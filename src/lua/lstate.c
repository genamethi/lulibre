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

static const char LUA_OWN_PATH[] = "lulibre.path", LUA_OWN_CPATH[] = "lulibre.cpath";

/* Lua's own package.path or cpath, as Lua and the environment set it, kept
 * in the registry without the entries relative to the current directory
 * (./?.lua): lulibre started in a folder must not load a module found there */
static void keep_own(lua_State *L, const char *field, const char *key) {
  lua_getglobal(L, "package");
  lua_getfield(L, -1, field);
  sbuf out = SBUF_INIT;
  const char *own = lua_tostring(L, -1);
  for (const char *p = own ? own : ""; *p;) {
    const char *end = strchr(p, ';');
    size_t n = end ? (size_t)(end - p) : strlen(p);
    if (n && strncmp(p, "./", 2) != 0) sb_printf(&out, "%s%.*s", out.len ? ";" : "", (int)n, p);
    p += n + (end ? 1 : 0);
  }
  lua_pushstring(L, out.s ? out.s : "");
  sb_free(&out);
  lua_setfield(L, LUA_REGISTRYINDEX, key);
  lua_pop(L, 2);
}

/* package[field] = entries, then Lua's own */
static void set_path(lua_State *L, const char *field, const char *key, const char *entries) {
  lua_getglobal(L, "package");
  lua_getfield(L, LUA_REGISTRYINDEX, key);
  const char *own = lua_tostring(L, -1);
  lua_pushfstring(L, "%s%s%s", entries, entries[0] && own[0] ? ";" : "", own);
  lua_setfield(L, -3, field);
  lua_pop(L, 2);
}

/* ---- a binary run from its source tree ----
 * build/lulibre finds its Lua files in the tree it was built in (below), so
 * that a build can be tried without installing it. The files are read when
 * they are first needed, which may be long after the program started; if
 * the tree has been changed to another version meanwhile (another branch
 * checked out), they no longer fit the binary and fail in ways that say
 * nothing of the cause. src/version.h in the tree says which version the
 * tree is now, so the mismatch can at least be named. */

static char tree_root[4096]; /* the tree this binary runs from, or "" */
static char runtime_lua[4096]; /* the packaged modules' directory: the tree's, LULIBRE_RUNTIME's or the installed one */

const char *lstate_runtime_modules(void) {
  return runtime_lua;
}

/* Where lulibre's files are installed: beside the binary when it runs from
 * an installed tree (<prefix>/bin/lulibre finds <prefix>/share/lulibre), so
 * that one build can be installed under any prefix; else the prefix
 * ./configure was given. */
const char *lstate_datadir(void) {
  static char dir[4096];
  if (dir[0]) return dir;
  snprintf(dir, sizeof dir, "%s", LULIBRE_DATADIR);
  char exe[4096];
  ssize_t len = readlink("/proc/self/exe", exe, sizeof exe - 1);
  if (len <= 0) return dir;
  exe[len] = '\0';
  char *slash = strrchr(exe, '/');
  if (!slash) return dir;
  *slash = '\0';
  char *share = xasprintf("%s/../share/lulibre", exe), *lua = xasprintf("%s/lua", share);
  char real[4096];
  if (access(lua, R_OK) == 0 && realpath(share, real)) snprintf(dir, sizeof dir, "%s", real);
  free(share);
  free(lua);
  return dir;
}

char *lstate_tree_mismatch(void) {
  if (!tree_root[0]) return NULL;
  char *path = xasprintf("%s/src/version.h", tree_root);
  FILE *f = fopen(path, "r");
  free(path);
  if (!f) return NULL;
  int major = -1, minor = -1, patch = -1;
  char pre[64] = "", line[256];
  while (fgets(line, sizeof line, f)) {
    sscanf(line, "#define LULIBRE_VERSION_MAJOR %d", &major);
    sscanf(line, "#define LULIBRE_VERSION_MINOR %d", &minor);
    sscanf(line, "#define LULIBRE_VERSION_PATCH %d", &patch);
    sscanf(line, "#define LULIBRE_VERSION_PRE \"%63[^\"]\"", pre);
  }
  fclose(f);
  if (major < 0 || minor < 0 || patch < 0) return NULL;
  char now[128];
  snprintf(now, sizeof now, "%d.%d.%d%s", major, minor, patch, pre);
  if (!strcmp(now, LULIBRE_VERSION)) return NULL;
  return xasprintf("this lulibre is %s, but the source tree it runs from (%s) is now %s: its Lua files belong to that "
                   "version and may fail with this binary. Quit, run make in that tree, and start again; or run an installed lulibre.",
                   LULIBRE_VERSION, tree_root, now);
}

/* The packaged modules: a source tree's when running from one (build/lulibre
 * finds ../lua), or LULIBRE_RUNTIME, and the installed ones otherwise, never
 * both (an installed module the tree has since renamed or removed would
 * still be found, stale). */
