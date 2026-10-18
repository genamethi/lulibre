#include "core/log.h"
#include "lua/sched.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#include <lua.h>
#include <lauxlib.h>

#include "app.h"
#include "core/util.h"
#include "lua/lapi.h"

#define SLICE 0.004   /* seconds one task may run before it is interrupted */
#define BUDGET 0.008  /* seconds of task time per loop iteration */
#define HOOK_COUNT 1000

enum { T_READY, T_WAITING, T_DONE };

struct task {
  struct lctx ctx; /* what the coroutine's extra space points at */
  int id;
  char *name;
  lua_State *co;
  int ref; /* keeps the coroutine alive */
  int state, queued, cancelled;
  int nargs;   /* values on the coroutine's stack for the next resume */
  int pending; /* waits begun and not yet ended */
  double slice_start;
  sched_cancel_fn *cancel_fn;
  void *cancel_ud;
  struct task *qnext, *next;
};

struct sched {
  struct app *app;
  lua_State *L;
  struct task *qhead, *qtail; /* run queue */
  struct task *all;
  int next_id;
  atomic_int live, failed; /* read by the interface thread for its status line */
  uv_idle_t idle;
  int idle_on;
};

static struct task *task_of(lua_State *L) {
  return (*(struct lctx **)lua_getextraspace(L))->task;
}

static void idle_cb(uv_idle_t *h);

static void enqueue(struct sched *s, struct task *t) {
  if (t->queued) return;
  t->queued = 1;
  t->qnext = NULL;
  if (s->qtail) s->qtail->qnext = t;
  else s->qhead = t;
  s->qtail = t;
  if (!s->idle_on) {
    s->idle_on = 1;
    uv_idle_start(&s->idle, idle_cb);
  }
}

static void task_free(struct task *t) {
  free(t->name);
  free(t);
}

static void finish(struct sched *s, struct task *t, int ok, const char *err) {
  t->state = T_DONE;
  s->live--;
  log_debug("task %d %s: %s", t->id, t->cancelled ? "cancelled" : ok ? "done" : "failed", t->name);
  if (!ok && !t->cancelled) {
    s->failed++;
    /* a failure may be the tree's Lua files no longer fitting this binary */
    char *why = lstate_tree_mismatch();
    char *msg = why ? xasprintf("%s: %s\n%s", t->name, err ? err : "error", why)
                    : xasprintf("%s: %s", t->name, err ? err : "error");
    lapi_report(s->app, 1, msg);
    free(msg);
    free(why);
  }
  lua_closethread(t->co, s->L); /* run pending to-be-closed variables */
  luaL_unref(s->L, LUA_REGISTRYINDEX, t->ref);
  t->co = NULL;
  for (struct task **p = &s->all; *p; p = &(*p)->next)
    if (*p == t) {
      *p = t->next;
      break;
    }
  lapi_tasks_changed(s->app);
  if (t->pending == 0) task_free(t); /* else freed when its last wait ends */
}

static void slice_hook(lua_State *L, lua_Debug *ar) {
  struct task *t = task_of(L);
  (void)ar;
  if (!t) return;
  if (t->cancelled) luaL_error(L, "cancelled");
  if (now_s() - t->slice_start > SLICE && lua_isyieldable(L)) lua_yield(L, 0);
}

static void run_one(struct sched *s, struct task *t) {
  if (t->cancelled) {
    finish(s, t, 0, NULL);
    return;
  }
  int nres = 0;
  t->slice_start = now_s();
  lua_sethook(t->co, slice_hook, LUA_MASKCOUNT, HOOK_COUNT);
  int st = lua_resume(t->co, s->L, t->nargs, &nres);
  t->nargs = 0;
  if (st == LUA_YIELD) {
    lua_pop(t->co, nres);
    if (t->state == T_READY) enqueue(s, t); /* interrupted, or lulibre.yield() */
  } else if (st == LUA_OK) {
    finish(s, t, 1, NULL);
  } else {
    const char *msg = lua_tostring(t->co, -1);
    luaL_traceback(s->L, t->co, msg ? msg : "error (not a string)", 0);
    char *err = xstrdup(lua_tostring(s->L, -1));
    lua_pop(s->L, 1);
    finish(s, t, 0, err);
    free(err);
  }
}

static void idle_cb(uv_idle_t *h) {
  struct sched *s = h->data;
  double start = now_s();
  while (s->qhead && now_s() - start < BUDGET) {
    struct task *t = s->qhead;
    s->qhead = t->qnext;
    if (!s->qhead) s->qtail = NULL;
    t->queued = 0;
    run_one(s, t);
  }
  if (!s->qhead) {
    s->idle_on = 0;
    uv_idle_stop(&s->idle);
  }
}

