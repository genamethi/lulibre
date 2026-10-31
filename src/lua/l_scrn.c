/* Screens, from Lua: the scrnman global.
 *
 *   scrnman.create(name, {
 *     title = "Review",                -- in the bar and ?; by default the name
 *     actions = { {"accept", "a", "accept the proposal"}, {"edit", "e <CR>", "edit the value"} },
 *     hint = { "accept", "edit" },
 *     place = { kind = "band", size = 0.45 },
 *     tab = true,                      -- a tab of the bar, which runs :name
 *     views = { about = { kind = "band", size = 0.3 } },  -- beside the main one
 *   })
 *   scrnman.set(name, { hint = { "accept" }, title = "Proposals", place = { kind = "column" } })
 *
 * place says where the screen's views go, unless the one opening a view
 * says otherwise (uiman.panel's side and height): kind is band (along the
 * bottom), column (down the left), over (in the list's place), tiled
 * (beside the focused window, splitting it), float (a box above the
 * windows) or overlay (over all of them); size is its share of the
 * screen. A tab screen's view stands in the list's place while it is open,
 * and its tab in the bar shows it is; clicking the tab runs the command
 * named as the screen.
 *
 * A screen is known by its name. Each action has a name, the keys it is on
 * by default (separated by spaces; one key, or two in a row) and what it
 * does, for ? and the hint. keymap.set(name, key, action) rebinds them as
 * it rebinds lulibre's places ("panel", "line" ...). A panel or list opened
 * for the screen (screen = name) hears a key bound to an action as the
 * action's name, and its bar shows the hint's actions with the keys they
 * are on. Making a screen again under its name replaces it. Screens go with
 * the lua_State: init.lua and the packaged modules make theirs again after
 * :restart-scripts.
 *
 * scrnman.set changes the title and the hint line of a screen, or of one of
 * lulibre's places ("console", "pager", "picker", "select", "panel",
 * "line"): what a field leaves out stays, and an empty hint shows none.
 * Like keymap.set on lulibre's places, it holds until :restart-scripts,
 * when init.lua says it again. place moves the console (the next time it
 * opens) and the preview (band, column or tiled, at once).
 *
 * views names windows of the screen beside its main one: uiman.panel{screen
 * = name, view = "about"} opens one, where the screen says, and it closes
 * with the main one. */
#include <stdlib.h>
#include <string.h>

#include <lua.h>
#include <lauxlib.h>

#include "core/util.h"
#include "lua/lapi.h"
#include "tui/tui.h"

#define MAX_ACTIONS 64

static const char *const kinds[] = {"band", "column", "over", "tiled", "float", "overlay", NULL};
static const char sides[] = "blmtfo"; /* the panel's side for each */

/* interface thread: (name, names, keys, abouts, hint, title, side, size, tab,
 * views), the four after the name as lists */
static int create_ui(lua_State *L) {
  const char *name = luaL_checkstring(L, 1);
  const char *title = lua_tostring(L, 6);
  const char *side = lua_tostring(L, 7);
  float size = (float)lua_tonumber(L, 8);
  int tab = lua_toboolean(L, 9);
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
  int c = ctx_add(name, title, n, names, keys, abouts, nh, hint, side ? side[0] : 0, size, tab, &err);
  if (c < 0) {
    lua_pushstring(L, err);
    free(err);
    return lua_error(L);
  }
  for (lua_Integer v = 1; v <= (lua_Integer)lua_rawlen(L, 10); v++) {
    lua_rawgeti(L, 10, v);
    lua_rawgeti(L, -1, 1);
    lua_rawgeti(L, -2, 2);
    lua_rawgeti(L, -3, 3);
    ctx_add_view(c, lua_tostring(L, -3), lua_tostring(L, -2)[0], (float)lua_tonumber(L, -1));
    lua_pop(L, 4);
  }
  return 0;
}

/* {kind=, size=} at idx (nil for none): the panel's side for the kind, and
 * the share of the screen */
