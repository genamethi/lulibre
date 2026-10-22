/* Content hashes, for telling whether two files hold the same bytes.
 *
 *   lulibre.md5(path)   32 hex digits, or nil and a message
 *
 * The first call for a file reads it on a worker thread (so it must be made
 * from a task) and remembers the answer in the index; later calls return at
 * once for as long as the file's size and modification time are unchanged.
 * Several tasks may hash at the same time.
 */
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include <lua.h>
#include <lauxlib.h>
#include <uv.h>

#include "app.h"
#include "core/md5.h"
#include "core/util.h"
#include "lua/lapi.h"
#include "lua/sched.h"

struct hjob {
  uv_work_t req;
  struct db *db;
  struct task *task;
  char *path;
  long long size, mtime;
  char hex[33];
  int err;
};

static void h_work(uv_work_t *req) {
  struct hjob *j = req->data;
  if (md5_file(j->path, j->hex)) j->err = errno ? errno : EIO;
}

static void remember(struct db *db, const struct hjob *j) {
  sqlite3_stmt *st;
  if (sqlite3_prepare_v2(db->h, "INSERT OR REPLACE INTO hashes(path, size, mtime, md5) VALUES(?, ?, ?, ?)",
                         -1, &st, NULL) != SQLITE_OK)
    return;
  sqlite3_bind_text(st, 1, j->path, -1, SQLITE_STATIC);
  sqlite3_bind_int64(st, 2, j->size);
  sqlite3_bind_int64(st, 3, j->mtime);
  sqlite3_bind_text(st, 4, j->hex, -1, SQLITE_STATIC);
  sqlite3_step(st);
  sqlite3_finalize(st);
}

static void h_after(uv_work_t *req, int status) {
  struct hjob *j = req->data;
  if (!j->err) remember(j->db, j);
  lua_State *L = sched_end_job(j->task);
  if (L) {
    if (j->err) {
      lua_pushnil(L);
      lua_pushfstring(L, "%s: %s", j->path, errstr(j->err));
      sched_wake(j->task, 2);
    } else {
      lua_pushstring(L, j->hex);
      sched_wake(j->task, 1);
    }
  }
  free(j->path);
  free(j);
}

/* Modification time to the nanosecond, so a file rewritten within the same
 * second as it was hashed is still seen as changed. */
static long long mtime_ns(const struct stat *sb) {
  return (long long)sb->st_mtim.tv_sec * 1000000000LL + sb->st_mtim.tv_nsec;
}

static int l_md5(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  struct app *app = lapi_app(L);
  struct stat sb;
  if (stat(path, &sb)) {
    lua_pushnil(L);
    lua_pushfstring(L, "%s: %s", path, errstr(errno));
    return 2;
  }
  struct db *db = lapi_db(L);
  sqlite3_stmt *st;
  if (sqlite3_prepare_v2(db->h, "SELECT md5 FROM hashes WHERE path = ? AND size = ? AND mtime = ?",
                         -1, &st, NULL) == SQLITE_OK) {
    sqlite3_bind_text(st, 1, path, -1, SQLITE_STATIC);
    sqlite3_bind_int64(st, 2, (sqlite3_int64)sb.st_size);
    sqlite3_bind_int64(st, 3, (sqlite3_int64)mtime_ns(&sb));
    int hit = sqlite3_step(st) == SQLITE_ROW;
    if (hit) lua_pushstring(L, (const char *)sqlite3_column_text(st, 0));
    sqlite3_finalize(st);
    if (hit) return 1;
  }
  sched_require_task(L); /* raises outside a task */
  struct hjob *j = xcalloc(1, sizeof *j);
  j->db = db;
  j->path = xstrdup(path);
  j->size = (long long)sb.st_size;
  j->mtime = mtime_ns(&sb);
  j->req.data = j;
  j->task = sched_begin_job(L);
  uv_queue_work(app->lloop, &j->req, h_work, h_after);
  return lua_yield(L, 0);
}

void l_hash_open(lua_State *L) {
  lua_pushcfunction(L, l_md5);
  lua_setfield(L, -2, "md5");
}
