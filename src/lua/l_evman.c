/* evman: callbacks on shared events (design 1, 3, 5).
 *
 *   evman.add(event, fn, ...)   a callback; returns its id
 *   evman.rm(id)
 *   evman.post(event, payload)  a shared event, from packaged code that
 *                               finds one out (an online answer arriving:
 *                               "source_arrived" {book=, service=}); each
 *                               loop's callbacks get it as they get C's
 *
 * event: "cursor" {book=}, "marks" {selection={...}}, "records_changed"
 * {ids=, fields=}, "holder" {holder="none"|"server"|"program"},
 * "source_arrived" {book=, service=}.
 *
 * Each time the event comes, fn runs as a task with the payload and then
 * the trailing values: fn(payload, ...). A trailing value that is a
 * function is called first, as the event comes and before any callback
 * runs, and its results are passed in its place (all of them when it is
 * the last, else the first, as in a Lua call). So a value is taken when
 * the callback is registered (passed as a value, or a local fn closes
 * over), when the callback starts (setman.get in fn), or each time the
 * event comes (a function). */
#include <stdlib.h>
#include <string.h>

#include <lua.h>
#include <lauxlib.h>

#include "app.h"
#include "core/events.h"
#include "core/util.h"
#include "library/library.h"
#include "lua/lapi.h"
#include "lua/sched.h"

/* registry: CALLBACKS[kind+1] = { cb, ... } in the order added, where cb =
 * { id=, fn=, n=, ... (the trailing values) }; IDS[id] = kind+1 */
static const char CALLBACKS[] = "lulibre.evman", IDS[] = "lulibre.evman.ids";

static const char *const names[EV_KINDS] = {
  [EV_CURSOR] = "cursor",          [EV_MARKS] = "marks",
  [EV_RECORDS_CHANGED] = "records_changed", [EV_HOLDER] = "holder",
  [EV_SOURCE_ARRIVED] = "source_arrived",
};

/* Lua's callbacks per kind, kept here for the Lua thread's listener. */
static int count[EV_KINDS];
static int next_id;

static void push_ids(lua_State *L, const long long *ids, int n) {
  lua_createtable(L, n, 0);
  for (int i = 0; i < n; i++) {
    lua_pushinteger(L, ids[i]);
    lua_rawseti(L, -2, i + 1);
  }
}

static void push_payload(lua_State *L, const struct event *ev) {
  static const char *holders[] = {[HOLDER_NONE] = "none", [HOLDER_SERVER] = "server", [HOLDER_PROGRAM] = "program"};
  lua_newtable(L);
  switch (ev->kind) {
  case EV_CURSOR:
    lua_pushinteger(L, ev->book);
    lua_setfield(L, -2, "book");
    break;
  case EV_MARKS:
    push_ids(L, ev->selection, ev->nselection);
    lua_setfield(L, -2, "selection");
    break;
  case EV_RECORDS_CHANGED:
    push_ids(L, ev->ids, ev->nids);
    lua_setfield(L, -2, "ids");
    lua_createtable(L, ev->nfields, 0);
    for (int i = 0; i < ev->nfields; i++) {
      lua_pushstring(L, ev->fields[i]);
      lua_rawseti(L, -2, i + 1);
    }
    lua_setfield(L, -2, "fields");
    break;
  case EV_HOLDER:
    lua_pushstring(L, holders[ev->holder]);
    lua_setfield(L, -2, "holder");
    break;
  case EV_SOURCE_ARRIVED:
    lua_pushinteger(L, ev->book);
    lua_setfield(L, -2, "book");
    lua_pushstring(L, ev->service);
    lua_setfield(L, -2, "service");
    break;
  case EV_KINDS:
    break;
  }
}

/* A table { fn, payload, values... , n= } for callback cb (at index cbi),
 * with its functions called; or nothing and the message, on an error. */