static void read_place(lua_State *L, int idx, const char *what, char side[2], float *size) {
  if (lua_isnil(L, idx)) return;
  if (!lua_istable(L, idx)) luaL_error(L, "%s: { kind = band | column | over | tiled | float | overlay, size = share }", what);
  lua_getfield(L, idx, "kind");
  const char *kind = lua_isnil(L, -1) ? "band" : lua_tostring(L, -1);
  int k = 0;
  while (kinds[k] && (!kind || strcmp(kinds[k], kind))) k++;
  if (!kinds[k]) luaL_error(L, "%s.kind: band, column, over, tiled, float or overlay", what);
  side[0] = sides[k];
  lua_getfield(L, idx, "size");
  if (!lua_isnil(L, -1)) {
    *size = (float)luaL_checknumber(L, -1);
    if (*size <= 0 || *size > 1) luaL_error(L, "%s.size: a share of the screen, above 0 and at most 1", what);
  }
  lua_pop(L, 2);
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
  /* 7 title, 8 side, 9 size, 10 tab */
  lua_getfield(L, 2, "title");
  if (!lua_isnil(L, 7) && lua_type(L, 7) != LUA_TSTRING) return luaL_error(L, "title: a string");
  lua_getfield(L, 2, "place");
  char side[2] = "";
  float size = 0;
  read_place(L, 8, "place", side, &size);
  lua_pop(L, 1);
  lua_pushstring(L, side);
  lua_pushnumber(L, size);
  lua_getfield(L, 2, "tab");
  lua_toboolean(L, -1) ? lua_pushboolean(L, 1) : lua_pushboolean(L, 0);
  lua_remove(L, -2);
  /* its views beside the main one: { {name, side, size}, ... } */
  lua_newtable(L);
  lua_getfield(L, 2, "views");
  int views = lua_gettop(L), nv = 0;
  if (lua_istable(L, views)) {
    lua_pushnil(L);
    while (lua_next(L, views)) {
      char vside[2] = "b";
      float vsize = 0;
      read_place(L, lua_gettop(L), luaL_checkstring(L, -2), vside, &vsize);
      lua_createtable(L, 3, 0);
      lua_pushvalue(L, -3);
      lua_rawseti(L, -2, 1);
      lua_pushstring(L, vside);
      lua_rawseti(L, -2, 2);
      lua_pushnumber(L, vsize);
      lua_rawseti(L, -2, 3);
      lua_rawseti(L, views - 1, ++nv);
      lua_pop(L, 1);
    }
  } else if (!lua_isnil(L, views)) {
    return luaL_error(L, "views: { name = { kind =, size = }, ... }");
  }
  lua_pop(L, 1);
  lua_remove(L, 2); /* name, names, keys, abouts, hint, title, side, size, tab, views */
  return ui_send(L, create_ui, "scrnman.create");
}

/* interface thread: (name, hint or nil, title or nil, side or nil, size) */
static int set_ui(lua_State *L) {
  const char *name = luaL_checkstring(L, 1), *hint[MAX_ACTIONS];
  int nh = lua_istable(L, 2) ? (int)lua_rawlen(L, 2) : -1;
  if (nh > MAX_ACTIONS) nh = MAX_ACTIONS;
  for (int i = 0; i < nh; i++) {
    lua_rawgeti(L, 2, i + 1);
    hint[i] = lua_tostring(L, -1); /* stays in the table */
    lua_pop(L, 1);
  }
  char *err = NULL;
  const char *side = lua_tostring(L, 4);
  if (ctx_set(name, lua_tostring(L, 3), nh, hint, side ? side[0] : 0, (float)lua_tonumber(L, 5), &err) < 0) {
    lua_pushstring(L, err);
    free(err);
    return lua_error(L);
  }
  struct tui *t = lapi_app(L)->tui;
  if (side && t && t->root && !strcmp(name, "preview")) wm_place_preview(t);
  return 0;
}

static int s_set(lua_State *L) {
  luaL_checkstring(L, 1);
  luaL_checktype(L, 2, LUA_TTABLE);
  lua_settop(L, 2);
  lua_getfield(L, 2, "hint");
  if (lua_istable(L, 3)) {
    int nh = (int)lua_rawlen(L, 3);
    luaL_argcheck(L, nh <= MAX_ACTIONS, 2, "too many actions in the hint");
    for (int i = 1; i <= nh; i++) {
      lua_rawgeti(L, 3, i);
      if (lua_type(L, -1) != LUA_TSTRING) return luaL_error(L, "hint[%d]: an action's name", i);
      lua_pop(L, 1);
    }
  } else if (!lua_isnil(L, 3)) {
    return luaL_error(L, "hint: a list of the actions to show");
  }
  lua_getfield(L, 2, "title");
  if (!lua_isnil(L, 4) && lua_type(L, 4) != LUA_TSTRING) return luaL_error(L, "title: a string");
  lua_getfield(L, 2, "place");
  char side[2] = "";
  float size = 0;
  read_place(L, 5, "place", side, &size);
  lua_pop(L, 1);
  if (side[0]) lua_pushstring(L, side);
  else lua_pushnil(L);
  lua_pushnumber(L, size);
  lua_remove(L, 2); /* name, hint, title, side, size */
  return ui_send(L, set_ui, "scrnman.set");
}

int luaopen_scrnman(lua_State *L) {
  static const luaL_Reg fns[] = {{"create", s_create}, {"set", s_set}, {NULL, NULL}};
  luaL_newlib(L, fns);
  return 1;
}