static void find_runtime(void) {
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
      } else {
        char *up = strrchr(exe, '/'); /* exe is .../build: the tree is one up */
        if (up && up > exe) snprintf(tree_root, sizeof tree_root, "%.*s", (int)(up - exe), exe);
      }
    }
  }
  if (dev && dev[0]) snprintf(runtime_lua, sizeof runtime_lua, "%s", dev);
  else if (tree) snprintf(runtime_lua, sizeof runtime_lua, "%s", tree);
  else snprintf(runtime_lua, sizeof runtime_lua, "%.4091s/lua", lstate_datadir());
  free(tree);
}

/* Search order (design 47): the packaged modules; the user's own (lua/ in
 * the configuration directory); the module prefix the setting mod_tree
 * names, outside a pixi environment; then Lua's own places. No user file
 * is found before a packaged module. Again whenever mod_tree changes. */
void lstate_paths(lua_State *L) {
  sbuf p = SBUF_INIT, c = SBUF_INIT;
  const char *cfg = lapi_app(L)->config_dir;
  sb_printf(&p, "%s/?.lua;%s/?/init.lua;%s/lua/?.lua;%s/lua/?/init.lua", runtime_lua, runtime_lua, cfg, cfg);
  char *tree = getenv("PIXI_ENVIRONMENT_NAME") ? NULL : lapi_setting_str(L, S_MOD_TREE);
  if (tree && tree[0]) {
    sb_printf(&p, ";%s/share/lua/%s/?.lua;%s/share/lua/%s/?/init.lua", tree, LULIBRE_LUA_VER, tree, LULIBRE_LUA_VER);
    sb_printf(&c, "%s/lib/lua/%s/?.so", tree, LULIBRE_LUA_VER);
  }
  free(tree);
  set_path(L, "path", LUA_OWN_PATH, p.s);
  set_path(L, "cpath", LUA_OWN_CPATH, c.s ? c.s : "");
  sb_free(&p);
  sb_free(&c);
}

lua_State *lstate_new(struct app *app) {
  lua_State *L = luaL_newstate();
  if (!L) die("cannot create Lua state");
  app->L = L;
  app->lmain = xcalloc(1, sizeof *app->lmain);
  app->lmain->app = app;
  *(struct lctx **)lua_getextraspace(L) = app->lmain;
  luaL_openlibs(L);
  luaL_requiref(L, "setman", luaopen_setman, 1);
  luaL_requiref(L, "evman", luaopen_evman, 1);
  lua_pop(L, 2);
  /* packaged modules written in C, found by require like the others */
  luaL_getsubtable(L, LUA_REGISTRYINDEX, LUA_PRELOAD_TABLE);
  lua_pushcfunction(L, luaopen_lulibre_reading);
  lua_setfield(L, -2, "lulibre.reading");
  lua_pop(L, 1);
  l_setman_fill(L, app->settings);
  keep_own(L, "path", LUA_OWN_PATH);
  keep_own(L, "cpath", LUA_OWN_CPATH);
  if (!runtime_lua[0]) find_runtime();
  lstate_paths(L);
  sched_init(app);

  lua_newtable(L);
  /* lulibre.version: "0.1.0-alpha"; lulibre.build: its parts and the kind of build */
  lua_pushstring(L, LULIBRE_VERSION);
  lua_setfield(L, -2, "version");
  lua_createtable(L, 0, 9);
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
  /* which build of the version this is, and the commit it was made from */
  lua_pushstring(L, lulibre_build_number);
  lua_setfield(L, -2, "number");
  lua_pushstring(L, lulibre_build_commit);
  lua_setfield(L, -2, "commit");
  lua_setfield(L, -2, "build");
  l_job_open(L);
  l_db_open(L);
  l_doc_open(L);
  l_proc_open(L);
  l_hash_open(L);
  l_copy_open(L);
  l_index_open(L);
  l_theme_open(L);
  l_match_open(L);
  l_learn_open(L);
  l_ui_open(L);
  l_panel_open(L);
  l_uv_open(L);
  lua_setglobal(L, "lulibre");
  l_uv_preload(L);

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
  char *init = xasprintf("%s/init.lua", app->config_dir);
  int rc = 0;
  if (access(init, R_OK) == 0 && luaL_dofile(app->L, init) != LUA_OK) {
    warnf("%s", lua_tostring(app->L, -1));
    lua_pop(app->L, 1);
    rc = -1;
  }
  /* what the prelude does once init.lua has had its say (lulibre._after_init) */
  lua_getglobal(app->L, "lulibre");
  if (lua_istable(app->L, -1)) {
    lua_getfield(app->L, -1, "_after_init");
    if (lua_isfunction(app->L, -1)) {
      if (lua_pcall(app->L, 0, 0, 0) != LUA_OK) {
        warnf("%s", lua_tostring(app->L, -1));
        lua_pop(app->L, 1);
      }
    } else {
      lua_pop(app->L, 1);
    }
  }
  lua_pop(app->L, 1);
  free(init);
  return rc;
}

void lstate_close(struct app *app) {
  l_evman_close(app);
  sched_free(app);
  if (app->L) lua_close(app->L);
  app->L = NULL;
  free(app->lmain);
  app->lmain = NULL;
}
