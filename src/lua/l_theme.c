/* lulibre.theme -- the interface's colours, by name.
 *
 *   lulibre.theme.border = "#9aa5ce"     or 0x9aa5ce
 *   lulibre.theme.bar_bg                 "#343a55"
 *   lulibre.theme()                      every name with its colour
 *
 * Names: dim accent warn error ok cursor_bg cursor_bg_blur visual_bg mark
 * title border (the line between windows) bar_bg bar_fg (a window's top
 * line; the focused window's is `accent` with `on_accent` text).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <lua.h>
#include <lauxlib.h>

#include "app.h"
#include "lua/bridge.h"
#include "lua/lapi.h"
#include "tui/tui.h"

static void push_colour(lua_State *L, int c) {
  char buf[16];
  snprintf(buf, sizeof buf, "#%06x", (unsigned)c & 0xffffff);
  lua_pushstring(L, buf);
}

static int theme_index_ui(lua_State *L) {
  const char *name = luaL_checkstring(L, 2);
  int *slot = theme_slot(name);
  if (!slot) return luaL_error(L, "unknown colour '%s'", name);
  push_colour(L, *slot);
  return 1;
}

static int theme_newindex_ui(lua_State *L) {
  const char *name = luaL_checkstring(L, 2);
  int *slot = theme_slot(name);
  if (!slot) return luaL_error(L, "unknown colour '%s'", name);
  long v;
  if (lua_isinteger(L, 3)) {
    v = (long)lua_tointeger(L, 3);
  } else {
    const char *s = luaL_checkstring(L, 3);
    char *end;
    if (*s == '#') s++;
    v = strtol(s, &end, 16);
    if (strlen(s) != 6 || *end) return luaL_error(L, "a colour is written \"#rrggbb\"");
  }
  if (v < 0 || v > 0xffffff) return luaL_error(L, "a colour is written \"#rrggbb\"");
  *slot = (int)v;
  struct tui *t = lapi_app(L)->tui;
  if (t && t->nc) tui_dirty(t);
  return 0;
}

static int theme_call_ui(lua_State *L) {
  lua_newtable(L);
  for (int i = 0; theme_name(i); i++) {
    push_colour(L, *theme_slot(theme_name(i)));
    lua_setfield(L, -2, theme_name(i));
  }
  return 1;
}

static int theme_index(lua_State *L) {
  return ui_call(L, theme_index_ui);
}

static int theme_newindex(lua_State *L) {
  return ui_call(L, theme_newindex_ui);
}

static int theme_call(lua_State *L) {
  return ui_call(L, theme_call_ui);
}

void l_theme_open(lua_State *L) {
  static const luaL_Reg mt[] = {
    {"__index", theme_index}, {"__newindex", theme_newindex}, {"__call", theme_call}, {NULL, NULL},
  };
  lua_newtable(L);
  luaL_newlib(L, mt);
  lua_setmetatable(L, -2);
  lua_setfield(L, -2, "theme");
}
