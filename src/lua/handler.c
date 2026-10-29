/* Handlers (core/registry.h): a function of Lua's in the place of a part
 * of C's, set as a field of a library table, `utils.ocr = fn` or
 * `store.calibre = fn`; nil gives the part back to C.
 *
 * The functions are kept in the registry by part, so C finds them without
 * the table. A request for a part comes from any thread; on the Lua thread
 * a task calls the handler once per call the part lists, each in a pcall,
 * and the part's answer reads the results. The request goes with a reply
 * handle (lua/reply.c) in the task's first slot, closed with the task: a
 * task cancelled or collected unanswered fails its request. */
#include <stdlib.h>

#include <lua.h>
#include <lauxlib.h>

#include "app.h"
#include "core/queue.h"
#include "core/registry.h"
#include "core/util.h"
#include "lua/lapi.h"
#include "lua/sched.h"

#define HANDLERS "lulibre.handlers"

/* the registry's table of handlers, by part, on top */
static void push_handlers(lua_State *L) {
  luaL_getsubtable(L, LUA_REGISTRYINDEX, HANDLERS);
}

/* __index and __newindex; upvalue 1, { [key] = part } */
static int m_index(lua_State *L) {
  if (lua_getfield(L, lua_upvalueindex(1), luaL_checkstring(L, 2)) == LUA_TNIL) return 1;
  int part = (int)lua_tointeger(L, -1);
  push_handlers(L);
  lua_rawgeti(L, -1, part);
  return 1;
}

static int m_newindex(lua_State *L) {
  if (lua_type(L, 2) != LUA_TSTRING || lua_getfield(L, lua_upvalueindex(1), lua_tostring(L, 2)) == LUA_TNIL) {
    lua_settop(L, 3);
    lua_rawset(L, 1);
    return 0;
  }
  int part = (int)lua_tointeger(L, -1);
  if (!lua_isnil(L, 3)) luaL_checktype(L, 3, LUA_TFUNCTION);
  push_handlers(L);
  lua_pushvalue(L, 3);
  lua_rawseti(L, -2, part);
  registry_set_lua((enum registry_kind)part, !lua_isnil(L, 3));
  return 0;
}

void lapi_handlers(lua_State *L, int idx, const struct lapi_handler *h) {
  idx = lua_absindex(L, idx);
  lua_newtable(L); /* the metatable */
  lua_newtable(L); /* key -> part */
  for (; h->key; h++) {
    lua_pushinteger(L, h->part->kind);
    lua_setfield(L, -2, h->key);
  }
  lua_pushvalue(L, -1);
  lua_pushcclosure(L, m_index, 1);
  lua_setfield(L, -3, "__index");
  lua_pushcclosure(L, m_newindex, 1);
  lua_setfield(L, -2, "__newindex");
  lua_setmetatable(L, idx);
}

/* ---- running one ----
 *
 * The task's stack: 1 the handle, 2 the handler, 3 the calls, 4 the
 * results, 5 the call being made, 6 the first error. */

static void record(lua_State *L, int status, int args);
static int calls_k(lua_State *L, int status, lua_KContext ctx);

/* the next call, or the answer when none is left */
static int next_call(lua_State *L) {
  const struct lapi_part *p = lua_touserdata(L, lua_upvalueindex(1));
  for (;;) {
    lua_Integer i = lua_tointeger(L, 5) + 1;
    lua_pushinteger(L, i);
    lua_replace(L, 5);
    if (lua_rawgeti(L, 3, i) == LUA_TNIL) {
      lua_pop(L, 1);
      break;
    }
    int args = lua_gettop(L), n = (int)lua_rawlen(L, args);
    lua_pushvalue(L, 2);
    for (int k = 1; k <= n; k++) lua_rawgeti(L, args, k);
    record(L, lua_pcallk(L, n, LUA_MULTRET, 0, args, calls_k), args);
  }
  void *req = lapi_take_reply(L, 1);
  p->answer(L, req, 4, lua_tostring(L, 6));
  return 0;
}

/* a call returned (or raised): its results packed in results[i], false
 * where it raised */
static void record(lua_State *L, int status, int args) {
  int top = lua_gettop(L);
  lua_Integer i = lua_tointeger(L, 5);
  if (status == LUA_OK || status == LUA_YIELD) {
    lua_createtable(L, top - args, 0);
    for (int k = args + 1; k <= top; k++) {
      lua_pushvalue(L, k);
      lua_rawseti(L, -2, k - args);
    }
  } else {
    if (lua_isnil(L, 6)) {
      luaL_tolstring(L, -1, NULL);
      lua_replace(L, 6);
    }
    lua_pushboolean(L, 0);
  }
  lua_rawseti(L, 4, i);
  lua_settop(L, args - 1);
}

/* a call that waited ended: what run does next is done from here, since
 * next_call's loop is gone with the wait */
static int calls_k(lua_State *L, int status, lua_KContext ctx) {
  record(L, status, (int)ctx);
  return next_call(L);
}

static int run(lua_State *L) {
  lua_toclose(L, 1);
  lua_settop(L, 3);
  lua_newtable(L);
  lua_pushinteger(L, 0);
  lua_pushnil(L);
  return next_call(L);
}

struct request {
  const struct lapi_part *p;
  void *req;
};

static void start(struct app *app, void *arg) { /* the Lua thread */
  struct request *r = arg;
  const struct lapi_part *p = r->p;
  void *req = r->req;
  free(r);
  lua_State *L = app->L;
  if (!L) {
    p->fail(req, "no lua_State: the scripts are restarting");
    return;
  }
  push_handlers(L);
  lua_rawgeti(L, -1, p->kind);
  lua_remove(L, -2);
  if (!lua_isfunction(L, -1)) { /* set to nil since C asked */
    lua_pop(L, 1);
    p->fail(req, "the handler was taken away");
    return;
  }
  lua_pushlightuserdata(L, (void *)p);
  lua_pushcclosure(L, run, 1);
  lua_insert(L, -2);
  lapi_push_reply(L, req, p->fail);
  lua_insert(L, -2);
  p->calls(L, req);
  sched_spawn(L, 3, p->name);
}

void lapi_handle(const struct lapi_part *p, void *req) {
  struct request *r = xmalloc(sizeof *r);
  r->p = p;
  r->req = req;
  queue_post(LOOP_LUA, start, r);
}
