/* Copy calibre's metadata.db into the index.
 *
 * metadata.db is attached read-only for a few milliseconds and never written.
 * The mirror tables are replaced wholesale (a couple of thousand rows); the
 * files table is reconciled in place so extracted text survives calibre
 * renaming a book's directory after a title or author change. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include "core/log.h"
#include "core/util.h"
#include "db/db.h"

/* Bump when the SQL below changes, so existing indexes re-copy. */
#define MIRROR_VERSION "4"

/* calibre's books (in the database attached as `cal`) as the index keeps
 * them: one row each, list fields joined into text. calibre stores "no date"
 * as year 0101; the column has numeric affinity, so a substr() of it is
 * compared (a bare string literal would be coerced). */
#define CAL_BOOKS \
  " SELECT b.id AS id, b.title AS title, b.sort AS sort," \
  "  (SELECT group_concat(replace(a.name, '|', ','), ' & ' ORDER BY l.id)" \
  "     FROM cal.books_authors_link l JOIN cal.authors a ON a.id = l.author WHERE l.book = b.id) AS authors," \
  "  b.author_sort AS author_sort," \
  "  (SELECT group_concat(t.name, ', ' ORDER BY t.name)" \
  "     FROM cal.books_tags_link l JOIN cal.tags t ON t.id = l.tag WHERE l.book = b.id) AS tags," \
  "  (SELECT s.name FROM cal.books_series_link l JOIN cal.series s ON s.id = l.series" \
  "    WHERE l.book = b.id) AS series," \
  "  b.series_index AS series_index," \
  "  (SELECT p.name FROM cal.books_publishers_link l JOIN cal.publishers p ON p.id = l.publisher" \
  "    WHERE l.book = b.id) AS publisher," \
  "  CASE WHEN b.pubdate IS NULL OR substr(b.pubdate, 1, 4) < '0102' THEN NULL" \
  "       ELSE substr(b.pubdate, 1, 10) END AS pubdate," \
  "  CASE WHEN b.pubdate IS NULL OR substr(b.pubdate, 1, 4) < '0102' THEN NULL" \
  "       ELSE CAST(substr(b.pubdate, 1, 4) AS INTEGER) END AS year," \
  "  (SELECT group_concat(g.lang_code, ',') FROM cal.books_languages_link l" \
  "     JOIN cal.languages g ON g.id = l.lang_code WHERE l.book = b.id) AS languages," \
  "  (SELECT group_concat(i.type || ':' || i.val, ', ' ORDER BY i.type)" \
  "     FROM cal.identifiers i WHERE i.book = b.id) AS idents," \
  "  EXISTS(SELECT 1 FROM cal.comments c WHERE c.book = b.id AND length(c.text) > 0) AS has_comments," \
  "  b.path AS path," \
  "  (SELECT group_concat(upper(d.format), ',' ORDER BY d.format) FROM cal.data d" \
  "    WHERE d.book = b.id) AS formats," \
  "  b.timestamp AS added, b.last_modified AS modified" \
  " FROM cal.books b"

/* Before the books are replaced, what they were is kept in mirror_prev, so
 * that changes made outside lulibre can be found and logged
 * (lua/lulibre/snapshots.lua). While an earlier copy waits there unexamined
 * (kv 'history:pending') it is left alone: several refreshes between two
 * looks come out as one change. */
static const char prev_sql[] =
  "DELETE FROM mirror_prev WHERE NOT EXISTS(SELECT 1 FROM kv WHERE key = 'history:pending');"
  "INSERT INTO mirror_prev(id, title, authors, tags, series, series_index, publisher, pubdate,"
  " languages, idents, formats, path)"
  " SELECT id, title, authors, tags, series, series_index, publisher, pubdate, languages, idents,"
  "  formats, path FROM books"
  " WHERE id > 0 AND NOT EXISTS(SELECT 1 FROM kv WHERE key = 'history:pending');"
  "INSERT OR REPLACE INTO kv(key, value)"
  " SELECT 'history:pending', '1' WHERE EXISTS(SELECT 1 FROM mirror_prev);";

