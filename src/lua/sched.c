#include "core/log.h"
#include "lua/sched.h"

#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <lua.h>
#include <lauxlib.h>

#include "app.h"
#include "core/util.h"
#include "lua/lapi.h"

#define BUDGET 0.008 /* seconds of task time per loop iteration, between tasks */
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
  int warned;  /* said, in this run, that it runs too long */
  sched_cancel_fn *cancel_fn;
  void *cancel_ud;
  struct task *qnext, *next;
  struct sched *s; /* its scheduler, while there is one */
  /* the lua_State is gone (:restart-scripts) while a wait of this task's
   * was still out: the wait's end finds no task to wake, and frees it */
  int orphan;
};

struct sched {
  struct app *app;
  lua_State *L;
  struct task *qhead, *qtail; /* run queue */
  struct task *all;
  struct task *limbo; /* finished, with waits still out */
  int next_id;
  int jobs; /* worker jobs begun and not yet ended */
  atomic_int live, failed; /* read by the interface thread for its status line */
  uv_idle_t *idle;
  int idle_on;
  /* A task waiting for a message (lulibre.library's answer, say) has no
   * handle of its own on the loop; while any task waits, this one keeps
   * the loop running. */
  uv_async_t *keep;
  int waits;
};

static struct task *task_of(lua_State *L) {
  return (*(struct lctx **)lua_getextraspace(L))->task;
}

/* ---- the task that is running, for other threads (sched.h) ----
 *
 * Tasks give way only where they wait. While one runs, the Lua thread's
 * loop does not turn, so a message cannot reach it: another thread reads
 * these, and stops or reports it through a hook installed by a signal. */
static _Atomic(lua_State *) running_co;
static atomic_int running_id;
static atomic_llong running_since; /* ms, uv_hrtime's clock */
static atomic_int stop_id;         /* a task to stop as it runs */

/* The task running, on the Lua thread: a coroutine the task resumed has no
 * task of its own, and its hook finds the task here. */
static struct task *current;

static long long now_ms(void) {
  return (long long)(uv_hrtime() / 1000000);
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
    uv_idle_start(s->idle, idle_cb);
  }
}

/* The task list as the interface shows it (:tasks), sent at each change:
 * it cannot ask the Lua thread while a task runs. */
static void publish(struct sched *s) {
  int n = 0;
  for (struct task *t = s->all; t; t = t->next) n++;
  struct sched_task_list *l = xcalloc(1, sizeof *l + (size_t)n * sizeof l->task[0]);
  for (struct task *t = s->all; t; t = t->next) {
    l->task[l->n].id = t->id;
    l->task[l->n].cancelled = t->cancelled;
    snprintf(l->task[l->n].name, sizeof l->task[l->n].name, "%s", t->name);
    l->n++;
  }
  lapi_tasks_changed(s->app, l);
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
  publish(s);
  if (t->pending == 0) {
    task_free(t);
  } else { /* freed when its last wait ends */
    t->next = s->limbo;
    s->limbo = t;
  }
}

/* Installed only while a task has run too long (on_watch_signal), on the
 * coroutine running then: the task's, or one it resumed. Says so once, and
 * stops the task when it is cancelled. It stops it by yielding, which no
 * pcall catches: in the task's coroutine, run_one then finishes the task,
 * closing what it holds; in one the task resumed, the resume yields the
 * task in turn (co_resume). Where a yield cannot cross (a C function's
 * callback), it raises an error, and stays to raise again. */
static void watch_hook(lua_State *L, lua_Debug *ar) {
  (void)ar;
  struct task *t = current;
  if (!t) {
    lua_sethook(L, NULL, 0, 0);
    return;
  }
  if (atomic_load(&stop_id) == t->id) t->cancelled = 1;
  if (!t->warned) {
    t->warned = 1;
    /* "task 3 (propose)", or "task 3" for one taskman.spawn named so */
    char *msg = xasprintf("task %d%s%s%s has run %.1f s without waiting%s", t->id,
                          strncmp(t->name, "task ", 5) ? " (" : "", strncmp(t->name, "task ", 5) ? t->name : "",
                          strncmp(t->name, "task ", 5) ? ")" : "",
                          (now_ms() - atomic_load(&running_since)) / 1000.0, t->cancelled || !t->ctx.app->tui ? "" : "; :cancel stops it");
    lapi_report(t->ctx.app, 1, msg);
    free(msg);
  }
  if (!t->cancelled) {
    lua_sethook(L, NULL, 0, 0);
    return;
  }
  if (lua_isyieldable(L)) {
    lua_yield(L, 0); /* from a hook, it returns; the yield happens as the hook ends */
    return;
  }
  luaL_error(L, "cancelled");
}

