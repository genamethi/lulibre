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
#define MIRROR_VERSION "3"

static const char mirror_sql[] =
  "DELETE FROM books; DELETE FROM authors; DELETE FROM book_authors;"
  "DELETE FROM tags; DELETE FROM book_tags; DELETE FROM idents; DELETE FROM books_fts;"

  "INSERT INTO books(id, title, sort, authors, author_sort, tags, series, series_index,"
  " publisher, pubdate, year, languages, idents, has_comments, path, formats, added, modified)"
  " SELECT b.id, b.title, b.sort,"
  "  (SELECT group_concat(replace(a.name, '|', ','), ' & ' ORDER BY l.id)"
  "     FROM cal.books_authors_link l JOIN cal.authors a ON a.id = l.author WHERE l.book = b.id),"
  "  b.author_sort,"
  "  (SELECT group_concat(t.name, ', ' ORDER BY t.name)"
  "     FROM cal.books_tags_link l JOIN cal.tags t ON t.id = l.tag WHERE l.book = b.id),"
  "  (SELECT s.name FROM cal.books_series_link l JOIN cal.series s ON s.id = l.series"
  "    WHERE l.book = b.id),"
  "  b.series_index,"
  "  (SELECT p.name FROM cal.books_publishers_link l JOIN cal.publishers p ON p.id = l.publisher"
  "    WHERE l.book = b.id),"
  /* calibre stores "no date" as year 0101. The column has numeric affinity,
   * so compare a substr() of it: a bare string literal would be coerced. */
  "  CASE WHEN b.pubdate IS NULL OR substr(b.pubdate, 1, 4) < '0102' THEN NULL"
  "       ELSE substr(b.pubdate, 1, 10) END,"
  "  CASE WHEN b.pubdate IS NULL OR substr(b.pubdate, 1, 4) < '0102' THEN NULL"
  "       ELSE CAST(substr(b.pubdate, 1, 4) AS INTEGER) END,"
  "  (SELECT group_concat(g.lang_code, ',') FROM cal.books_languages_link l"
  "     JOIN cal.languages g ON g.id = l.lang_code WHERE l.book = b.id),"
  "  (SELECT group_concat(i.type || ':' || i.val, ', ' ORDER BY i.type)"
  "     FROM cal.identifiers i WHERE i.book = b.id),"
  "  EXISTS(SELECT 1 FROM cal.comments c WHERE c.book = b.id AND length(c.text) > 0),"
  "  b.path,"
  "  (SELECT group_concat(upper(d.format), ',' ORDER BY d.format) FROM cal.data d"
  "    WHERE d.book = b.id),"
  "  b.timestamp, b.last_modified"
  " FROM cal.books b;"

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
    int ok = db_exec(db, mirror_sql, err) == 0 && db_prepare(db, files_sql, &cf, err) == 0;
    if (ok) {
      sqlite3_bind_text(cf, 1, library, -1, SQLITE_STATIC);
      ok = sqlite3_step(cf) == SQLITE_DONE;
      if (!ok) *err = xasprintf("listing calibre files: %s", sqlite3_errmsg(db->h));
    }
    sqlite3_finalize(cf);
    ok = ok && db_exec(db, files_sql2, err) == 0;
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
