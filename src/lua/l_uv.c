/* libuv for scripts, on the loop lulibre runs Lua on.
 *
 * `require "luv"` (or `lulibre.uv`, which is the same module) loads the luv
 * rock from the Lua path as usual, with three differences made here before it
 * initialises: it is given the loop of the Lua thread instead of creating
 * its own, so its handles and the `lulibre` API's timers, subprocesses and
 * worker jobs are serviced together, and errors in its
 * callbacks are reported like any other script error instead of ending the
 * process, which is luv's default. And it is loaded once, at startup, by the
 * main Lua state: luv runs every callback on the state that loaded it, so
 * that state must outlive them all, which a task's coroutine does not. */
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>

#include <lua.h>
#include <lauxlib.h>

#include "app.h"
#include "config.h"
#include "core/util.h"
#include "lua/lapi.h"
#include "lua/sched.h"

typedef int (*luv_pcall_fn)(lua_State *L, int nargs, int nresults, int flags);

static int traceback(lua_State *L) {
  const char *msg = lua_tostring(L, 1);
  luaL_traceback(L, L, msg ? msg : "error (not a string)", 1);
  return 1;
}

/* luv's calling convention for callbacks: the function and its nargs
 * arguments are on the stack; return the result count, or minus the Lua
 * status on error with the stack restored. */
static int callback_pcall(lua_State *L, int nargs, int nresults, int flags) {
  int top = lua_gettop(L);
  int errfunc = top - nargs;
  lua_pushcfunction(L, traceback);
  lua_insert(L, errfunc);
  int ret = lua_pcall(L, nargs, nresults, errfunc);
  if (ret != LUA_OK) {
    lapi_report(lapi_app(L), 1, lua_tostring(L, -1));
    sched_note_failure(lapi_app(L));
    lua_pop(L, 1);
    lua_remove(L, errfunc);
    return -ret;
  }
  lua_remove(L, errfunc);
  if (nresults == LUA_MULTRET) nresults = lua_gettop(L) - top + nargs + 1;
  (void)flags;
  return nresults;
}

/* luv is looked for on package.cpath, after the luarocks tree the option
 * rocks_tree names, as require looks for any module */
static int preload_luv(lua_State *L) {
  const char *rocks = lapi_app(L)->cfg.rocks_tree;
  lua_getglobal(L, "package");
  lua_getfield(L, -1, "searchpath");
  lua_pushliteral(L, "luv");
  if (rocks && rocks[0]) lua_pushfstring(L, "%s/lib/lua/%s/?.so;", rocks, LULIBRE_LUA_VER);
  else lua_pushliteral(L, "");
  lua_getfield(L, -4, "cpath");
  lua_concat(L, 2);
  lua_call(L, 2, 2);
  if (lua_isnil(L, -2))
    return luaL_error(L, "luv is not on Lua's path (package.cpath) or in the luarocks tree rocks_tree names: %s",
                      lua_tostring(L, -1));
  const char *path = lua_tostring(L, -2);
  void *h = dlopen(path, RTLD_NOW | RTLD_GLOBAL);
  if (!h) return luaL_error(L, "cannot load %s: %s", path, dlerror());
  void (*set_loop)(lua_State *, uv_loop_t *) = dlsym(h, "luv_set_loop");
  void (*set_callback)(lua_State *, luv_pcall_fn) = dlsym(h, "luv_set_callback");
  lua_CFunction open = dlsym(h, "luaopen_luv");
  if (!set_loop || !open) return luaL_error(L, "%s does not look like luv", path);
  set_loop(L, lapi_loop(L));
  if (set_callback) set_callback(L, callback_pcall);
  lua_pushcfunction(L, open);
  lua_pushliteral(L, "luv");
  lua_call(L, 1, 1);
  return 1;
}

/* lulibre.uv, resolved on first use so luv is only loaded when wanted */
static int lulibre_index(lua_State *L) {
  const char *key = lua_tostring(L, 2);
  if (!key || strcmp(key, "uv") != 0) return 0;
  lua_getglobal(L, "require");
  lua_pushliteral(L, "luv");
  lua_call(L, 1, 1);
  lua_pushvalue(L, -1);
  lua_setfield(L, 1, "uv"); /* cache: later reads skip the metamethod */
  return 1;
}

/* Load luv now, on the main state, if it is installed. */
void l_uv_preload(lua_State *L) {
  lua_getglobal(L, "require");
  lua_pushliteral(L, "luv");
  if (lua_pcall(L, 1, 0, 0) != LUA_OK) lua_pop(L, 1); /* not installed: require says so when asked */
}

void l_uv_open(lua_State *L) {
  lua_getglobal(L, "package");
  lua_getfield(L, -1, "preload");
  lua_pushcfunction(L, preload_luv);
  lua_setfield(L, -2, "luv");
  lua_pop(L, 2);

  lua_newtable(L);
  lua_pushcfunction(L, lulibre_index);
  lua_setfield(L, -2, "__index");
  lua_setmetatable(L, -2);
}
