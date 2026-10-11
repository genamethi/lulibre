/* The main Lua state: created once at startup on the main thread, then
 * handed to the Lua thread when the interface starts (lua/bridge.h).
 * This file owns its construction and the package search path; each API
 * module registers itself from its own l_*.c file. */
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>

#include "app.h"
#include "config.h"
#include "version.h"
#include "core/util.h"
#include "lua/lapi.h"
#include "lua/sched.h"

struct app *lapi_app(lua_State *L) {
  return (*(struct lctx **)lua_getextraspace(L))->app;
}

struct db *lapi_db(lua_State *L) {
  struct app *app = lapi_app(L);
  app_open_db(app);
  return app->ldb ? app->ldb : &app->db;
}

uv_loop_t *lapi_loop(lua_State *L) {
  return lapi_app(L)->lloop;
}

static char *config_dir(void) {
  const char *xdg = getenv("XDG_CONFIG_HOME");
  return xdg && xdg[0] ? xasprintf("%s/lulibre", xdg) : path_expand("~/.config/lulibre");
}

/* Prepend to package.path / package.cpath. */
static void prepend(lua_State *L, const char *field, const char *entries) {
  lua_getglobal(L, "package");
  lua_getfield(L, -1, field);
  lua_pushfstring(L, "%s;%s", entries, lua_tostring(L, -1));
  lua_setfield(L, -3, field);
  lua_pop(L, 2);
}

/* Search order: the user's own modules, a source tree when running from one
 * (build/lulibre finds ./lua), the installed runtime, then the user's
 * luarocks tree so `luarocks install --local` rocks just work. */
static void setup_paths(lua_State *L) {
  sbuf p = SBUF_INIT, c = SBUF_INIT;
  char *cfg = config_dir();
  char *rocks = path_expand("~/.luarocks");
  const char *dev = getenv("LULIBRE_RUNTIME");
  char exe[4096], *tree = NULL;
  ssize_t len = readlink("/proc/self/exe", exe, sizeof exe - 1);
  if (len > 0) {
    exe[len] = '\0';
    char *slash = strrchr(exe, '/');
    if (slash) {
      *slash = '\0';
      tree = xasprintf("%s/../lua", exe);
      if (access(tree, R_OK) != 0) {
        free(tree);
        tree = NULL;
      }
    }
  }

  sb_printf(&p, "%s/lua/?.lua;%s/lua/?/init.lua", cfg, cfg);
  if (dev && dev[0]) sb_printf(&p, ";%s/?.lua;%s/?/init.lua", dev, dev);
  if (tree) sb_printf(&p, ";%s/?.lua;%s/?/init.lua", tree, tree);
  sb_printf(&p, ";%s/lua/?.lua;%s/lua/?/init.lua", LULIBRE_DATADIR, LULIBRE_DATADIR);
  sb_printf(&p, ";%s/share/lua/%s/?.lua;%s/share/lua/%s/?/init.lua", rocks, LULIBRE_LUA_VER,
            rocks, LULIBRE_LUA_VER);
  sb_printf(&c, "%s/lib/lua/%s/?.so", rocks, LULIBRE_LUA_VER);

  prepend(L, "path", p.s);
  prepend(L, "cpath", c.s);
  sb_free(&p);
  sb_free(&c);
  free(tree);
  free(cfg);
  free(rocks);
}

lua_State *lstate_new(struct app *app) {
  lua_State *L = luaL_newstate();
  if (!L) die("cannot create Lua state");
  app->L = L;
  app->lmain = xcalloc(1, sizeof *app->lmain);
  app->lmain->app = app;
  *(struct lctx **)lua_getextraspace(L) = app->lmain;
  luaL_openlibs(L);
  setup_paths(L);
  sched_init(app);

  lua_newtable(L);
  /* lulibre.version: "0.1.0-alpha"; lulibre.build: its parts and the kind of build */
  lua_pushstring(L, LULIBRE_VERSION);
  lua_setfield(L, -2, "version");
  lua_createtable(L, 0, 7);
  lua_pushstring(L, LULIBRE_VERSION);
  lua_setfield(L, -2, "version");
  lua_pushinteger(L, LULIBRE_VERSION_MAJOR);
  lua_setfield(L, -2, "major");
  lua_pushinteger(L, LULIBRE_VERSION_MINOR);
  lua_setfield(L, -2, "minor");
  lua_pushinteger(L, LULIBRE_VERSION_PATCH);
  lua_setfield(L, -2, "patch");
  lua_pushstring(L, LULIBRE_VERSION_PRE[0] ? LULIBRE_VERSION_PRE + 1 : "");
  lua_setfield(L, -2, "pre");
  lua_pushboolean(L, LULIBRE_DEBUG);
  lua_setfield(L, -2, "debug");
  lua_pushstring(L, LULIBRE_LUA_VER);
  lua_setfield(L, -2, "lua");
  lua_setfield(L, -2, "build");
  l_opt_open(L);
  l_job_open(L);
  l_db_open(L);
  l_doc_open(L);
  l_proc_open(L);
  l_hash_open(L);
  l_theme_open(L);
  l_match_open(L);
  l_ui_open(L);
  l_panel_open(L);
  l_uv_open(L);
  lua_setglobal(L, "lulibre");

  /* the part of the API written in Lua */
  lua_getglobal(L, "require");
  lua_pushliteral(L, "lulibre.prelude");
  if (lua_pcall(L, 1, 0, 0) != LUA_OK) {
    warnf("Lua runtime files not found; scripts will be limited (%s)", lua_tostring(L, -1));
    lua_pop(L, 1);
  }
  return L;
}

int lstate_run_init(struct app *app) {
  char *dir = config_dir();
  char *init = xasprintf("%s/init.lua", dir);
  int rc = 0;
  if (access(init, R_OK) == 0 && luaL_dofile(app->L, init) != LUA_OK) {
    warnf("%s", lua_tostring(app->L, -1));
    lua_pop(app->L, 1);
    rc = -1;
  }
  free(init);
  free(dir);
  return rc;
}

void lstate_close(struct app *app) {
  sched_free(app);
  if (app->L) lua_close(app->L);
  app->L = NULL;
  free(app->lmain);
  app->lmain = NULL;
}
