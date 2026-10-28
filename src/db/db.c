#include "db/db.h"

#include <libgen.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "core/util.h"

#define SCHEMA_VERSION "4"

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

/* A schema change drops what the index derived (from the library, the
 * files, the readings) instead of migrating it; what nothing can derive
 * again stays: the online answers, the sync folder's files, kv. */
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
  /* every view and table of the index: views first, then full-text tables
   * (which take their own tables with them: IF EXISTS passes over those) */
  sbuf sql = SBUF_INIT;
  if (sqlite3_prepare_v2(db->h,
                         "SELECT type, name FROM main.sqlite_master WHERE type IN ('table', 'view')"
                         " AND name NOT LIKE 'sqlite_%' AND name NOT IN ('lookups', 'staged', 'kv')"
                         " ORDER BY type = 'view' DESC, sql LIKE 'CREATE VIRTUAL%' DESC",
                         -1, &st, NULL) == SQLITE_OK) {
    while (sqlite3_step(st) == SQLITE_ROW)
      sb_printf(&sql, "DROP %s IF EXISTS \"%s\";", (const char *)sqlite3_column_text(st, 0),
                (const char *)sqlite3_column_text(st, 1));
    sqlite3_finalize(st);
  }
  int rc = sql.s ? db_exec(db, sql.s, err) : 0;
  sb_free(&sql);
  return rc;
}

/* ---- the journal: every operation on the library, one lifecycle
 * (design 25, 26, 27). It is lulibre's record of what it did, not derived
 * from anything, so it lives in a file of its own beside the index
 * ("<index>.journal.db") where rebuilding or deleting the index cannot
 * touch it. It is attached to each read-write connection as `history`. ----
 *
 * A row is one field of one book changed (old and new), or one structural
 * command (argv, as calibredb's arguments joined by tabs); a batch is one
 * operation. need: enum op_need; state: enum op_state. proposal, proposed
 * and source: where the value came from, for a decision taken in review.
 * undoes: the batch an undo puts back. */
static const char history_schema[] =
  "PRAGMA history.journal_mode=WAL;"
  "CREATE TABLE IF NOT EXISTS history.journal("
  " id INTEGER PRIMARY KEY, batch INTEGER NOT NULL, label TEXT, need INTEGER NOT NULL DEFAULT 0,"
  " store TEXT NOT NULL, state INTEGER NOT NULL, error TEXT, ts INTEGER,"
  " book INTEGER, field TEXT, old TEXT, new TEXT, argv TEXT,"
  " proposal INTEGER, proposed TEXT, source TEXT, undoes INTEGER);"
  "CREATE INDEX IF NOT EXISTS history.journal_batch ON journal(batch);"
  "CREATE INDEX IF NOT EXISTS history.journal_book ON journal(book, field);";

/* ---- custom metadata: fields of your own beside calibre's (#partof,
 * #part ...), additive: calibre's database is never changed for them. In a
 * file of their own beside the index ("<index>.custom.db"), attached as
 * `custom`; written through lulibre.edit like any field, so journaled. ---- */
static const char custom_schema[] =
  "PRAGMA custom.journal_mode=WAL;"
  /* the fields: name as calibre writes a custom column's (#partof); type text,
   * number, date or list (several values) */
  "CREATE TABLE IF NOT EXISTS custom.fields("
  " name TEXT PRIMARY KEY, type TEXT NOT NULL DEFAULT 'text', help TEXT, created INTEGER);"
  /* the values: one row each (a list's in order) */
  "CREATE TABLE IF NOT EXISTS custom.data("
  " book INTEGER NOT NULL, field TEXT NOT NULL, ord INTEGER NOT NULL DEFAULT 0, value TEXT NOT NULL,"
  " source TEXT, ts INTEGER, PRIMARY KEY(book, field, ord)) WITHOUT ROWID;"
  "CREATE INDEX IF NOT EXISTS custom.data_field ON data(field, value);";

static char *beside(const char *index, const char *what) {
  size_t n = strlen(index);
  if (n > 3 && !strcmp(index + n - 3, ".db")) return xasprintf("%.*s.%s.db", (int)(n - 3), index, what);
  return xasprintf("%s.%s.db", index, what);
}

/* Where the journal of the index at `index` is kept. malloc'd. */
static char *db_history_path(const char *index) {
  return beside(index, "journal");
}

