/* Settings.
 *
 *   lulibre.o.pages = 8                 read or write an option by name
 *   lulibre.o.pages = nil               back to its default
 *
 *   lulibre.settings.get(name)          the same, as functions
 *   lulibre.settings.get()              every option: { name = value, ... }
 *   lulibre.settings.set(name, value)
 *   lulibre.settings.set{ pages = 8, ocr = "auto" }
 *   lulibre.settings.reset(name)        back to the default
 *   lulibre.settings.names()            the option names, in the order
 *                                       `lulibre config` writes them
 *   lulibre.settings.info(name)         { name=, value=, default=, type=
 *                                       "number" | "string" | "path",
 *                                       choices = { ... } or nil, help=,
 *                                       group= (the heading it is under) }
 *   lulibre.settings.paths()            where things are: { config_dir=, init=,
 *                                       scripts=, modules=, data_dir=, index=,
 *                                       library= }
 *
 * Reads and writes go to the option registry in core/config.c, so a value
 * set here is identical to the same name given with -o on the command line.
 * The options belong to the interface thread, which reads them as it draws,
 * so each call is carried there (lua/bridge.h).
 *
 * config_dir reads as the directory in effect even when the option itself
 * is empty. Setting it changes where scripts and modules are looked for
 * from then on; which init.lua is loaded was decided when lulibre started
 * (lulibre -C DIR, or $LULIBRE_CONFIG_DIR). */
#include <stdlib.h>
#include <string.h>

#include <lua.h>
#include <lauxlib.h>

#include "app.h"
#include "core/util.h"
#include "lua/bridge.h"
#include "lua/lapi.h"

static void push_value(lua_State *L, const struct config *c, const struct opt_def *o) {
  if (o->type == OPT_INT) {
    lua_pushinteger(L, config_int(c, o));
  } else if (!strcmp(o->name, "config_dir")) {
    char *dir = config_dir_path(c);
    lua_pushstring(L, dir);
    free(dir);
  } else {
    lua_pushstring(L, config_str(c, o));
  }
}

static const struct opt_def *check_option(lua_State *L, int idx) {
  const char *name = luaL_checkstring(L, idx);
  const struct opt_def *o = config_find(name);
  if (!o) luaL_error(L, "unknown option '%s'", name);
  return o;
}

/* name at idx, value at idx + 1; nil is the option's default */
static void set_option(lua_State *L, int idx) {
  struct app *app = lapi_app(L);
  const struct opt_def *o = check_option(L, idx);
  if (lua_isnoneornil(L, idx + 1)) {
    lua_settop(L, idx);
    lua_pushstring(L, o->def);
  }
  const char *val = luaL_tolstring(L, idx + 1, NULL);
  char *err = NULL;
  if (config_set(&app->cfg, o->name, val, &err)) {
    lua_pushstring(L, err);
    free(err);
    lua_error(L);
  }
  lua_pop(L, 1);
  if (!strcmp(o->name, "config_dir")) {
    /* modules of the new directory are found before those of the old */
    char *dir = config_dir_path(&app->cfg);
    lua_getglobal(L, "package");
    lua_getfield(L, -1, "path");
    lua_pushfstring(L, "%s/lua/?.lua;%s/lua/?/init.lua;%s", dir, dir, lua_tostring(L, -1));
    lua_setfield(L, -3, "path");
    lua_pop(L, 2);
    free(dir);
  }
}

static int opt_index_ui(lua_State *L) {
  push_value(L, &lapi_app(L)->cfg, check_option(L, 2));
  return 1;
}

static int opt_newindex_ui(lua_State *L) {
  set_option(L, 2);
  return 0;
}

static int s_get_ui(lua_State *L) {
  const struct config *c = &lapi_app(L)->cfg;
  if (!lua_isnoneornil(L, 1)) {
    push_value(L, c, check_option(L, 1));
    return 1;
  }
  size_t n;
  const struct opt_def *o = config_opts(&n);
  lua_createtable(L, 0, (int)n);
  for (size_t i = 0; i < n; i++) {
    push_value(L, c, &o[i]);
    lua_setfield(L, -2, o[i].name);
  }
  return 1;
}

static int s_set_ui(lua_State *L) {
  if (lua_istable(L, 1)) {
    lua_pushnil(L);
    while (lua_next(L, 1)) { /* key at -2, value at -1 */
      luaL_argcheck(L, lua_type(L, -2) == LUA_TSTRING, 1, "option names are strings");
      set_option(L, lua_gettop(L) - 1);
      lua_pop(L, 1);
    }
    return 0;
  }
  luaL_checkany(L, 2);
  set_option(L, 1);
  return 0;
}

