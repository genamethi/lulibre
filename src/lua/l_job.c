/* Tasks.
 *
 *   lulibre.spawn(fn, ...)   run fn as a background task; returns its id
 *   lulibre.sleep(ms)        wait without blocking anything
 *   lulibre.yield()          give the other tasks a turn now: a task that
 *                            computes for long, between steps
 *   lulibre.tasks()          { {id=, name=, state=}, ... }
 *   lulibre.cancel(id)       ask a task to stop
 *   lulibre.task_id()        id of the running task, or nil outside one
 *   lulibre.claim(t, key [, value])
 *                            t[key] = value (default true) if it is nil:
 *                            true if this call set it, false if it was set.
 *                            Give it back with t[key] = nil. (From when
 *                            tasks were interrupted anywhere; between two
 *                            waits, a test and a set are one step now.)
 */
#include <stdio.h>
#include <stdlib.h>

#include <lua.h>
#include <lauxlib.h>

#include "app.h"
#include "core/util.h"
#include "lua/lapi.h"
#include "lua/sched.h"

/* One C call is one step for the scheduler: the count hook that interrupts
 * tasks runs between Lua instructions, never inside a C function. Raw
 * access, so no metamethod (Lua code) runs in between. */
static int l_claim(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  luaL_checkany(L, 2);
  lua_pushvalue(L, 2);
  if (lua_rawget(L, 1) != LUA_TNIL) {
    lua_pushboolean(L, 0);
    return 1;
  }
  lua_pushvalue(L, 2);
  if (lua_isnoneornil(L, 3)) lua_pushboolean(L, 1);
  else lua_pushvalue(L, 3);
  lua_rawset(L, 1);
  lua_pushboolean(L, 1);
  return 1;
}

static int l_spawn(lua_State *L) {
  luaL_checktype(L, 1, LUA_TFUNCTION);
  lua_Debug ar;
  char name[96] = "task";
  lua_pushvalue(L, 1);
  if (lua_getinfo(L, ">S", &ar)) snprintf(name, sizeof name, "%s:%d", ar.short_src, ar.linedefined);
  lua_pushinteger(L, sched_spawn(L, lua_gettop(L) - 1, name));
  return 1;
}

struct sleeper {
  uv_timer_t timer;
  struct task *task;
};

static void sleeper_closed(uv_handle_t *h) {
  free(h->data);
}

static void sleeper_done(struct sleeper *s) {
  if (sched_end_wait(s->task)) sched_wake(s->task, 0);
  uv_close((uv_handle_t *)&s->timer, sleeper_closed);
}

static void sleeper_cb(uv_timer_t *h) {
  sleeper_done(h->data);
}

static void sleeper_cancel(void *ud) {
  struct sleeper *s = ud;
  uv_timer_stop(&s->timer);
  sleeper_done(s);
}

static int l_sleep(lua_State *L) {
  lua_Number ms = luaL_checknumber(L, 1);
  struct task *t = sched_begin_wait(L);
  struct sleeper *s = xcalloc(1, sizeof *s);
  s->task = t;
  uv_timer_init(lapi_loop(L), &s->timer);
  s->timer.data = s;
  uv_timer_start(&s->timer, sleeper_cb, ms > 0 ? (uint64_t)ms : 0, 0);
  sched_on_cancel(t, sleeper_cancel, s);
  return lua_yield(L, 0);
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

static int l_task_id(lua_State *L) {
  int id = sched_current_id(L);
  if (id) lua_pushinteger(L, id);
  else lua_pushnil(L);
  return 1;
}

void l_job_open(lua_State *L) {
  static const luaL_Reg fns[] = {
    {"spawn", l_spawn}, {"sleep", l_sleep},   {"yield", l_yield},
    {"tasks", l_tasks}, {"cancel", l_cancel}, {"task_id", l_task_id}, {"claim", l_claim},
    {NULL, NULL},
  };
  luaL_setfuncs(L, fns, 0);
}
