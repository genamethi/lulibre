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
 * again stays: the sync folder's files, kv. */
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
                         " AND name NOT LIKE 'sqlite_%' AND name NOT IN ('staged', 'kv')"
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
  /* a snapshot is a position in the journal; its values, those a copy of
   * calibre's database had that the journal didn't see (lulib._snapshots) */
  "CREATE TABLE IF NOT EXISTS history.snapshots("
  " id INTEGER PRIMARY KEY, name TEXT, ts INTEGER, upto INTEGER, auto INTEGER, retired INTEGER, note TEXT);"
  "CREATE TABLE IF NOT EXISTS history.snapshot_values(snap INTEGER, book INTEGER, field TEXT, value TEXT);"
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

/* ---- wits: a value for a book's field, with the source that gave it,
 * waiting for review (lua/wit.lua). In a file of their own beside the
 * index ("<index>.wit.db"), attached as `wit` for the filter is:proposed;
 * wit writes it through a connection of its own. Per book and field, alt 1
 * is the first-ranked; agree and disagree name the sources that agree and
 * differ, comma-separated; start and stop, where in the file's text (its
 * txt) the value was found; review, the review it belongs to (wit.lua);
 * hidden, shown only by a deep review; decision ("accept" or "reject") and
 * edited, what the review has marked and not yet written; op, set on a
 * rewrite of the field (wit.add), which making proposals anew leaves. ---- */
static const char wit_schema[] =
  "PRAGMA wit.journal_mode=WAL;"
  "CREATE TABLE IF NOT EXISTS wit.reviews(id INTEGER PRIMARY KEY, name TEXT, opened INTEGER NOT NULL DEFAULT 0);"
  "CREATE TABLE IF NOT EXISTS wit.wits("
  " id INTEGER PRIMARY KEY, review INTEGER NOT NULL DEFAULT 1, book INTEGER NOT NULL, field TEXT NOT NULL,"
  " value TEXT, source TEXT NOT NULL, alt INTEGER NOT NULL, score REAL, agree TEXT, disagree TEXT,"
  " file INTEGER, start INTEGER, stop INTEGER, ts INTEGER,"
  " hidden INTEGER NOT NULL DEFAULT 0, decision TEXT, edited TEXT, op TEXT,"
  " UNIQUE(review, book, field, alt));"
  /* :capture's patterns kept under a name */
  "CREATE TABLE IF NOT EXISTS wit.capture_rules(name TEXT PRIMARY KEY, source TEXT, spec TEXT);"
  /* what was worked out from a file, so that it is not worked out again
   * while the file is as it was read at stamp (lulib._kept) */
  "CREATE TABLE IF NOT EXISTS wit.kept("
  " file INTEGER NOT NULL, step TEXT NOT NULL, key TEXT NOT NULL, stamp INTEGER, data TEXT,"
  " PRIMARY KEY(file, step, key));";

/* A wits table from before reviews: its rows become the first review's. */
static const char wit_before_reviews[] =
  "ALTER TABLE wit.wits RENAME TO wits_old;"
  "CREATE TABLE wit.wits("
  " id INTEGER PRIMARY KEY, review INTEGER NOT NULL DEFAULT 1, book INTEGER NOT NULL, field TEXT NOT NULL,"
  " value TEXT, source TEXT NOT NULL, alt INTEGER NOT NULL, score REAL, agree TEXT, disagree TEXT,"
  " file INTEGER, start INTEGER, stop INTEGER, ts INTEGER,"
  " hidden INTEGER NOT NULL DEFAULT 0, decision TEXT, edited TEXT, op TEXT,"
  " UNIQUE(review, book, field, alt));"
  "INSERT INTO wit.wits(id, book, field, value, source, alt, score, agree, disagree, file, start, stop, ts)"
  " SELECT id, book, field, value, source, alt, score, agree, disagree, file, start, stop, ts FROM wit.wits_old;"
  "DROP TABLE wit.wits_old;";

static int wit_prepare(struct db *db, char **err) {
  if (db_exec(db, wit_schema, err)) return -1;
  sqlite3_stmt *st = NULL;
  if (sqlite3_prepare_v2(db->h, "SELECT review FROM wit.wits LIMIT 0", -1, &st, NULL) != SQLITE_OK)
    return db_exec(db, wit_before_reviews, err);
  sqlite3_finalize(st);
  if (sqlite3_prepare_v2(db->h, "SELECT op FROM wit.wits LIMIT 0", -1, &st, NULL) != SQLITE_OK)
    return db_exec(db, "ALTER TABLE wit.wits ADD COLUMN op TEXT;", err);
  sqlite3_finalize(st);
  return 0;
}

static char *side[3]; /* journal, custom, wit */
static const char *const side_names[] = {"journal", "custom", "wit"};

void db_side_set(const char *journal, const char *custom, const char *wit) {
  const char *paths[] = {journal, custom, wit};
  for (int i = 0; i < 3; i++) {
    free(side[i]);
    side[i] = paths[i] && paths[i][0] ? xstrdup(paths[i]) : NULL;
  }
}

char *db_side_path(const char *index, const char *what) {
  for (int i = 0; i < 3; i++)
    if (side[i] && !strcmp(what, side_names[i])) return xstrdup(side[i]);
  size_t n = strlen(index);
  if (n > 3 && !strcmp(index + n - 3, ".db")) return xasprintf("%.*s.%s.db", (int)(n - 3), index, what);
  return xasprintf("%s.%s.db", index, what);
}


/* mode: "rwc" (made if it is not there), "rw", "ro" */
static int attach(struct db *db, const char *path, const char *as, const char *mode, char **err);

static int attach_history(struct db *db, int create, char **err) {
  if (!strncmp(db->path, "file:", 5) || !strcmp(db->path, ":memory:")) return 0;
  char *path = db_side_path(db->path, "journal");
  int rc = attach(db, path, "history", create ? "rwc" : "rw", err);
  free(path);
  return rc;
}

/* A file beside the index (custom, wit), attached under its name. */
static int attach_beside(struct db *db, const char *what, const char *mode, char **err) {
  if (!strncmp(db->path, "file:", 5) || !strcmp(db->path, ":memory:")) return 0;
  char *path = db_side_path(db->path, what);
  int rc = attach(db, path, what, mode, err);
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
      db_exec(db, history_schema, err) || attach_beside(db, "custom", "rwc", err) ||
      db_exec(db, custom_schema, err) || attach_beside(db, "wit", "rwc", err) || wit_prepare(db, err)) {
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
  /* the custom fields and the wits, for filters on them (the files are
   * made by db_open) */
  if (attach_beside(db, "custom", "ro", err) || attach_beside(db, "wit", "ro", err)) {
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
      attach_history(db, 0, err) || attach_beside(db, "custom", "rw", err) ||
      attach_beside(db, "wit", "ro", err)) {
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
