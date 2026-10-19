/* Copies of SQLite databases, made while others may be using them, and
 * their integrity.
 *
 *   lulibre.copy_db(src, dst [, opts])   true, or nil and a message
 *   lulibre.check_db(path)               true; false and the problems found
 *                                        (a list); nil and a message
 *
 * copy_db is SQLite's online backup: src is opened read-only and copied
 * page by page into dst, which is made or replaced; a writer holding src
 * for a moment is waited for. opts.amend is SQL run on dst once it is
 * copied, in one transaction, with the databases in opts.attach
 * ({ name = path }) attached read-only and ?1 bound to opts.value: how a
 * copy is fitted to what has changed since it was made, before it is put
 * back (lua/lulibre/backup.lua). opts.stubs names SQL functions the copy's
 * triggers call that only their own program has (calibre's title_sort):
 * they exist, so that the triggers compile, and fail if called, so an
 * amendment that would set one off fails instead of guessing. check_db is PRAGMA integrity_check, on a
 * connection opened read-only.
 *
 * Both run on a worker thread (so they must be called from a task), on
 * connections of the worker's own, opened and closed there, so nothing is
 * shared with the loop but the job itself. calibre's metadata.db is copied
 * and checked this way for lulibre.backup.
 */
#include <stdlib.h>
#include <string.h>

#include <lua.h>
#include <lauxlib.h>
#include <sqlite3.h>
#include <uv.h>

#include "app.h"
#include "core/util.h"
#include "db/db.h"
#include "lua/lapi.h"
#include "lua/sched.h"

#define MAX_ATTACH 4
#define MAX_STUBS 8
#define MAX_PROBLEMS 100 /* lines kept; integrity_check stops at 100 problems itself */

struct cjob {
  uv_work_t req;
  struct task *task;
  int check; /* check_db, not copy_db */
  char *src, *dst;
  char *amend, *value;
  char *as[MAX_ATTACH], *at[MAX_ATTACH];
  int nattach;
  char *stubs[MAX_STUBS];
  int nstubs;
  char *problems[MAX_PROBLEMS];
  int nproblems;
  char *err;
};

static int open_ro(const char *path, sqlite3 **h, char **err) {
  char *uri = db_uri(path, "ro");
  int rc = sqlite3_open_v2(uri, h, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, NULL);
  free(uri);
  if (rc != SQLITE_OK) {
    *err = xasprintf("%s: %s", path, *h ? sqlite3_errmsg(*h) : "cannot open");
    return -1;
  }
  sqlite3_busy_timeout(*h, 5000);
  return 0;
}

static void stub(sqlite3_context *ctx, int argc, sqlite3_value **argv) {
  (void)argc;
  (void)argv;
  char *msg = sqlite3_mprintf("%s() was called: it is the program's own, and lulibre does not have it",
                              (const char *)sqlite3_user_data(ctx));
  sqlite3_result_error(ctx, msg, -1);
  sqlite3_free(msg);
}

/* opts.amend on the copy: each statement in turn, ?1 bound to opts.value */
static void amend(struct cjob *j, sqlite3 *to) {
  for (int i = 0; i < j->nstubs; i++)
    sqlite3_create_function(to, j->stubs[i], -1, SQLITE_UTF8, j->stubs[i], stub, NULL, NULL);
  for (int i = 0; i < j->nattach && !j->err; i++) {
    char *uri = db_uri(j->at[i], "ro");
    char *sql = sqlite3_mprintf("ATTACH DATABASE %Q AS \"%w\"", uri, j->as[i]);
    if (sqlite3_exec(to, sql, NULL, NULL, NULL) != SQLITE_OK)
      j->err = xasprintf("attaching %s: %s", j->at[i], sqlite3_errmsg(to));
    sqlite3_free(sql);
    free(uri);
  }
  if (j->err) return;
  if (sqlite3_exec(to, "BEGIN", NULL, NULL, NULL) != SQLITE_OK) {
    j->err = xasprintf("%s: %s", j->dst, sqlite3_errmsg(to));
    return;
  }
  const char *sql = j->amend;
  while (sql && *sql && !j->err) {
    sqlite3_stmt *st = NULL;
    const char *tail = NULL;
    if (sqlite3_prepare_v2(to, sql, -1, &st, &tail) != SQLITE_OK) {
      j->err = xasprintf("amending %s: %s", j->dst, sqlite3_errmsg(to));
      break;
    }
    if (st) {
      if (sqlite3_bind_parameter_count(st) >= 1)
        sqlite3_bind_text(st, 1, j->value ? j->value : "", -1, SQLITE_STATIC);
      int rc;
      while ((rc = sqlite3_step(st)) == SQLITE_ROW) {
      }
      if (rc != SQLITE_DONE) j->err = xasprintf("amending %s: %s", j->dst, sqlite3_errmsg(to));
      sqlite3_finalize(st);
    }
    sql = tail;
  }
  sqlite3_exec(to, j->err ? "ROLLBACK" : "COMMIT", NULL, NULL, NULL);
  if (!j->err && sqlite3_get_autocommit(to) == 0) {
    j->err = xasprintf("amending %s: %s", j->dst, sqlite3_errmsg(to));
    sqlite3_exec(to, "ROLLBACK", NULL, NULL, NULL);
  }
}

static void copy_work(struct cjob *j) {
  sqlite3 *from = NULL, *to = NULL;
  if (open_ro(j->src, &from, &j->err) == 0) {
    if (sqlite3_open_v2(j->dst, &to, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_URI, NULL) != SQLITE_OK) {
      j->err = xasprintf("%s: %s", j->dst, to ? sqlite3_errmsg(to) : "cannot open");
    } else {
      sqlite3_busy_timeout(to, 5000);
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
      if (!j->err && j->amend) amend(j, to);
    }
  }
  sqlite3_close(from);
  sqlite3_close(to);
}