/* Where the custom fields (#partof ...) of the index at `index` are kept. */
static char *db_custom_path(const char *index) {
  return beside(index, "custom");
}

/* mode: "rwc" (made if it is not there), "rw", "ro" */
static int attach(struct db *db, const char *path, const char *as, const char *mode, char **err);

static int attach_history(struct db *db, int create, char **err) {
  if (!strncmp(db->path, "file:", 5) || !strcmp(db->path, ":memory:")) return 0;
  char *path = db_history_path(db->path);
  int rc = attach(db, path, "history", create ? "rwc" : "rw", err);
  free(path);
  return rc;
}

static int attach_custom(struct db *db, const char *mode, char **err) {
  if (!strncmp(db->path, "file:", 5) || !strcmp(db->path, ":memory:")) return 0;
  char *path = db_custom_path(db->path);
  int rc = attach(db, path, "custom", mode, err);
  free(path);
  return rc;
}

char *db_uri(const char *path, const char *mode) {
  size_t n = strlen(path);
  char *esc = xmalloc(3 * n + 1), *o = esc;
  for (const char *p = path; *p; p++) {
    if (*p == '%' || *p == '?' || *p == '#') o += sprintf(o, "%%%02x", (unsigned char)*p);
    else *o++ = *p;
  }
  *o = 0;
  char *uri = xasprintf("file:%s?mode=%s", esc, mode);
  free(esc);
  return uri;
}

static int attach(struct db *db, const char *path, const char *as, const char *mode, char **err) {
  char *uri = db_uri(path, mode);
  char *sql = xasprintf("ATTACH DATABASE ?1 AS %s", as);
  sqlite3_stmt *st = NULL;
  int rc = db_prepare(db, sql, &st, err);
  free(sql);
  if (!rc) {
    sqlite3_bind_text(st, 1, uri, -1, SQLITE_STATIC);
    if (sqlite3_step(st) != SQLITE_DONE) {
      *err = xasprintf("cannot open %s: %s", path, sqlite3_errmsg(db->h));
      rc = -1;
    }
    sqlite3_finalize(st);
  }
  free(uri);
  return rc;
}

int db_open(struct db *db, const char *path, char **err) {
  memset(db, 0, sizeof *db);
  db_functions_everywhere();
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
  sqlite3_busy_timeout(db->h, DB_BUSY_MS);
  if (db_exec(db,
              "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON;"
              "PRAGMA temp_store=MEMORY; PRAGMA cache_size=-32000;",
              err) ||
      reset_if_stale(db, err) || db_exec(db, db_schema, err) || attach_history(db, 1, err) ||
      db_exec(db, history_schema, err) || attach_custom(db, "rwc", err) ||
      db_exec(db, custom_schema, err)) {
    db_close(db);
    return -1;
  }
  db_meta_set(db, "schema", SCHEMA_VERSION);
  return 0;
}

int db_open_reader(struct db *db, const char *path, char **err) {
  memset(db, 0, sizeof *db);
  db_functions_everywhere();
  if (sqlite3_open_v2(path, &db->h, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, NULL) != SQLITE_OK) {
    *err = xasprintf("cannot open index %s: %s", path, db->h ? sqlite3_errmsg(db->h) : "?");
    db_close(db);
    return -1;
  }
  db->path = xstrdup(path);
  sqlite3_busy_timeout(db->h, DB_BUSY_MS);
  /* the custom fields, for filters on them (the file is made by db_open) */
  if (attach_custom(db, "ro", err)) {
    db_close(db);
    return -1;
  }
  return 0;
}

int db_open_writer(struct db *db, const char *path, char **err) {
  memset(db, 0, sizeof *db);
  db_functions_everywhere();
  if (sqlite3_open_v2(path, &db->h, SQLITE_OPEN_READWRITE | SQLITE_OPEN_URI, NULL) != SQLITE_OK) {
    *err = xasprintf("cannot open index %s: %s", path, db->h ? sqlite3_errmsg(db->h) : "?");
    db_close(db);
    return -1;
  }
  db->path = xstrdup(path);
  sqlite3_busy_timeout(db->h, DB_BUSY_MS);
  if (db_exec(db, "PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON; PRAGMA temp_store=MEMORY;", err) ||
      attach_history(db, 0, err) || attach_custom(db, "rw", err)) {
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
}