void sched_init(struct app *app) {
  struct sched *s = xcalloc(1, sizeof *s);
  s->app = app;
  s->L = app->L;
  s->next_id = 1;
  uv_idle_init(app->lloop, &s->idle);
  s->idle.data = s;
  app->sched = s;
}

void sched_free(struct app *app) {
  struct sched *s = app->sched;
  if (!s) return;
  uv_idle_stop(&s->idle);
  /* tasks still alive here are released with the Lua state */
  for (struct task *t = s->all, *n; t; t = n) {
    n = t->next;
    task_free(t);
  }
  free(s);
  app->sched = NULL;
}

int sched_spawn(lua_State *L, int nargs, const char *name) {
  struct app *app = lapi_app(L);
  struct sched *s = app->sched;
  struct task *t = xcalloc(1, sizeof *t);
  t->ctx.app = app;
  t->ctx.task = t;
  t->id = s->next_id++;
  t->name = xstrdup(name && *name ? name : "task");
  t->co = lua_newthread(L);
  *(struct lctx **)lua_getextraspace(t->co) = &t->ctx;
  t->ref = luaL_ref(L, LUA_REGISTRYINDEX);
  lua_xmove(L, t->co, nargs + 1);
  t->nargs = nargs;
  t->state = T_READY;
  t->next = s->all;
  s->all = t;
  s->live++;
  enqueue(s, t);
  log_debug("task %d started: %s", t->id, t->name);
  lapi_tasks_changed(app);
  return t->id;
}

void sched_require_task(lua_State *L) {
  if (!task_of(L) || !lua_isyieldable(L))
    luaL_error(L, "this function waits for something, so it must run in a task: "
                  "call it from a script, a command, or lulibre.spawn(function() ... end)");
}

struct task *sched_begin_wait(lua_State *L) {
  sched_require_task(L);
  struct task *t = task_of(L);
  t->state = T_WAITING;
  t->pending++;
  return t;
}

void sched_abort_wait(struct task *t) {
  t->state = T_READY;
  t->pending--;
  t->cancel_fn = NULL;
}

lua_State *sched_end_wait(struct task *t) {
  struct sched *s = t->ctx.app->sched;
  t->pending--;
  t->cancel_fn = NULL;
  if (t->state == T_DONE) {
    if (t->pending == 0) task_free(t);
    return NULL;
  }
  if (t->cancelled) {
    finish(s, t, 0, NULL);
    return NULL;
  }
  return t->co;
}

void sched_wake(struct task *t, int nargs) {
  t->state = T_READY;
  t->nargs = nargs;
  enqueue(t->ctx.app->sched, t);
}

void sched_on_cancel(struct task *t, sched_cancel_fn *fn, void *ud) {
  t->cancel_fn = fn;
  t->cancel_ud = ud;
}

static void cancel(struct sched *s, struct task *t) {
  if (t->cancelled || t->state == T_DONE) return;
  t->cancelled = 1;
  if (t->state == T_READY) {
    enqueue(s, t); /* finished the next time it would have run */
  } else if (t->cancel_fn) {
    sched_cancel_fn *fn = t->cancel_fn;
    t->cancel_fn = NULL;
    fn(t->cancel_ud);
  }
}

int sched_cancel(struct app *app, int id) {
  struct sched *s = app->sched;
  for (struct task *t = s->all; t; t = t->next)
    if (t->id == id) {
      cancel(s, t);
      return 1;
    }
  return 0;
}

void sched_cancel_all(struct app *app) {
  struct sched *s = app->sched;
  if (!s) return;
  /* cancelling may finish a task and unlink it, so restart after each */
  for (;;) {
    struct task *t = s->all;
    while (t && t->cancelled) t = t->next;
    if (!t) break;
    cancel(s, t);
  }
}

int sched_live(const struct app *app) {
  return app->sched ? atomic_load(&app->sched->live) : 0;
}

int sched_failed(const struct app *app) {
  return app->sched ? atomic_load(&app->sched->failed) : 0;
}

void sched_push_tasks(lua_State *L) {
  struct sched *s = lapi_app(L)->sched;
  lua_newtable(L);
  int i = 0;
  for (struct task *t = s->all; t; t = t->next) {
    lua_createtable(L, 0, 3);
    lua_pushinteger(L, t->id);
    lua_setfield(L, -2, "id");
    lua_pushstring(L, t->name);
    lua_setfield(L, -2, "name");
    lua_pushstring(L, t->cancelled ? "cancelling" : t->state == T_WAITING ? "waiting" : "running");
    lua_setfield(L, -2, "state");
    lua_rawseti(L, -2, ++i);
  }
}

int sched_current_id(lua_State *L) {
  struct task *t = task_of(L);
  return t ? t->id : 0;
}
