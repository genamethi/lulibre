/* Indexing, from Lua.
 *
 *   lulibre.index([{filter=, force=, retry=, pages=}])
 *
 * Extract text from files that are new or have changed (every file with
 * force; only books matching a filter with filter), and wait until it is
 * done. Returns { files=, queued=, ok=, failed=, missing=, seconds= }, or nil
 * and a message. If an indexing run is already under way in the interface,
 * this waits for that one instead of starting another.
 *
 * The indexer writes through the interface's own connection on the
 * interface's loop, so with the interface up the run is started over there
 * and its result sent back; without it everything is on the one loop. */
#include <stdlib.h>
#include <string.h>

#include <lua.h>
#include <lauxlib.h>

#include "app.h"
#include "core/util.h"
#include "db/query.h"
#include "index/indexer.h"
#include "lua/bridge.h"
#include "lua/lapi.h"
#include "lua/sched.h"
#include "tui/tui.h"

struct iwait {
  struct app *app;
  struct task *task;
  struct index_stats stats;
  struct query only;
  int has_only;
  struct indexer *ix; /* headless: ours to free */
};

static void finished(struct app *app, void *arg) { /* Lua thread */
  struct iwait *w = arg;
  lua_State *L = sched_end_wait(w->task);
  if (L) {
    const struct index_stats *s = &w->stats;
    lua_createtable(L, 0, 6);
    lua_pushinteger(L, s->files);
    lua_setfield(L, -2, "files");
    lua_pushinteger(L, s->queued);
    lua_setfield(L, -2, "queued");
    lua_pushinteger(L, s->ok);
    lua_setfield(L, -2, "ok");
    lua_pushinteger(L, s->failed);
    lua_setfield(L, -2, "failed");
    lua_pushinteger(L, s->missing);
    lua_setfield(L, -2, "missing");
    lua_pushnumber(L, s->elapsed);
    lua_setfield(L, -2, "seconds");
    sched_wake(w->task, 1);
  }
  if (w->has_only) query_free(&w->only);
  free(w);
}

/* interface thread (or the only thread): the run is over */
static void on_done(const struct index_stats *st, void *ud) {
  struct iwait *w = ud;
  w->stats = *st;
  w->stats.last_path = w->stats.last_error = NULL;
  bridge_lua(w->app, finished, w);
}

static void headless_done(struct indexer *ix, const struct index_stats *st, void *ud) {
  struct iwait *w = ud;
  struct index_stats s = *st; /* st lives inside the indexer being freed */
  indexer_free(w->ix);
  on_done(&s, w);
}

/* the options table (or nil), the iwait */
static int start_ui(lua_State *L) {
  struct iwait *w = lua_touserdata(L, 2);
  struct app *app = w->app;
  struct index_opts o = {0};
  app_open_db(app);
  o.pages = app->cfg.pages;
  o.layout_pages = app->cfg.layout_pages < o.pages ? app->cfg.layout_pages : o.pages;
  o.inflight = app_jobs(app) + app_jobs(app) / 2;
  if (lua_istable(L, 1)) {
    lua_getfield(L, 1, "pages"); /* read this many pages of each file, not the option's number */
    if (lua_isinteger(L, -1) && lua_tointeger(L, -1) > 0) {
      o.pages = (int)lua_tointeger(L, -1);
      if (o.layout_pages > o.pages) o.layout_pages = o.pages;
    }
    lua_pop(L, 1);
    lua_getfield(L, 1, "force");
    o.force = lua_toboolean(L, -1);
    lua_getfield(L, 1, "retry");
    o.retry = lua_toboolean(L, -1);
    lua_getfield(L, 1, "filter");
    if (lua_isstring(L, -1)) {
      char *err = NULL;
      if (query_compile_in(lua_tostring(L, -1), SCOPE_ALL, &w->only, &err)) {
        lua_pushfstring(L, "filter: %s", err);
        free(err);
        return lua_error(L);
      }
      w->has_only = 1;
      o.only = &w->only;
    }
    lua_pop(L, 3);
  }
  char *err = NULL;
  if (app->tui && app->tui->nc) {
    if (tui_index(app->tui, &o, on_done, w, &err)) {
      lua_pushstring(L, err);
      free(err);
      return lua_error(L);
    }
    return 0;
  }
  w->ix = indexer_start(app->loop, &app->db, &o, NULL, headless_done, w, &err);
  if (!w->ix) {
    lua_pushstring(L, err);
    free(err);
    return lua_error(L);
  }
  return 0;
}

static int l_index(lua_State *L) {
  sched_require_task(L);
  struct iwait *w = xcalloc(1, sizeof *w);
  w->app = lapi_app(L);
  lua_settop(L, 1);
  lua_pushlightuserdata(L, w);
  w->task = sched_begin_wait(L);
  if (ui_pcall(L, start_ui) != LUA_OK) {
    sched_abort_wait(w->task);
    if (w->has_only) query_free(&w->only);
    free(w);
    return lua_error(L);
  }
  return lua_yield(L, 0);
}

void l_index_open(lua_State *L) {
  lua_pushcfunction(L, l_index);
  lua_setfield(L, -2, "index");
}
