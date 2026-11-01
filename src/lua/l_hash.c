/* Content hashes, for telling whether two files hold the same bytes.
 *
 *   utils.md5(path)   32 hex digits, or nil and a message
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
#include "db/db.h"
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

static void h_after(uv_work_t *req, int status) {
  struct hjob *j = req->data;
  if (!j->err) db_hash_put(j->db->h, j->path, j->size, j->mtime, j->hex);
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
  char hex[33];
  if (db_hash_get(db->h, path, (long long)sb.st_size, db_mtime_ns(&sb), hex)) {
    lua_pushstring(L, hex);
    return 1;
  }
  sched_require_task(L); /* raises outside a task */
  struct hjob *j = xcalloc(1, sizeof *j);
  j->db = db;
  j->path = xstrdup(path);
  j->size = (long long)sb.st_size;
  j->mtime = db_mtime_ns(&sb);
  j->req.data = j;
  j->task = sched_begin_job(L);
  uv_queue_work(app->lloop, &j->req, h_work, h_after);
  return lua_yield(L, 0);
}

void l_hash_open(lua_State *L) {
  lua_pushcfunction(L, l_md5);
  lua_setfield(L, -2, "md5");
}
