/* Staged files as books.
 *
 * A file waiting in the sync folder is a row of `staged`, which lulibre owns
 * and edits. So that the list, the filters, the preview, the indexer and
 * the Lua API treat it like any other book, each staged file is also given
 * rows in the mirror tables, under the negative of its id: calibre's books
 * are positive, staged files negative, and a filter's scope (in:library,
 * in:sync) is a test of the sign. Those rows are derived, rebuilt here
 * whenever `staged` changes or the mirror is replaced. */
#include <stdlib.h>
#include <string.h>

#include "core/util.h"
#include "db/db.h"

static const char clear_sql[] =
  "DELETE FROM books WHERE id < 0; DELETE FROM book_authors WHERE book < 0;"
  "DELETE FROM book_tags WHERE book < 0; DELETE FROM idents WHERE book < 0;"
  "DELETE FROM authors WHERE id < 0; DELETE FROM tags WHERE id < 0;"
  "DELETE FROM books_fts WHERE rowid < 0;";

static const char book_sql[] =
  "INSERT INTO books(id, title, sort, authors, author_sort, tags, series, series_index,"
  " publisher, pubdate, year, languages, idents, has_comments, path, formats, added, modified)"
  " SELECT -s.id, s.title, s.title, coalesce(nullif(s.authors, ''), 'Unknown'),"
  "  coalesce(nullif(s.authors, ''), 'Unknown'), nullif(s.tags, ''), nullif(s.series, ''),"
  "  s.series_index, nullif(s.publisher, ''), nullif(s.pubdate, ''),"
  "  CASE WHEN length(s.pubdate) >= 4 THEN CAST(substr(s.pubdate, 1, 4) AS INTEGER) END,"
  "  nullif(s.languages, ''), nullif(s.idents, ''), 0, s.path, ?2,"
  "  datetime(s.added, 'unixepoch'), datetime(s.added, 'unixepoch')"
  " FROM staged s WHERE s.id = ?1";

static const char files_sql[] =
  "UPDATE files SET path = (SELECT s.path FROM staged s WHERE s.id = -files.book)"
  " WHERE book < 0 AND EXISTS(SELECT 1 FROM staged s WHERE s.id = -files.book AND s.path <> files.path);"
  "DELETE FROM files WHERE book < 0 AND NOT EXISTS(SELECT 1 FROM staged s WHERE s.id = -files.book);";

struct stmts {
  sqlite3_stmt *book, *fts, *find_author, *new_author, *link_author, *find_tag, *new_tag, *link_tag,
    *ident, *file;
};

static int step(sqlite3_stmt *st) {
  int rc = sqlite3_step(st);
  sqlite3_reset(st);
  return rc == SQLITE_DONE || rc == SQLITE_ROW ? 0 : -1;
}

/* The id of the row named `name`, creating it (with a negative id) if the
 * library has none of that name. */
static sqlite3_int64 named(sqlite3_stmt *find, sqlite3_stmt *make, sqlite3 *h, const char *name) {
  sqlite3_int64 id = 0;
  sqlite3_bind_text(find, 1, name, -1, SQLITE_TRANSIENT);
  if (sqlite3_step(find) == SQLITE_ROW) id = sqlite3_column_int64(find, 0);
  sqlite3_reset(find);
  if (id) return id;
  sqlite3_bind_text(make, 1, name, -1, SQLITE_TRANSIENT);
  if (sqlite3_step(make) == SQLITE_ROW) id = sqlite3_column_int64(make, 0);
  sqlite3_reset(make);
  return id;
}

/* Call fn for each piece of s between occurrences of sep, trimmed. */
static void each_piece(const char *s, const char *sep, void (*fn)(const char *piece, void *ud), void *ud) {
  if (!s) return;
  size_t seplen = strlen(sep);
  while (*s) {
    const char *e = strstr(s, sep);
    size_t len = e ? (size_t)(e - s) : strlen(s);
    while (len && (*s == ' ')) s++, len--;
    while (len && s[len - 1] == ' ') len--;
    if (len) {
      char *piece = xstrndup(s, len);
      fn(piece, ud);
      free(piece);
    }
    if (!e) break;
    s = e + seplen;
  }
}

struct ctx {
  sqlite3 *h;
  struct stmts *st;
  sqlite3_int64 book;
  int ord;
};

static void add_author(const char *name, void *ud) {
  struct ctx *c = ud;
  sqlite3_int64 id = named(c->st->find_author, c->st->new_author, c->h, name);
  if (!id) return;
  sqlite3_bind_int64(c->st->link_author, 1, c->book);
  sqlite3_bind_int64(c->st->link_author, 2, id);
  sqlite3_bind_int(c->st->link_author, 3, c->ord++);
  step(c->st->link_author);
}

static void add_tag(const char *name, void *ud) {
  struct ctx *c = ud;
  sqlite3_int64 id = named(c->st->find_tag, c->st->new_tag, c->h, name);
  if (!id) return;
  sqlite3_bind_int64(c->st->link_tag, 1, c->book);
  sqlite3_bind_int64(c->st->link_tag, 2, id);
  step(c->st->link_tag);
}

