/* Tasks: the taskman global.
 *
 *   taskman.spawn(fn, ...)   run fn as a background task; returns its id
 *   taskman.sleep([ms])      wait without blocking anything: ms
 *                            milliseconds, or until taskman.wake
 *   taskman.wake(id)         end task id's sleep now; true if it slept
 *   taskman.self()           the running task's id; nil outside a task
 *   taskman.yield()          give the other tasks a turn now: a task that
 *                            computes for long, between steps
 *   taskman.tasks()          { {id=, name=, state=}, ... }
 *   taskman.cancel(id)       ask a task to stop
 */
#include <stdio.h>
#include <stdlib.h>

#include <lua.h>
#include <lauxlib.h>

#include "app.h"
#include "core/util.h"
#include "lua/lapi.h"
#include "lua/sched.h"

static int l_spawn(lua_State *L) {
  luaL_checktype(L, 1, LUA_TFUNCTION);
  lua_pushinteger(L, sched_spawn(L, lua_gettop(L) - 1, NULL)); /* named "task N" */
  return 1;
}

/* A task asleep: by its timer, or (timed 0) until woken. The sleepers
 * are the Lua thread's, listed for wake. */
struct sleeper {
  uv_timer_t timer;
  struct task *task;
  int id, timed;
  struct sleeper *next;
};

static struct sleeper *sleepers;

static void sleeper_closed(uv_handle_t *h) {
  free(h->data);
}

static void sleeper_done(struct sleeper *s) {
  for (struct sleeper **p = &sleepers; *p; p = &(*p)->next)
    if (*p == s) {
      *p = s->next;
      break;
    }
  if (sched_end_wait(s->task)) sched_wake(s->task, 0);
  if (s->timed) uv_close((uv_handle_t *)&s->timer, sleeper_closed);
  else free(s);
}

static void sleeper_cb(uv_timer_t *h) {
  sleeper_done(h->data);
}

static void sleeper_cancel(void *ud) {
  struct sleeper *s = ud;
  if (s->timed) uv_timer_stop(&s->timer);
  sleeper_done(s);
}

static int l_sleep(lua_State *L) {
  int timed = !lua_isnoneornil(L, 1);
  lua_Number ms = timed ? luaL_checknumber(L, 1) : 0;
  int id = sched_current_id(L);
  struct task *t = sched_begin_wait(L);
  struct sleeper *s = xcalloc(1, sizeof *s);
  s->task = t;
  s->id = id;
  s->timed = timed;
  s->next = sleepers;
  sleepers = s;
  if (timed) {
    uv_timer_init(lapi_loop(L), &s->timer);
    s->timer.data = s;
    uv_timer_start(&s->timer, sleeper_cb, ms > 0 ? (uint64_t)ms : 0, 0);
  }
  sched_on_cancel(t, sleeper_cancel, s);
  return lua_yield(L, 0);
}

static int l_wake(lua_State *L) {
  int id = (int)luaL_checkinteger(L, 1);
  struct sleeper *s = sleepers;
  while (s && s->id != id) s = s->next;
  if (s) sleeper_cancel(s);
  lua_pushboolean(L, s != NULL);
  return 1;
}

static int l_self(lua_State *L) {
  int id = sched_current_id(L);
  if (id) lua_pushinteger(L, id);
  else lua_pushnil(L);
  return 1;
}

static int l_yield(lua_State *L) {
  sched_require_task(L);
  return lua_yield(L, 0); /* still runnable: goes to the back of the queue */
}

static int l_tasks(lua_State *L) {
  sched_push_tasks(L);
  return 1;
}

static int l_cancel(lua_State *L) {
  lua_pushboolean(L, sched_cancel(lapi_app(L), (int)luaL_checkinteger(L, 1)));
  return 1;
}

void l_job_close(void) {
  for (struct sleeper *s = sleepers, *n; s; s = n) {
    n = s->next;
    if (!s->timed) sleeper_done(s);
  }
}

void l_job_open(lua_State *L) {
  static const luaL_Reg fns[] = {
    {"spawn", l_spawn}, {"sleep", l_sleep},   {"yield", l_yield}, {"wake", l_wake},
    {"self", l_self},   {"tasks", l_tasks}, {"cancel", l_cancel},
    {NULL, NULL},
  };
  luaL_setfuncs(L, fns, 0);
}
