/* lulibre.o -- options, as in `lulibre.o.pages = 8`. Reads and writes go
 * straight to the option registry in core/config.c, so anything set here is
 * identical to the same name given with -o on the command line. */
#include <stdlib.h>

#include <lua.h>
#include <lauxlib.h>

#include "app.h"
#include "lua/bridge.h"
#include "lua/lapi.h"

static int opt_index_ui(lua_State *L) {
  const char *name = luaL_checkstring(L, 2);
  const struct opt_def *o = config_find(name);
  if (!o) return luaL_error(L, "unknown option '%s'", name);
  const struct config *c = &lapi_app(L)->cfg;
  if (o->type == OPT_INT) lua_pushinteger(L, config_int(c, o));
  else lua_pushstring(L, config_str(c, o));
  return 1;
}

static int opt_newindex_ui(lua_State *L) {
  const char *name = luaL_checkstring(L, 2);
  const char *val = luaL_tolstring(L, 3, NULL);
  char *err = NULL;
  if (config_set(&lapi_app(L)->cfg, name, val, &err)) {
    lua_pushstring(L, err);
    free(err);
    return lua_error(L);
  }
  return 0;
}

/* The options belong to the interface thread, which reads them as it draws. */
static int opt_index(lua_State *L) {
  return ui_call(L, opt_index_ui);
}

static int opt_newindex(lua_State *L) {
  return ui_call(L, opt_newindex_ui);
}

void l_opt_open(lua_State *L) {
  lua_newtable(L);
  lua_newtable(L);
  lua_pushcfunction(L, opt_index);
  lua_setfield(L, -2, "__index");
  lua_pushcfunction(L, opt_newindex);
  lua_setfield(L, -2, "__newindex");
  lua_setmetatable(L, -2);
  lua_setfield(L, -2, "o");
}
