/* Indexing, from Lua.
 *
 *   lulib.index([{filter=, force=, retry=, pages=}])
 *
 * Extract text from files that are new or have changed (every file with
 * force; only books matching a filter with filter), and wait until it is
 * done. Returns { files=, queued=, ok=, failed=, missing=, seconds= }, or nil
 * and a message. If an indexing run is already under way in the interface,
 * this waits for that one instead of starting another.
 *
 * The run is the background thread's (work.h); its options are taken from
 * the settings on the main thread, where the request goes first. */
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
#include "work.h"

struct iwait {
  struct app *app;
  struct task *task;
  struct index_stats stats;
  char *err; /* the run did not start */
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
  free(w->err);
  free(w);
}

/* the background thread: the run is over, or did not start */
static void on_done(const struct index_stats *st, const char *err, void *ud) {
  struct iwait *w = ud;
  if (st) w->stats = *st;
  w->err = err ? xstrdup(err) : NULL;
  queue_post(LOOP_LUA, finished, w);
}

/* the options table (or nil), the iwait (an integer); the main thread */
static int start_ui(lua_State *L) {
  struct iwait *w = (struct iwait *)(intptr_t)luaL_checkinteger(L, 2);
  int pages = 0, force = 0, retry = 0;
  const char *filter = NULL;
  if (lua_istable(L, 1)) {
    lua_getfield(L, 1, "pages"); /* read this many pages of each file, not the option's number */
    if (lua_isinteger(L, -1) && lua_tointeger(L, -1) > 0) pages = (int)lua_tointeger(L, -1);
    lua_getfield(L, 1, "force");
    force = lua_toboolean(L, -1);
    lua_getfield(L, 1, "retry");
    retry = lua_toboolean(L, -1);
    lua_getfield(L, 1, "filter");
    if (lua_isstring(L, -1)) filter = lua_tostring(L, -1);
  }
  char *err = NULL;
  if (work_index(w->app, pages, force, retry, filter, on_done, w, &err)) {
    w->err = xasprintf("filter: %s", err);
    free(err);
    queue_post(LOOP_LUA, finished, w);
  }
  return 0;
}

static int l_index(lua_State *L) {
  sched_require_task(L);
  struct iwait *w = xcalloc(1, sizeof *w);
  w->app = lapi_app(L);
  lapi_db(L); /* the index open, and the library with it */
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