static const char mirror_sql[] =
  "DELETE FROM books; DELETE FROM authors; DELETE FROM book_authors;"
  "DELETE FROM tags; DELETE FROM book_tags; DELETE FROM idents; DELETE FROM books_fts;"

  "INSERT INTO books(id, title, sort, authors, author_sort, tags, series, series_index,"
  " publisher, pubdate, year, languages, idents, has_comments, path, formats, added, modified)"
  CAL_BOOKS ";"

  "INSERT INTO authors(id, name, sort, key, n_books)"
  " SELECT a.id, replace(a.name, '|', ','), a.sort, fold(replace(a.name, '|', ',')),"
  "  (SELECT count(*) FROM cal.books_authors_link l WHERE l.author = a.id) FROM cal.authors a;"
  "INSERT INTO book_authors(book, author, ord) SELECT book, author, id FROM cal.books_authors_link;"
  "INSERT INTO tags(id, name, n_books)"
  " SELECT t.id, t.name, (SELECT count(*) FROM cal.books_tags_link l WHERE l.tag = t.id)"
  " FROM cal.tags t;"
  "INSERT INTO book_tags(book, tag) SELECT book, tag FROM cal.books_tags_link;"
  "INSERT INTO idents(book, type, val) SELECT book, lower(type), val FROM cal.identifiers;"
  "INSERT INTO books_fts(rowid, title, authors, tags, publisher, series)"
  " SELECT id, title, authors, tags, publisher, series FROM books;";

/* ?1 is the library directory */
static const char files_sql[] =
  "CREATE TEMP TABLE cf AS"
  " SELECT d.book AS book, upper(d.format) AS fmt,"
  "        ?1 || '/' || b.path || '/' || d.name || '.' || lower(d.format) AS path"
  " FROM cal.data d JOIN cal.books b ON b.id = d.book;";

static const char files_sql2[] =
  "UPDATE files SET path = (SELECT cf.path FROM cf WHERE cf.book = files.book AND cf.fmt = files.format)"
  " WHERE book > 0"
  "   AND EXISTS(SELECT 1 FROM cf WHERE cf.book = files.book AND cf.fmt = files.format);"
  "INSERT INTO files(book, format, path)"
  " SELECT cf.book, cf.fmt, cf.path FROM cf"
  "  WHERE NOT EXISTS(SELECT 1 FROM files f WHERE f.book = cf.book AND f.format = cf.fmt);"
  "DELETE FROM files WHERE book > 0"
  "   AND NOT EXISTS(SELECT 1 FROM cf WHERE cf.book = files.book AND cf.fmt = files.format);"
  "DROP TABLE cf;";

/* calibre's custom columns and their values (cal_columns, cal_values),
 * spelled as lulibre's custom fields spell theirs. A column's values are in
 * custom_column_N, linked to books through books_custom_column_N_link when
 * the column is normalized (text, series, enumeration); a composite column
 * keeps none. */
