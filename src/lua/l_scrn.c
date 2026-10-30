/* Screens, from Lua: the scrnman global.
 *
 *   scrnman.create(name, {
 *     actions = { {"accept", "a", "accept the proposal"}, {"edit", "e <CR>", "edit the value"} },
 *     hint = { "accept", "edit" },
 *   })
 *
 * A screen is known by its name. Each action has a name, the keys it is on
 * by default (separated by spaces; one key, or two in a row) and what it
 * does, for ? and the hint. keymap.set(name, key, action) rebinds them as
 * it rebinds lulibre's places ("panel", "line" ...). A panel or list opened
 * for the screen (screen = name) hears a key bound to an action as the
 * action's name, and its bar shows the hint's actions with the keys they
 * are on. Making a screen again under its name replaces it. Screens go with
 * the lua_State: init.lua and the packaged modules make theirs again after
 * :restart-scripts. */
#include <stdlib.h>
#include <string.h>

#include <lua.h>
#include <lauxlib.h>

#include "core/util.h"
#include "lua/lapi.h"
#include "tui/tui.h"

#define MAX_ACTIONS 64

/* interface thread: (name, names, keys, abouts, hint), the four as lists */
static int create_ui(lua_State *L) {
  const char *name = luaL_checkstring(L, 1);
  const char *names[MAX_ACTIONS], *keys[MAX_ACTIONS], *abouts[MAX_ACTIONS], *hint[MAX_ACTIONS];
  int n = (int)lua_rawlen(L, 2), nh = (int)lua_rawlen(L, 5);
  if (n > MAX_ACTIONS) n = MAX_ACTIONS;
  if (nh > MAX_ACTIONS) nh = MAX_ACTIONS;
  for (int i = 0; i < n; i++) { /* the strings stay in the tables until ctx_add copies them */
    lua_rawgeti(L, 2, i + 1);
    lua_rawgeti(L, 3, i + 1);
    lua_rawgeti(L, 4, i + 1);
    names[i] = lua_tostring(L, -3);
    keys[i] = lua_tostring(L, -2);
    abouts[i] = lua_tostring(L, -1);
    lua_pop(L, 3);
  }
  for (int i = 0; i < nh; i++) {
    lua_rawgeti(L, 5, i + 1);
    hint[i] = lua_tostring(L, -1);
    lua_pop(L, 1);
  }
  char *err = NULL;
  if (ctx_add(name, n, names, keys, abouts, nh, hint, &err) < 0) {
    lua_pushstring(L, err);
    free(err);
    return lua_error(L);
  }
  return 0;
}

static int s_create(lua_State *L) {
  const char *name = luaL_checkstring(L, 1);
  luaL_argcheck(L, *name && !strchr(name, ' '), 1, "a screen's name is one word");
  /* keymap.set tells a place from modes by its letters */
  luaL_argcheck(L, strspn(name, "nv") != strlen(name), 1, "a screen's name is not made of n and v alone");
  luaL_argcheck(L, !ctx_is_own(name), 1, "the name of one of lulibre's places");
  luaL_checktype(L, 2, LUA_TTABLE);
  lua_settop(L, 2);
  lua_newtable(L); /* 3 names */
  lua_newtable(L); /* 4 keys */
  lua_newtable(L); /* 5 abouts */
  lua_newtable(L); /* 6 hint */
  lua_getfield(L, 2, "actions");
  int n = lua_istable(L, 7) ? (int)lua_rawlen(L, 7) : 0;
  luaL_argcheck(L, n <= MAX_ACTIONS, 2, "too many actions");
  for (int i = 1; i <= n; i++) {
    lua_rawgeti(L, 7, i);
    if (!lua_istable(L, -1)) return luaL_error(L, "actions[%d]: {name, keys, what it does}", i);
    for (int f = 1; f <= 3; f++) {
      lua_rawgeti(L, -1, f);
      if (f == 1 && (!lua_isstring(L, -1) || !*lua_tostring(L, -1)))
        return luaL_error(L, "actions[%d]: an action's name first", i);
      if (!lua_isnoneornil(L, -1) && lua_type(L, -1) != LUA_TSTRING)
        return luaL_error(L, "actions[%d]: name, keys and what it does are strings", i);
      lua_rawseti(L, 2 + f, i);
    }
    lua_pop(L, 1);
  }
  lua_getfield(L, 2, "hint");
  if (lua_istable(L, 8)) {
    int nh = (int)lua_rawlen(L, 8);
    for (int i = 1; i <= nh; i++) {
      lua_rawgeti(L, 8, i);
      int found = 0;
      for (int a = 1; a <= n && !found; a++) {
        lua_rawgeti(L, 3, a);
        found = lua_rawequal(L, -1, -2);
        lua_pop(L, 1);
      }
      if (!found) return luaL_error(L, "hint[%d]: %s is not one of the screen's actions", i, luaL_tolstring(L, -1, NULL));
      lua_rawseti(L, 6, i);
    }
  }
  lua_settop(L, 6);
  lua_remove(L, 2); /* name, names, keys, abouts, hint */
  return ui_send(L, create_ui, "scrnman.create");
}

int luaopen_scrnman(lua_State *L) {
  static const luaL_Reg fns[] = {{"create", s_create}, {NULL, NULL}};
  luaL_newlib(L, fns);
  return 1;
}