static int prepare(lua_State *L, int cbi, int payload) {
  lua_newtable(L);
  int out = lua_gettop(L);
  lua_getfield(L, cbi, "fn");
  lua_rawseti(L, out, 1);
  lua_pushvalue(L, payload);
  lua_rawseti(L, out, 2);
  lua_getfield(L, cbi, "n");
  int n = (int)lua_tointeger(L, -1), k = 2;
  lua_pop(L, 1);
  for (int i = 1; i <= n; i++) {
    lua_rawgeti(L, cbi, i);
    if (!lua_isfunction(L, -1)) {
      lua_rawseti(L, out, ++k);
      continue;
    }
    int base = lua_gettop(L) - 1;
    if (lua_pcall(L, 0, i == n ? LUA_MULTRET : 1, 0) != LUA_OK) {
      lua_remove(L, out);
      return -1;
    }
    int got = lua_gettop(L) - base;
    for (int j = 0; j < got; j++) lua_rawseti(L, out, k + got - j); /* pops from the top: the last first */
    k += got;
  }
  lua_pushinteger(L, k);
  lua_setfield(L, out, "n");
  return 0;
}

static void dispatch(const struct event *ev, void *ud) {
  struct app *app = ud;
  lua_State *L = app->L;
  if (!L) return;
  int top = lua_gettop(L);
  lua_getfield(L, LUA_REGISTRYINDEX, CALLBACKS);
  lua_rawgeti(L, -1, ev->kind + 1);
  int list = lua_gettop(L);
  if (!lua_istable(L, list)) {
    lua_settop(L, top);
    return;
  }
  push_payload(L, ev);
  int payload = lua_gettop(L);
  /* every callback's values are taken before any callback runs */
  int n = (int)lua_rawlen(L, list);
  lua_createtable(L, n, 0);
  int calls = lua_gettop(L), ncalls = 0;
  for (int i = 1; i <= n; i++) {
    lua_rawgeti(L, list, i);
    if (prepare(L, lua_gettop(L), payload)) {
      lapi_report(app, 1, lua_tostring(L, -1));
      lua_pop(L, 2);
      continue;
    }
    lua_rawseti(L, calls, ++ncalls);
    lua_pop(L, 1);
  }
  for (int i = 1; i <= ncalls; i++) {
    lua_rawgeti(L, calls, i);
    lua_getfield(L, -1, "n");
    int k = (int)lua_tointeger(L, -1);
    lua_pop(L, 1);
    for (int j = 1; j <= k; j++) lua_rawgeti(L, -j, j);
    lua_remove(L, -k - 1);
    sched_spawn(L, k - 1, names[ev->kind]);
  }
  lua_settop(L, top);
}

static int kind_of(lua_State *L, int idx) {
  const char *name = luaL_checkstring(L, idx);
  for (int k = 0; k < EV_KINDS; k++)
    if (!strcmp(names[k], name)) return k;
  return luaL_argerror(L, idx, lua_pushfstring(L, "no event is called %s", name));
}

static int l_add(lua_State *L) {
  int kind = kind_of(L, 1);
  luaL_checktype(L, 2, LUA_TFUNCTION);
  int n = lua_gettop(L) - 2;
  lua_createtable(L, n, 3);
  int cb = lua_gettop(L);
  for (int i = 1; i <= n; i++) {
    lua_pushvalue(L, i + 2);
    lua_rawseti(L, cb, i);
  }
  lua_pushinteger(L, n);
  lua_setfield(L, cb, "n");
  lua_pushvalue(L, 2);
  lua_setfield(L, cb, "fn");
  int id = ++next_id;
  lua_pushinteger(L, id);
  lua_setfield(L, cb, "id");

  lua_getfield(L, LUA_REGISTRYINDEX, CALLBACKS);
  if (lua_rawgeti(L, -1, kind + 1) == LUA_TNIL) {
    lua_pop(L, 1);
    lua_newtable(L);
    lua_pushvalue(L, -1);
    lua_rawseti(L, -3, kind + 1);
  }
  lua_pushvalue(L, cb);
  lua_rawseti(L, -2, (lua_Integer)lua_rawlen(L, -2) + 1);
  lua_getfield(L, LUA_REGISTRYINDEX, IDS);
  lua_pushinteger(L, kind + 1);
  lua_rawseti(L, -2, id);
  if (count[kind]++ == 0) events_listen(LOOP_LUA, kind, dispatch, lapi_app(L));
  lua_pushinteger(L, id);
  return 1;
}