long long sched_running_ms(void) {
  long long since = atomic_load(&running_since);
  return since ? now_ms() - since : 0;
}

/* ---- the clock on a run ----
 *
 * A run (one resume of a task) arms a timer that signals the thread running
 * Lua once the run has gone 2 s; the signal puts the hook on the coroutine
 * running then, as lua.c does for Ctrl-C. A run that waits sooner disarms
 * it, and no signal comes. The same signal, sent by another thread, brings
 * the hook to a task stopped as it runs (sched_stop_running). */

#define TOO_LONG_MS 2000

static timer_t clock_;
static int clocked;

int sched_watch_signal(void) {
  return SIGRTMIN + 1;
}

static void on_watch_signal(int sig) {
  (void)sig;
  lua_State *co = atomic_load(&running_co);
  /* a signal that arrives as a run ends, or in the next one, finds nothing to do */
  if (!co || (sched_running_ms() < TOO_LONG_MS && atomic_load(&stop_id) != atomic_load(&running_id))) return;
  lua_sethook(co, watch_hook, LUA_MASKCOUNT, HOOK_COUNT);
}

void sched_watch_here(void) {
  static int handled;
  if (!handled) {
    handled = 1;
    struct sigaction sa = {.sa_handler = on_watch_signal, .sa_flags = SA_RESTART};
    sigemptyset(&sa.sa_mask);
    sigaction(sched_watch_signal(), &sa, NULL);
  }
  if (clocked) timer_delete(clock_);
  struct sigevent ev = {.sigev_notify = SIGEV_THREAD_ID, .sigev_signo = sched_watch_signal()};
  ev._sigev_un._tid = gettid();
  clocked = timer_create(CLOCK_MONOTONIC, &ev, &clock_) == 0;
  if (!clocked) log_debug("no clock on runs: a task that runs too long is not reported");
}

/* ms > 0 arms the clock; 0 disarms it */
static void clock_set(long long ms) {
  if (!clocked) return;
  struct itimerspec it = {.it_value = {.tv_sec = ms / 1000, .tv_nsec = (ms % 1000) * 1000000}};
  timer_settime(clock_, 0, &it, NULL);
}

int sched_running_id(void) {
  return atomic_load(&running_id);
}

void sched_stop_running(int id) {
  atomic_store(&stop_id, id);
}

static void run_one(struct sched *s, struct task *t) {
  if (t->cancelled) {
    finish(s, t, 0, NULL);
    return;
  }
  int nres = 0;
  t->warned = 0;
  current = t;
  atomic_store(&running_id, t->id);
  atomic_store(&running_since, now_ms());
  atomic_store(&running_co, t->co);
  clock_set(TOO_LONG_MS);
  int st = lua_resume(t->co, s->L, t->nargs, &nres);
  clock_set(0);
  atomic_store(&running_co, NULL);
  atomic_store(&running_since, 0);
  atomic_store(&running_id, 0);
  current = NULL;
  int stop = t->id;
  atomic_compare_exchange_strong(&stop_id, &stop, 0);
  lua_sethook(t->co, NULL, 0, 0);
  t->nargs = 0;
  if (st == LUA_YIELD) {
    lua_pop(t->co, nres);
    if (t->state == T_READY) enqueue(s, t); /* taskman.yield() */
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
    uv_idle_stop(s->idle);
  }
}

static void handle_free(uv_handle_t *h) {
  free(h);
}

static void waits_add(struct sched *s, int d) {
  int before = s->waits;
  s->waits += d;
  if (!before && s->waits) uv_ref((uv_handle_t *)s->keep);
  else if (before && !s->waits) uv_unref((uv_handle_t *)s->keep);
}