static void check_work(struct cjob *j) {
  sqlite3 *h = NULL;
  sqlite3_stmt *st = NULL;
  if (open_ro(j->src, &h, &j->err) == 0) {
    if (sqlite3_prepare_v2(h, "PRAGMA integrity_check", -1, &st, NULL) != SQLITE_OK) {
      j->err = xasprintf("%s: %s", j->src, sqlite3_errmsg(h));
    } else {
      int rc;
      /* a row may hold several problems, a line each */
      while ((rc = sqlite3_step(st)) == SQLITE_ROW) {
        const char *text = (const char *)sqlite3_column_text(st, 0);
        for (const char *p = text ? text : ""; *p && j->nproblems < MAX_PROBLEMS;) {
          size_t n = strcspn(p, "\n");
          /* "*** in database main ***" heads the list: not a problem itself */
          if (n && strncmp(p, "*** ", 4) != 0) j->problems[j->nproblems++] = xasprintf("%.*s", (int)n, p);
          p += n + (p[n] ? 1 : 0);
        }
      }
      /* a database too damaged to be read through says so here, not in rows */
      if (rc != SQLITE_DONE && j->nproblems < MAX_PROBLEMS) j->problems[j->nproblems++] = xstrdup(sqlite3_errmsg(h));
      sqlite3_finalize(st);
    }
  }
  sqlite3_close(h);
}

static void c_work(uv_work_t *req) {
  struct cjob *j = req->data;
  if (j->check) check_work(j);
  else copy_work(j);
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
    } else if (j->check && !(j->nproblems == 1 && !strcmp(j->problems[0], "ok"))) {
      lua_pushboolean(L, 0);
      lua_createtable(L, j->nproblems, 0);
      for (int i = 0; i < j->nproblems; i++) {
        lua_pushstring(L, j->problems[i]);
        lua_rawseti(L, -2, i + 1);
      }
      sched_wake(j->task, 2);
    } else {
      lua_pushboolean(L, 1);
      sched_wake(j->task, 1);
    }
  }
  free(j->src);
  free(j->dst);
  free(j->amend);
  free(j->value);
  for (int i = 0; i < j->nattach; i++) {
    free(j->as[i]);
    free(j->at[i]);
  }
  for (int i = 0; i < j->nstubs; i++) free(j->stubs[i]);
  for (int i = 0; i < j->nproblems; i++) free(j->problems[i]);
  free(j->err);
  free(j);
}

static int start(lua_State *L, struct cjob *j) {
  j->req.data = j;
  j->task = sched_begin_wait(L);
  uv_queue_work(lapi_app(L)->lloop, &j->req, c_work, c_after);
  return lua_yield(L, 0);
}

static int l_copy_db(lua_State *L) {
  const char *src = luaL_checkstring(L, 1), *dst = luaL_checkstring(L, 2);
  int opts = !lua_isnoneornil(L, 3);
  if (opts) luaL_checktype(L, 3, LUA_TTABLE);
  sched_require_task(L); /* raises outside a task */
  const char *amend_sql = NULL, *value = NULL;
  if (opts) {
    lua_getfield(L, 3, "amend");
    amend_sql = lua_isnil(L, -1) ? NULL : luaL_checkstring(L, -1);
    lua_getfield(L, 3, "value");
    value = lua_isnil(L, -1) ? NULL : luaL_checkstring(L, -1);
    lua_getfield(L, 3, "attach");
    if (!lua_isnil(L, -1)) luaL_checktype(L, -1, LUA_TTABLE);
  }
  struct cjob *j = xcalloc(1, sizeof *j);
  if (opts && lua_istable(L, -1)) {
    lua_pushnil(L);
    while (lua_next(L, -2)) {
      if (j->nattach == MAX_ATTACH || lua_type(L, -2) != LUA_TSTRING || lua_type(L, -1) != LUA_TSTRING) {
        for (int i = 0; i < j->nattach; i++) {
          free(j->as[i]);
          free(j->at[i]);
        }
        free(j);
        return luaL_error(L, "copy_db: attach is { name = path, ... }, at most %d", MAX_ATTACH);
      }
      j->as[j->nattach] = xstrdup(lua_tostring(L, -2));
      j->at[j->nattach++] = xstrdup(lua_tostring(L, -1));
      lua_pop(L, 1);
    }
  }
  if (opts) {
    lua_getfield(L, 3, "stubs");
    if (lua_istable(L, -1)) {
      for (lua_Integer i = 1; i <= MAX_STUBS && lua_type(L, -1) == LUA_TTABLE; i++) {
        if (lua_rawgeti(L, -1, i) != LUA_TSTRING) {
          lua_pop(L, 1);
          break;
        }
        j->stubs[j->nstubs++] = xstrdup(lua_tostring(L, -1));
        lua_pop(L, 1);
      }
    }
  }
  j->src = xstrdup(src);
  j->dst = xstrdup(dst);
  j->amend = amend_sql ? xstrdup(amend_sql) : NULL;
  j->value = value ? xstrdup(value) : NULL;
  return start(L, j);
}

static int l_check_db(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  sched_require_task(L);
  struct cjob *j = xcalloc(1, sizeof *j);
  j->check = 1;
  j->src = xstrdup(path);
  return start(L, j);
}

void l_copy_open(lua_State *L) {
  lua_pushcfunction(L, l_copy_db);
  lua_setfield(L, -2, "copy_db");
  lua_pushcfunction(L, l_check_db);
  lua_setfield(L, -2, "check_db");
}
