#include "db/db.h"

#include <libgen.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "core/util.h"

#define SCHEMA_VERSION "1"

static int fail(struct db *db, char **err, const char *what) {
  *err = xasprintf("%s: %s", what, db->h ? sqlite3_errmsg(db->h) : "no database");
  return -1;
}

int db_exec(struct db *db, const char *sql, char **err) {
  char *msg = NULL;
  if (sqlite3_exec(db->h, sql, NULL, NULL, &msg) != SQLITE_OK) {
    *err = xasprintf("sql: %s", msg ? msg : "error");
    sqlite3_free(msg);
    return -1;
  }
  return 0;
}

int db_prepare(struct db *db, const char *sql, sqlite3_stmt **st, char **err) {
  if (sqlite3_prepare_v2(db->h, sql, -1, st, NULL) != SQLITE_OK) return fail(db, err, "prepare");
  return 0;
}

char *db_meta_get(struct db *db, const char *key) {
  sqlite3_stmt *st;
  char *out = NULL;
  if (sqlite3_prepare_v2(db->h, "SELECT value FROM meta WHERE key=?", -1, &st, NULL) != SQLITE_OK)
    return NULL;
  sqlite3_bind_text(st, 1, key, -1, SQLITE_STATIC);
  if (sqlite3_step(st) == SQLITE_ROW && sqlite3_column_text(st, 0))
    out = xstrdup((const char *)sqlite3_column_text(st, 0));
  sqlite3_finalize(st);
  return out;
}

int db_meta_set(struct db *db, const char *key, const char *val) {
  sqlite3_stmt *st;
  if (sqlite3_prepare_v2(db->h, "INSERT OR REPLACE INTO meta(key, value) VALUES(?, ?)", -1, &st,
                         NULL) != SQLITE_OK)
    return -1;
  sqlite3_bind_text(st, 1, key, -1, SQLITE_STATIC);
  sqlite3_bind_text(st, 2, val, -1, SQLITE_STATIC);
  int rc = sqlite3_step(st) == SQLITE_DONE ? 0 : -1;
  sqlite3_finalize(st);
  return rc;
}

/* The index holds nothing that cannot be regenerated, so a schema change
 * drops everything instead of migrating. */
static int reset_if_stale(struct db *db, char **err) {
  char *v = NULL;
  sqlite3_stmt *st;
  if (sqlite3_prepare_v2(db->h, "SELECT value FROM meta WHERE key='schema'", -1, &st, NULL) ==
      SQLITE_OK) {
    if (sqlite3_step(st) == SQLITE_ROW) v = xstrdup((const char *)sqlite3_column_text(st, 0));
    sqlite3_finalize(st);
  }
  int stale = v && strcmp(v, SCHEMA_VERSION) != 0;
  free(v);
  if (!stale) return 0;
  static const char *const drop[] = {
    "pages_fts", "books_fts", "lines", "pages", "files", "idents", "book_tags", "tags",
    "book_authors", "authors", "books", "marks", "meta",
  };
  for (size_t i = 0; i < ARRAY_LEN(drop); i++) {
    char *sql = xasprintf("DROP TABLE IF EXISTS %s", drop[i]);
    int rc = db_exec(db, sql, err);
    free(sql);
    if (rc) return rc;
  }
  return 0;
}

int db_open(struct db *db, const char *path, char **err) {
  memset(db, 0, sizeof *db);
  char *tmp = xstrdup(path);
  mkdir_p(dirname(tmp));
  free(tmp);
  if (sqlite3_open_v2(path, &db->h,
                      SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_URI, NULL) !=
      SQLITE_OK) {
    *err = xasprintf("cannot open index %s: %s", path, db->h ? sqlite3_errmsg(db->h) : "?");
    db_close(db);
    return -1;
  }
  db->path = xstrdup(path);
  sqlite3_busy_timeout(db->h, 5000);
  if (db_exec(db,
              "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON;"
              "PRAGMA temp_store=MEMORY; PRAGMA cache_size=-32000;",
              err) ||
      reset_if_stale(db, err) || db_exec(db, db_schema, err) || db_register_functions(db, err)) {
    db_close(db);
    return -1;
  }
  db_meta_set(db, "schema", SCHEMA_VERSION);
  return 0;
}

int db_open_reader(struct db *db, const char *path, char **err) {
  memset(db, 0, sizeof *db);
  if (sqlite3_open_v2(path, &db->h, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, NULL) != SQLITE_OK) {
    *err = xasprintf("cannot open index %s: %s", path, db->h ? sqlite3_errmsg(db->h) : "?");
    db_close(db);
    return -1;
  }
  db->path = xstrdup(path);
  sqlite3_busy_timeout(db->h, 5000);
  if (db_register_functions(db, err)) {
    db_close(db);
    return -1;
  }
  return 0;
}

int db_open_writer(struct db *db, const char *path, char **err) {
  memset(db, 0, sizeof *db);
  if (sqlite3_open_v2(path, &db->h, SQLITE_OPEN_READWRITE | SQLITE_OPEN_URI, NULL) != SQLITE_OK) {
    *err = xasprintf("cannot open index %s: %s", path, db->h ? sqlite3_errmsg(db->h) : "?");
    db_close(db);
    return -1;
  }
  db->path = xstrdup(path);
  sqlite3_busy_timeout(db->h, 5000);
  if (db_exec(db, "PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON; PRAGMA temp_store=MEMORY;", err) ||
      db_register_functions(db, err)) {
    db_close(db);
    return -1;
  }
  return 0;
}

void db_close(struct db *db) {
  if (db->h) sqlite3_close(db->h);
  db->h = NULL;
  free(db->path);
  db->path = NULL;
  /* db->L is closed in dbfuncs.c's destructor, run by sqlite3_close */
}