void sched_init(struct app *app) {
  struct sched *s = xcalloc(1, sizeof *s);
  s->app = app;
  s->L = app->L;
  s->next_id = 1;
  s->idle = xcalloc(1, sizeof *s->idle);
  uv_idle_init(app->lloop, s->idle);
  s->idle->data = s;
  s->keep = xcalloc(1, sizeof *s->keep);
  uv_async_init(app->lloop, s->keep, NULL);
  uv_unref((uv_handle_t *)s->keep);
  app->sched = s;
  sched_watch_here(); /* the thread making the state runs it first */
}

void sched_free(struct app *app) {
  struct sched *s = app->sched;
  if (!s) return;
  if (clocked) timer_delete(clock_);
  clocked = 0;
  uv_idle_stop(s->idle);
  /* the handles go when the loop next turns, if it does */
  uv_close((uv_handle_t *)s->idle, handle_free);
  uv_close((uv_handle_t *)s->keep, handle_free);
  /* tasks still alive here are released with the Lua state; one with a
   * wait still out is freed when the wait ends (orphan) */
  for (struct task *t = s->all, *n; t; t = n) {
    n = t->next;
    if (t->pending > 0) {
      t->orphan = 1;
      t->state = T_DONE;
      t->co = NULL;
      t->s = NULL;
    } else {
      task_free(t);
    }
  }
  for (struct task *t = s->limbo; t; t = t->next) {
    t->orphan = 1;
    t->s = NULL;
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
  t->s = s;
  t->id = s->next_id++;
  t->name = name && *name ? xstrdup(name) : xasprintf("task %d", t->id); /* taskman.spawn's */
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
  publish(s);
  return t->id;
}

int sched_spawn_now(lua_State *L, int nargs, const char *name) {
  struct sched *s = lapi_app(L)->sched;
  int id = sched_spawn(L, nargs, name);
  struct task *t = s->qtail; /* the one just queued */
  for (struct task **p = &s->qhead; *p; p = &(*p)->qnext)
    if (*p == t) {
      *p = t->qnext;
      if (s->qtail == t) {
        s->qtail = NULL;
        for (struct task *q = s->qhead; q; q = q->qnext) s->qtail = q;
      }
      break;
    }
  t->queued = 0;
  run_one(s, t);
  return id;
}

/* ---- coroutines a task resumes ----
 *
 * coroutine.resume and coroutine.wrap, as Lua's, but the coroutine they
 * resume is the one a hook goes on while it runs (running_co), and a task
 * cancelled while it ran yields on the resume's return, up to the
 * scheduler: a task looping in a coroutine of its own is reached too. */

/* lcorolib's auxresume: the results on L, or -1 and the error on L. */
static int resume(lua_State *L, lua_State *co, int narg) {
  if (!lua_checkstack(co, narg)) {
    lua_pushliteral(L, "too many arguments to resume");
    return -1;
  }
  lua_xmove(L, co, narg);
  lua_State *outer = atomic_load(&running_co);
  if (outer) atomic_store(&running_co, co);
  int nres, status = lua_resume(co, L, narg, &nres);
  if (outer) atomic_store(&running_co, outer);
  if (status == LUA_OK || status == LUA_YIELD) {
    if (!lua_checkstack(L, nres + 1)) {
      lua_pop(co, nres);
      lua_pushliteral(L, "too many results to resume");
      return -1;
    }
    lua_xmove(co, L, nres);
    return nres;
  }
  lua_xmove(co, L, 1);
  return -1;
}

/* The task was cancelled while the coroutine ran: on up. */
static int stopping(lua_State *L) {
  if (!current || !current->cancelled) return 0;
  if (lua_isyieldable(L)) return 1;
  luaL_error(L, "cancelled");
  return 0;
}

static int co_resume(lua_State *L) {
  lua_State *co = lua_tothread(L, 1);
  luaL_argexpected(L, co, 1, "coroutine");
  int r = resume(L, co, lua_gettop(L) - 1);
  if (stopping(L)) return lua_yield(L, 0);
  if (r < 0) {
    lua_pushboolean(L, 0);
    lua_insert(L, -2);
    return 2;
  }
  lua_pushboolean(L, 1);
  lua_insert(L, -(r + 1));
  return r + 1;
}

/* lcorolib's auxwrap */
static int co_wrapped(lua_State *L) {
  lua_State *co = lua_tothread(L, lua_upvalueindex(1));
  int r = resume(L, co, lua_gettop(L));
  if (stopping(L)) return lua_yield(L, 0);
  if (r < 0) {
    int status = lua_status(co);
    if (status != LUA_OK && status != LUA_YIELD) { /* an error in the coroutine */
      status = lua_closethread(co, L);
      lua_xmove(co, L, 1);
    }
    if (status != LUA_ERRMEM && lua_type(L, -1) == LUA_TSTRING) {
      luaL_where(L, 1);
      lua_insert(L, -2);
      lua_concat(L, 2);
    }
    return lua_error(L);
  }
  return r;
}

static int co_wrap(lua_State *L) {
  luaL_checktype(L, 1, LUA_TFUNCTION);
  lua_State *co = lua_newthread(L);
  lua_pushvalue(L, 1);
  lua_xmove(L, co, 1);
  lua_pushcclosure(L, co_wrapped, 1);
  return 1;
}

void sched_open_coroutines(lua_State *L) {
  lua_getglobal(L, "coroutine");
  lua_pushcfunction(L, co_resume);
  lua_setfield(L, -2, "resume");
  lua_pushcfunction(L, co_wrap);
  lua_setfield(L, -2, "wrap");
  lua_pop(L, 1);
}

void sched_require_task(lua_State *L) {
  if (!task_of(L) || !lua_isyieldable(L))
    luaL_error(L, "this function waits for something, so it must run in a task: "
                  "call it from a script, a command, or taskman.spawn(function() ... end)");
}

struct task *sched_begin_wait(lua_State *L) {
  sched_require_task(L);
  struct task *t = task_of(L);
  /* cancelled while it ran: it stops at its next wait */
  if (t->cancelled) luaL_error(L, "cancelled");
  t->state = T_WAITING;
  t->pending++;
  waits_add(t->s, 1);
  return t;
}

/* A wait's end for an orphan: nothing to wake. */
static void orphan_end(struct task *t) {
  if (--t->pending == 0) task_free(t);
}

static void limbo_drop(struct sched *s, struct task *t) {
  for (struct task **p = &s->limbo; *p; p = &(*p)->next)
    if (*p == t) {
      *p = t->next;
      return;
    }
}

void sched_abort_wait(struct task *t) {
  if (t->orphan) {
    orphan_end(t);
    return;
  }
  t->state = T_READY;
  t->pending--;
  waits_add(t->s, -1);
  t->cancel_fn = NULL;
}

lua_State *sched_end_wait(struct task *t) {
  if (t->orphan) {
    orphan_end(t);
    return NULL;
  }
  struct sched *s = t->s;
  t->pending--;
  waits_add(s, -1);
  t->cancel_fn = NULL;
  if (t->state == T_DONE) {
    if (t->pending == 0) {
      limbo_drop(s, t);
      task_free(t);
    }
    return NULL;
  }
  if (t->cancelled) {
    finish(s, t, 0, NULL);
    return NULL;
  }
  return t->co;
}

struct task *sched_begin_job(lua_State *L) {
  struct task *t = sched_begin_wait(L);
  t->s->jobs++;
  return t;
}

lua_State *sched_end_job(struct task *t) {
  if (t->s) t->s->jobs--; /* before sched_end_wait, which may free t */
  return sched_end_wait(t);
}

int sched_jobs(const struct app *app) {
  return app->sched ? app->sched->jobs : 0;
}

void sched_wake(struct task *t, int nargs) {
  t->state = T_READY;
  t->nargs = nargs;
  enqueue(t->s, t);
}

void sched_on_cancel(struct task *t, sched_cancel_fn *fn, void *ud) {
  t->cancel_fn = fn;
  t->cancel_ud = ud;
}

static void cancel(struct sched *s, struct task *t) {
  if (t->cancelled || t->state == T_DONE) return;
  t->cancelled = 1;
  publish(s);
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
  if (!s) return 0;
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

void sched_note_failure(struct app *app) {
  if (app->sched) atomic_fetch_add(&app->sched->failed, 1);
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
