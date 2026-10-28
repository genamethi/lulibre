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
#include "core/queue.h"
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
  char *err;          /* the run did not start */
};

static void finished(struct app *app, void *arg) { /* Lua thread */
  struct iwait *w = arg;
  lua_State *L = sched_end_wait(w->task);
  if (L && w->err) {
    lua_pushnil(L);
    lua_pushstring(L, w->err);
    sched_wake(w->task, 2);
  } else if (L) {
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
  free(w->err);
  free(w);
}

/* interface thread (or the only thread): the run is over */
static void on_done(const struct index_stats *st, void *ud) {
  struct iwait *w = ud;
  w->stats = *st;
  w->stats.last_path = w->stats.last_error = NULL;
  queue_post(LOOP_LUA, finished, w);
}

static void headless_done(struct indexer *ix, const struct index_stats *st, void *ud) {
  struct iwait *w = ud;
  struct index_stats s = *st; /* st lives inside the indexer being freed */
  indexer_free(w->ix);
  on_done(&s, w);
}

/* The run did not start: the task hears why. */
static int not_started(struct iwait *w, char *err) {
  w->err = err;
  queue_post(LOOP_LUA, finished, w);
  return 0;
}

/* the options table (or nil), the iwait (an integer) */
static int start_ui(lua_State *L) {
  struct iwait *w = (struct iwait *)(intptr_t)luaL_checkinteger(L, 2);
  struct app *app = w->app;
  struct index_opts o = {0};
  app_open_db(app);
  app_index_opts(app, &o); /* the main thread */
  if (lua_istable(L, 1)) {
    lua_getfield(L, 1, "pages"); /* read this many pages of each file, not the option's number */
    if (lua_isinteger(L, -1) && lua_tointeger(L, -1) > 0) {
      o.pages = (int)lua_tointeger(L, -1);
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
        char *msg = xasprintf("filter: %s", err);
        free(err);
        return not_started(w, msg);
      }
      w->has_only = 1;
      o.only = &w->only;
    }
    lua_pop(L, 3);
  }
  char *err = NULL;
  if (app->tui && app->tui->nc) {
    if (tui_index(app->tui, &o, on_done, w, &err)) return not_started(w, err);
    return 0;
  }
  w->ix = indexer_start(app->loop, &app->db, &o, NULL, headless_done, w, &err);
  if (!w->ix) return not_started(w, err);
  return 0;
}

static int l_index(lua_State *L) {
  sched_require_task(L);
  struct iwait *w = xcalloc(1, sizeof *w);
  w->app = lapi_app(L);
  lua_settop(L, 1);
  lua_pushinteger(L, (lua_Integer)(intptr_t)w);
  w->task = sched_begin_wait(L);
  ui_send(L, start_ui, "index");
  return lua_yield(L, 0);
}

void l_index_open(lua_State *L) {
  lua_pushcfunction(L, l_index);
  lua_setfield(L, -2, "index");
}
