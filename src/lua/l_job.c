/* Tasks: the taskman global.
 *
 *   taskman.spawn(fn, ...)   run fn as a background task; returns its id
 *   taskman.sleep(ms)        wait without blocking anything
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

void l_job_open(lua_State *L) {
  static const luaL_Reg fns[] = {
    {"spawn", l_spawn}, {"sleep", l_sleep},   {"yield", l_yield},
    {"tasks", l_tasks}, {"cancel", l_cancel},
    {NULL, NULL},
  };
  luaL_setfuncs(L, fns, 0);
}