static int s_reset_ui(lua_State *L) {
  const struct opt_def *o = check_option(L, 1);
  lua_settop(L, 1);
  lua_pushstring(L, o->def);
  set_option(L, 1);
  return 0;
}

static int s_names_ui(lua_State *L) {
  size_t n;
  const struct opt_def *o = config_opts(&n);
  lua_createtable(L, (int)n, 0);
  for (size_t i = 0; i < n; i++) {
    lua_pushstring(L, o[i].name);
    lua_rawseti(L, -2, (lua_Integer)i + 1);
  }
  return 1;
}

static int s_info_ui(lua_State *L) {
  const struct opt_def *o = check_option(L, 1);
  lua_createtable(L, 0, 6);
  lua_pushstring(L, o->name);
  lua_setfield(L, -2, "name");
  push_value(L, &lapi_app(L)->cfg, o);
  lua_setfield(L, -2, "value");
  if (o->type == OPT_INT) lua_pushinteger(L, atoi(o->def));
  else lua_pushstring(L, o->def);
  lua_setfield(L, -2, "default");
  lua_pushstring(L, o->type == OPT_INT ? "number" : o->type == OPT_PATH ? "path" : "string");
  lua_setfield(L, -2, "type");
  lua_pushstring(L, o->help);
  lua_setfield(L, -2, "help");
  /* the heading it comes under: the last one given at or before it */
  size_t n;
  const struct opt_def *all = config_opts(&n);
  const char *group = NULL;
  for (size_t i = 0; i < n && &all[i] <= o; i++)
    if (all[i].group) group = all[i].group;
  if (group) {
    lua_pushstring(L, group);
    lua_setfield(L, -2, "group");
  }
  if (o->choices) {
    lua_newtable(L);
    int k = 0;
    for (const char *p = o->choices; *p;) {
      size_t len = strcspn(p, "|");
      lua_pushlstring(L, p, len);
      lua_rawseti(L, -2, ++k);
      p += len + (p[len] == '|');
    }
    lua_setfield(L, -2, "choices");
  }
  return 1;
}

static int s_paths_ui(lua_State *L) {
  const struct config *c = &lapi_app(L)->cfg;
  char *dir = config_dir_path(c);
  const char *xdg = getenv("XDG_DATA_HOME");
  char *data = xdg && xdg[0] ? xasprintf("%s/lulibre", xdg) : path_expand("~/.local/share/lulibre");
  lua_createtable(L, 0, 7);
  lua_pushstring(L, dir);
  lua_setfield(L, -2, "config_dir");
  lua_pushfstring(L, "%s/init.lua", dir);
  lua_setfield(L, -2, "init");
  lua_pushfstring(L, "%s/scripts", dir);
  lua_setfield(L, -2, "scripts");
  lua_pushfstring(L, "%s/lua", dir);
  lua_setfield(L, -2, "modules");
  lua_pushstring(L, data);
  lua_setfield(L, -2, "data_dir");
  lua_pushstring(L, c->library);
  lua_setfield(L, -2, "library");
  if (c->library[0]) {
    char *index = config_index_path(c);
    lua_pushstring(L, index);
    lua_setfield(L, -2, "index");
    free(index);
  }
  free(dir);
  free(data);
  return 1;
}

#define ON_UI(name) \
  static int name(lua_State *L) { return ui_call(L, name##_ui); }
ON_UI(opt_index)
ON_UI(opt_newindex)
ON_UI(s_get)
ON_UI(s_set)
ON_UI(s_reset)
ON_UI(s_names)
ON_UI(s_info)
ON_UI(s_paths)

void l_opt_open(lua_State *L) {
  static const luaL_Reg settings[] = {
    {"get", s_get},     {"set", s_set},   {"reset", s_reset},
    {"names", s_names}, {"info", s_info}, {"paths", s_paths}, {NULL, NULL},
  };
  lua_newtable(L);
  lua_newtable(L);
  lua_pushcfunction(L, opt_index);
  lua_setfield(L, -2, "__index");
  lua_pushcfunction(L, opt_newindex);
  lua_setfield(L, -2, "__newindex");
  lua_setmetatable(L, -2);
  lua_setfield(L, -2, "o");

  luaL_newlib(L, settings);
  lua_setfield(L, -2, "settings");
}