static int l_rm(lua_State *L) {
  lua_Integer id = luaL_checkinteger(L, 1);
  lua_getfield(L, LUA_REGISTRYINDEX, IDS);
  if (lua_rawgeti(L, -1, id) == LUA_TNIL) return luaL_error(L, "no callback has the id %d", (int)id);
  int kind = (int)lua_tointeger(L, -1) - 1;
  lua_pop(L, 1);
  lua_pushnil(L);
  lua_rawseti(L, -2, id);
  lua_getfield(L, LUA_REGISTRYINDEX, CALLBACKS);
  lua_rawgeti(L, -1, kind + 1);
  int list = lua_gettop(L), n = (int)lua_rawlen(L, list);
  for (int i = 1; i <= n; i++) {
    lua_rawgeti(L, list, i);
    lua_getfield(L, -1, "id");
    int found = lua_tointeger(L, -1) == id;
    lua_pop(L, 2);
    if (!found) continue;
    for (int j = i; j < n; j++) {
      lua_rawgeti(L, list, j + 1);
      lua_rawseti(L, list, j);
    }
    lua_pushnil(L);
    lua_rawseti(L, list, n);
    break;
  }
  if (--count[kind] == 0) events_unlisten(LOOP_LUA, kind, dispatch, lapi_app(L));
  return 0;
}

static long long *ids_of(lua_State *L, int idx, const char *field, int *n) {
  lua_getfield(L, idx, field);
  *n = lua_istable(L, -1) ? (int)lua_rawlen(L, -1) : 0;
  long long *ids = xcalloc((size_t)*n + 1, sizeof *ids);
  for (int i = 0; i < *n; i++) {
    lua_rawgeti(L, -1, i + 1);
    ids[i] = lua_tointeger(L, -1);
    lua_pop(L, 1);
  }
  lua_pop(L, 1);
  return ids;
}

/* The services' names live as long as the program: the payload's service
 * points at a copy kept here. */
static const char *service_name(const char *s) {
  static char *names[64];
  static int n;
  for (int i = 0; i < n; i++)
    if (!strcmp(names[i], s)) return names[i];
  if (n == (int)ARRAY_LEN(names)) return "service";
  return names[n++] = xstrdup(s);
}

static int l_post(lua_State *L) {
  int kind = kind_of(L, 1);
  luaL_checktype(L, 2, LUA_TTABLE);
  if (!events_wanted(kind)) return 0;
  struct event *ev = xcalloc(1, sizeof *ev);
  ev->kind = kind;
  lua_getfield(L, 2, "book");
  ev->book = lua_tointeger(L, -1);
  lua_getfield(L, 2, "service");
  if (lua_isstring(L, -1)) ev->service = service_name(lua_tostring(L, -1));
  lua_pop(L, 2);
  ev->ids = ids_of(L, 2, "ids", &ev->nids);
  ev->selection = ids_of(L, 2, "selection", &ev->nselection);
  events_post(ev);
  return 0;
}

int luaopen_evman(lua_State *L) {
  static const luaL_Reg fns[] = {{"add", l_add}, {"rm", l_rm}, {"post", l_post}, {NULL, NULL}};
  lua_newtable(L);
  lua_setfield(L, LUA_REGISTRYINDEX, CALLBACKS);
  lua_newtable(L);
  lua_setfield(L, LUA_REGISTRYINDEX, IDS);
  luaL_newlib(L, fns);
  return 1;
}

void l_evman_close(struct app *app) {
  events_unlisten_all(LOOP_LUA, dispatch);
  memset(count, 0, sizeof count);
}