static void add_ident(const char *item, void *ud) {
  struct ctx *c = ud;
  const char *colon = strchr(item, ':');
  if (!colon || colon == item || !colon[1]) return;
  sqlite3_bind_int64(c->st->ident, 1, c->book);
  sqlite3_bind_text(c->st->ident, 2, item, (int)(colon - item), SQLITE_TRANSIENT);
  sqlite3_bind_text(c->st->ident, 3, colon + 1, -1, SQLITE_TRANSIENT);
  step(c->st->ident);
}

int db_stage_refresh(struct db *db, int in_txn, char **err) {
  sqlite3 *h = db->h;
  struct stmts st = {0};
  sqlite3_stmt *rows = NULL;
  int rc = -1;
  if (!in_txn && db_exec(db, "BEGIN IMMEDIATE", err)) return -1;
  if (db_exec(db, clear_sql, err)) goto out;
#define PREP(slot, sql) \
  if (sqlite3_prepare_v2(h, sql, -1, &st.slot, NULL) != SQLITE_OK) goto sqlerr;
  PREP(book, book_sql)
  PREP(fts, "INSERT INTO books_fts(rowid, title, authors, tags, publisher, series)"
            " SELECT id, title, authors, tags, publisher, series FROM books WHERE id = ?")
  PREP(find_author, "SELECT id FROM authors WHERE name = ? ORDER BY id DESC LIMIT 1")
  PREP(new_author, "INSERT INTO authors(id, name, sort, key, n_books)"
                   " VALUES((SELECT min(coalesce(min(id), 0), 0) - 1 FROM authors), ?1, ?1, fold(?1), 0)"
                   " RETURNING id")
  PREP(link_author, "INSERT INTO book_authors(book, author, ord) VALUES(?, ?, ?)")
  PREP(find_tag, "SELECT id FROM tags WHERE name = ? ORDER BY id DESC LIMIT 1")
  PREP(new_tag, "INSERT INTO tags(id, name, n_books)"
                " VALUES((SELECT min(coalesce(min(id), 0), 0) - 1 FROM tags), ?1, 0) RETURNING id")
  PREP(link_tag, "INSERT INTO book_tags(book, tag) VALUES(?, ?)")
  PREP(ident, "INSERT INTO idents(book, type, val) VALUES(?, lower(?), ?)")
  PREP(file, "INSERT INTO files(book, format, path) SELECT ?1, ?2, ?3"
             " WHERE NOT EXISTS(SELECT 1 FROM files WHERE book = ?1)")
#undef PREP
  if (sqlite3_prepare_v2(h, "SELECT id, path, authors, tags, idents FROM staged ORDER BY id", -1, &rows,
                         NULL) != SQLITE_OK)
    goto sqlerr;
  while (sqlite3_step(rows) == SQLITE_ROW) {
    sqlite3_int64 id = sqlite3_column_int64(rows, 0);
    const char *path = (const char *)sqlite3_column_text(rows, 1);
    char fmt[16] = "";
    const char *ext = path_ext(path ? path : "");
    for (size_t i = 0; ext[i] && i < sizeof fmt - 1; i++)
      fmt[i] = (char)(ext[i] >= 'a' && ext[i] <= 'z' ? ext[i] - 32 : ext[i]);

    sqlite3_bind_int64(st.book, 1, id);
    sqlite3_bind_text(st.book, 2, fmt, -1, SQLITE_TRANSIENT);
    if (step(st.book)) goto sqlerr;
    sqlite3_bind_int64(st.fts, 1, -id);
    if (step(st.fts)) goto sqlerr;

    struct ctx c = {h, &st, -id, 0};
    each_piece((const char *)sqlite3_column_text(rows, 2), " & ", add_author, &c);
    each_piece((const char *)sqlite3_column_text(rows, 3), ",", add_tag, &c);
    each_piece((const char *)sqlite3_column_text(rows, 4), ",", add_ident, &c);

    sqlite3_bind_int64(st.file, 1, -id);
    sqlite3_bind_text(st.file, 2, fmt, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st.file, 3, path, -1, SQLITE_TRANSIENT);
    if (step(st.file)) goto sqlerr;
  }
  sqlite3_finalize(rows);
  rows = NULL;
  if (db_exec(db, files_sql, err)) goto out;
  rc = 0;
  goto out;
sqlerr:
  *err = xasprintf("staging: %s", sqlite3_errmsg(h));
out:
  sqlite3_finalize(rows);
  sqlite3_finalize(st.book);
  sqlite3_finalize(st.fts);
  sqlite3_finalize(st.find_author);
  sqlite3_finalize(st.new_author);
  sqlite3_finalize(st.link_author);
  sqlite3_finalize(st.find_tag);
  sqlite3_finalize(st.new_tag);
  sqlite3_finalize(st.link_tag);
  sqlite3_finalize(st.ident);
  sqlite3_finalize(st.file);
  if (!in_txn) {
    char *ignored = NULL;
    if (db_exec(db, rc ? "ROLLBACK" : "COMMIT", &ignored)) free(ignored);
  }
  return rc;
}