static int mirror_custom(struct db *db, char **err) {
  if (db_exec(db, "DELETE FROM cal_columns; DELETE FROM cal_values;", err)) return -1;
  sqlite3_stmt *st = NULL;
  if (sqlite3_prepare_v2(db->h,
                         "SELECT id, label, name, datatype, is_multiple, normalized FROM cal.custom_columns"
                         " WHERE NOT mark_for_delete ORDER BY id",
                         -1, &st, NULL) != SQLITE_OK)
    return 0; /* a database calibre made has the table; one that lacks it has no columns */
  int rc = 0;
  while (!rc && sqlite3_step(st) == SQLITE_ROW) {
    int id = sqlite3_column_int(st, 0);
    const char *label = (const char *)sqlite3_column_text(st, 1), *type = (const char *)sqlite3_column_text(st, 3);
    if (!label || !type) continue;
    sqlite3_stmt *ins = NULL;
    if (db_prepare(db, "INSERT OR REPLACE INTO cal_columns(label, name, datatype, multiple) VALUES(?1, ?2, ?3, ?4)",
                   &ins, err))
      break;
    sqlite3_bind_text(ins, 1, label, -1, SQLITE_TRANSIENT);
    sqlite3_bind_value(ins, 2, sqlite3_column_value(st, 2));
    sqlite3_bind_text(ins, 3, type, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int(ins, 4, sqlite3_column_int(st, 4));
    sqlite3_step(ins);
    sqlite3_finalize(ins);
    if (!strcmp(type, "composite")) continue;
    const char *value = !strcmp(type, "int") || !strcmp(type, "float") ? "printf('%.10g', v.value)"
                        : !strcmp(type, "datetime")                     ? "substr(v.value, 1, 10)"
                                                                        : "v.value";
    char *q = sqlite3_column_int(st, 5)
                  ? xasprintf("INSERT INTO cal_values(book, label, ord, value) SELECT l.book, ?1, l.id, %s"
                              " FROM cal.books_custom_column_%d_link l JOIN cal.custom_column_%d v ON v.id = l.value",
                              value, id, id)
                  : xasprintf("INSERT INTO cal_values(book, label, ord, value) SELECT v.book, ?1, 0, %s"
                              " FROM cal.custom_column_%d v",
                              value, id);
    if (sqlite3_prepare_v2(db->h, q, -1, &ins, NULL) == SQLITE_OK) {
      sqlite3_bind_text(ins, 1, label, -1, SQLITE_TRANSIENT);
      if (sqlite3_step(ins) != SQLITE_DONE) {
        *err = xasprintf("reading calibre's column #%s: %s", label, sqlite3_errmsg(db->h));
        rc = -1;
      }
    } else {
      log_debug("calibre's column #%s has no table of values: %s", label, sqlite3_errmsg(db->h));
    }
    sqlite3_finalize(ins);
    free(q);
  }
  sqlite3_finalize(st);
  return rc;
}

int db_mirror(struct db *db, const char *library, int force, char **err) {
  char *cal = xasprintf("%s/metadata.db", library);
  struct stat st;
  if (stat(cal, &st) != 0) {
    *err = xasprintf("no metadata.db in %s", library);
    free(cal);
    return -1;
  }
  char *stamp = xasprintf(MIRROR_VERSION "|%s|%lld|%lld.%09ld", cal, (long long)st.st_size,
                          (long long)st.st_mtim.tv_sec, st.st_mtim.tv_nsec);
  char *have = db_meta_get(db, "calibre_stamp");
  int current = have && strcmp(have, stamp) == 0;
  free(have);

  int rc = 0;
  if (current && !force) goto out;

  rc = -1;
  sqlite3_stmt *att = NULL;
  char *uri = xasprintf("file:%s?mode=ro", cal);
  if (db_prepare(db, "ATTACH DATABASE ?1 AS cal", &att, err) == 0) {
    sqlite3_bind_text(att, 1, uri, -1, SQLITE_STATIC);
    if (sqlite3_step(att) != SQLITE_DONE)
      *err = xasprintf("cannot attach %s: %s", cal, sqlite3_errmsg(db->h));
    else
      rc = 0;
    sqlite3_finalize(att);
  }
  free(uri);
  if (rc) goto out;

  rc = -1;
  if (db_exec(db, "BEGIN IMMEDIATE", err) == 0) {
    sqlite3_stmt *cf = NULL;
    int ok = db_exec(db, prev_sql, err) == 0 && db_exec(db, mirror_sql, err) == 0 &&
             db_prepare(db, files_sql, &cf, err) == 0;
    if (ok) {
      sqlite3_bind_text(cf, 1, library, -1, SQLITE_STATIC);
      ok = sqlite3_step(cf) == SQLITE_DONE;
      if (!ok) *err = xasprintf("listing calibre files: %s", sqlite3_errmsg(db->h));
    }
    sqlite3_finalize(cf);
    ok = ok && db_exec(db, files_sql2, err) == 0;
    ok = ok && mirror_custom(db, err) == 0;
    /* the wholesale replace above took the staged files' rows with it */
    ok = ok && db_stage_refresh(db, 1, err) == 0;
    if (ok) {
      db_meta_set(db, "calibre_stamp", stamp);
      ok = db_exec(db, "COMMIT", err) == 0;
    }
    if (ok) {
      rc = 1;
      log_debug("calibre's metadata.db copied into the index (%s)", library);
    } else {
      char *ignored = NULL;
      if (db_exec(db, "ROLLBACK", &ignored)) free(ignored);
    }
  }
  char *ignored = NULL;
  if (db_exec(db, "DETACH DATABASE cal", &ignored)) free(ignored);
out:
  free(stamp);
  free(cal);
  return rc;
}

int db_calibre_books(struct db *db, const char *path, int (*fn)(void *ud, sqlite3_stmt *st), void *ud,
                     char **err) {
  char *uri = xasprintf("file:%s?mode=ro&immutable=1", path);
  sqlite3_stmt *att = NULL, *st = NULL;
  int rc = -1;
  if (db_prepare(db, "ATTACH DATABASE ?1 AS cal", &att, err) == 0) {
    sqlite3_bind_text(att, 1, uri, -1, SQLITE_STATIC);
    if (sqlite3_step(att) != SQLITE_DONE)
      *err = xasprintf("cannot open %s: %s", path, sqlite3_errmsg(db->h));
    else
      rc = 0;
    sqlite3_finalize(att);
  }
  free(uri);
  if (rc) return rc;
  rc = db_prepare(db, CAL_BOOKS " ORDER BY b.id", &st, err);
  if (!rc) {
    int r;
    while ((r = sqlite3_step(st)) == SQLITE_ROW)
      if (fn(ud, st)) break;
    if (r != SQLITE_ROW && r != SQLITE_DONE) {
      *err = xasprintf("reading %s: %s", path, sqlite3_errmsg(db->h));
      rc = -1;
    }
    sqlite3_finalize(st);
  }
  char *ignored = NULL;
  if (db_exec(db, "DETACH DATABASE cal", &ignored)) free(ignored);
  return rc;
}
