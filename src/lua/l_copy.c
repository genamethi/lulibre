/* Copies of SQLite databases, made while others may be using them.
 *
 *   lulibre.copy_db(src, dst)   true, or nil and a message
 *
 * SQLite's online backup, on a worker thread (so it must be called from a
 * task): src is opened read-only and copied page by page into dst, which is
 * made or replaced; a writer holding src for a moment is waited for. Both
 * connections are the worker's own, opened and closed there, so nothing is
 * shared with the loop but the job itself. calibre's metadata.db is copied
 * this way for lulibre.backup.
 */
#include <stdlib.h>

#include <lua.h>
#include <lauxlib.h>
#include <sqlite3.h>
#include <uv.h>

#include "app.h"
#include "core/util.h"
#include "db/db.h"
#include "lua/lapi.h"
#include "lua/sched.h"

struct cjob {
  uv_work_t req;
  struct task *task;
  char *src, *dst;
  char *err;
};

static void c_work(uv_work_t *req) {
  struct cjob *j = req->data;
  sqlite3 *from = NULL, *to = NULL;
  char *uri = db_uri(j->src, "ro");
  if (sqlite3_open_v2(uri, &from, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, NULL) != SQLITE_OK) {
    j->err = xasprintf("%s: %s", j->src, from ? sqlite3_errmsg(from) : "cannot open");
  } else if (sqlite3_open_v2(j->dst, &to, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, NULL) != SQLITE_OK) {
    j->err = xasprintf("%s: %s", j->dst, to ? sqlite3_errmsg(to) : "cannot open");
  } else {
    sqlite3_busy_timeout(from, 5000);
    sqlite3_backup *b = sqlite3_backup_init(to, "main", from, "main");
    if (!b) {
      j->err = xasprintf("%s: %s", j->dst, sqlite3_errmsg(to));
    } else {
      int rc, tries = 0;
      /* -1: every page in one step; a writer in the way is waited for */
      while ((rc = sqlite3_backup_step(b, -1)) == SQLITE_BUSY || rc == SQLITE_LOCKED) {
        if (++tries > 100) break;
        sqlite3_sleep(100);
      }
      if (rc != SQLITE_DONE) j->err = xasprintf("copying %s: %s", j->src, sqlite3_errstr(rc));
      sqlite3_backup_finish(b);
    }
  }
  free(uri);
  sqlite3_close(from);
  sqlite3_close(to);
}

static void c_after(uv_work_t *req, int status) {
  (void)status;
  struct cjob *j = req->data;
  lua_State *L = sched_end_wait(j->task);
  if (L) {
    if (j->err) {
      lua_pushnil(L);
      lua_pushstring(L, j->err);
      sched_wake(j->task, 2);
    } else {
      lua_pushboolean(L, 1);
      sched_wake(j->task, 1);
    }
  }
  free(j->src);
  free(j->dst);
  free(j->err);
  free(j);
}

static int l_copy_db(lua_State *L) {
  const char *src = luaL_checkstring(L, 1), *dst = luaL_checkstring(L, 2);
  sched_require_task(L); /* raises outside a task */
  struct cjob *j = xcalloc(1, sizeof *j);
  j->src = xstrdup(src);
  j->dst = xstrdup(dst);
  j->req.data = j;
  j->task = sched_begin_wait(L);
  uv_queue_work(lapi_app(L)->lloop, &j->req, c_work, c_after);
  return lua_yield(L, 0);
}

void l_copy_open(lua_State *L) {
  lua_pushcfunction(L, l_copy_db);
  lua_setfield(L, -2, "copy_db");
}
