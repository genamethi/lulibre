/* Staged files as books.
 *
 * A file waiting in the sync folder is a row of `staged`, which lulibre owns
 * and edits. So that the list, the filters, the preview, the indexer and
 * the Lua API treat it like any other book, each staged file is also given
 * rows in the mirror tables, under the negative of its id: calibre's books
 * are positive, staged files negative, and a filter's scope (in:library,
 * in:sync) is a test of the sign. Those rows are derived, rebuilt here
 * whenever `staged` changes or the mirror is replaced. */
#include <dirent.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <time.h>

#include "core/util.h"
#include "db/db.h"
#include "index/outcome.h"

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

/* ---- reading the sync folder ---- */

/* The files the sync folder offers: as 0.2 took them. */
static const char *const ebook_ext[] = {"pdf", "djvu", "djv", "epub", "mobi", "azw3", "fb2", "cbz", "txt", "ps"};

struct found {
  char **path;
  long long *size, *mtime;
  int n, cap;
};

static void found_add(struct found *f, char *path, const struct stat *sb) {
  if (f->n == f->cap) {
    f->cap = f->cap ? f->cap * 2 : 64;
    f->path = xrealloc(f->path, (size_t)f->cap * sizeof *f->path);
    f->size = xrealloc(f->size, (size_t)f->cap * sizeof *f->size);
    f->mtime = xrealloc(f->mtime, (size_t)f->cap * sizeof *f->mtime);
  }
  f->path[f->n] = path;
  f->size[f->n] = (long long)sb->st_size;
  f->mtime[f->n++] = (long long)sb->st_mtim.tv_sec;
}

static int is_ebook(const char *name) {
  const char *ext = path_ext(name);
  for (size_t i = 0; i < ARRAY_LEN(ebook_ext); i++)
    if (!strcasecmp(ext, ebook_ext[i])) return 1;
  return 0;
}

/* Every ebook file under d; hidden entries are passed over, and at the top
 * the folder unsynced/, which holds books taken back out of the library
 * rather than books waiting to go in. */
static void walk(const char *d, int top, struct found *f) {
  DIR *dir = opendir(d);
  if (!dir) return;
  for (struct dirent *e; (e = readdir(dir));) {
    if (e->d_name[0] == '.') continue;
    char *path = xasprintf("%s/%s", d, e->d_name);
    struct stat sb;
    if (stat(path, &sb)) {
      free(path);
      continue;
    }
    if (S_ISDIR(sb.st_mode)) {
      if (!(top && !strcmp(e->d_name, "unsynced"))) walk(path, 0, f);
      free(path);
    } else if (S_ISREG(sb.st_mode) && is_ebook(e->d_name)) {
      found_add(f, path, &sb);
    } else {
      free(path);
    }
  }
  closedir(dir);
}

/* A file's name as a title: no folder, no extension, _ as a space. */
static char *stem(const char *path) {
  const char *base = strrchr(path, '/');
  base = base ? base + 1 : path;
  const char *dot = strrchr(base, '.');
  char *t = xstrndup(base, dot && dot > base ? (size_t)(dot - base) : strlen(base));
  for (char *p = t; *p; p++)
    if (*p == '_') *p = ' ';
  return t;
}

/* The first library book holding a file with path's bytes, or 0: files of
 * the same size (stat where the index has none) are hashed, through the
 * hashes table. */
static long long twin_of(sqlite3 *h, const char *path, long long size) {
  sqlite3_stmt *st;
  long long twin = 0;
  char mine[33] = "", theirs[33];
  if (sqlite3_prepare_v2(h,
                         "SELECT book, path, size FROM files WHERE book > 0 AND (size = ?1 OR size IS NULL)"
                         " AND outcome <> ?2 ORDER BY book",
                         -1, &st, NULL) != SQLITE_OK)
    return 0;
  sqlite3_bind_int64(st, 1, size);
  sqlite3_bind_int(st, 2, OUT_MISSING);
  while (!twin && sqlite3_step(st) == SQLITE_ROW) {
    const char *other = (const char *)sqlite3_column_text(st, 1);
    struct stat sb;
    if (!other) continue;
    if (sqlite3_column_type(st, 2) == SQLITE_NULL && (stat(other, &sb) || (long long)sb.st_size != size)) continue;
    if (!mine[0] && db_hash_file(h, path, mine)) break;
    if (!db_hash_file(h, other, theirs) && !strcmp(mine, theirs)) twin = sqlite3_column_int64(st, 0);
  }
  sqlite3_finalize(st);
  return twin;
}

static void id_add(long long **ids, int *n, long long id) {
  *ids = xrealloc(*ids, (size_t)(*n + 1) * sizeof **ids);
  (*ids)[(*n)++] = id;
}

int db_stage_scan(struct db *db, const char *dir, long long **ids, int *nids, char **err) {
  sqlite3 *h = db->h;
  struct found f = {0};
  sqlite3_stmt *rows = NULL, *add = NULL, *upd = NULL, *del = NULL;
  long long *drop = NULL, *keep = NULL, *twin = NULL;
  int ndrop = 0, rc = -1;
  *ids = NULL;
  *nids = 0;
  struct stat sb;
  if (stat(dir, &sb) || !S_ISDIR(sb.st_mode)) {
    *err = xasprintf("the sync folder %s is not a folder", dir);
    return -1;
  }
  walk(dir, 1, &f);
  /* what each file is: keep[i] its staged row (0: new), twin[i] for the new
   * and the changed (-1: unchanged). Worked out before the transaction, so
   * that hashing holds no lock on the index. */
  keep = xcalloc((size_t)f.n + 1, sizeof *keep);
  twin = xcalloc((size_t)f.n + 1, sizeof *twin);
  if (sqlite3_prepare_v2(h, "SELECT id, path, size, mtime FROM staged", -1, &rows, NULL) != SQLITE_OK) goto sqlerr;
  while (sqlite3_step(rows) == SQLITE_ROW) {
    long long id = sqlite3_column_int64(rows, 0);
    const char *path = (const char *)sqlite3_column_text(rows, 1);
    int at = -1;
    for (int i = 0; i < f.n && at < 0; i++)
      if (!keep[i] && path && !strcmp(f.path[i], path)) at = i;
    if (at < 0) { /* gone, or from an earlier sync folder */
      drop = xrealloc(drop, (size_t)(ndrop + 1) * sizeof *drop);
      drop[ndrop++] = id;
      id_add(ids, nids, -id);
      continue;
    }
    keep[at] = id;
    if (sqlite3_column_int64(rows, 2) == f.size[at] && sqlite3_column_int64(rows, 3) == f.mtime[at]) twin[at] = -1;
  }
  sqlite3_finalize(rows);
  rows = NULL;
  for (int i = 0; i < f.n; i++)
    if (twin[i] != -1) twin[i] = twin_of(h, f.path[i], f.size[i]);

  if (db_exec(db, "BEGIN IMMEDIATE", err)) goto done;
  if (sqlite3_prepare_v2(h, "INSERT INTO staged(path, size, mtime, title, added, twin) VALUES(?, ?, ?, ?, ?, ?)"
                            " RETURNING id",
                         -1, &add, NULL) != SQLITE_OK ||
      sqlite3_prepare_v2(h, "UPDATE staged SET size = ?, mtime = ?, twin = ? WHERE id = ?", -1, &upd, NULL) !=
        SQLITE_OK ||
      sqlite3_prepare_v2(h, "DELETE FROM staged WHERE id = ?", -1, &del, NULL) != SQLITE_OK)
    goto sqlerr;
  for (int i = 0; i < ndrop; i++) {
    sqlite3_bind_int64(del, 1, drop[i]);
    if (sqlite3_step(del) != SQLITE_DONE) goto sqlerr;
    sqlite3_reset(del);
  }
  for (int i = 0; i < f.n; i++) {
    if (twin[i] == -1) continue; /* as it was */
    sqlite3_stmt *st = keep[i] ? upd : add;
    int k = 1;
    if (!keep[i]) sqlite3_bind_text(st, k++, f.path[i], -1, SQLITE_STATIC);
    sqlite3_bind_int64(st, k++, f.size[i]);
    sqlite3_bind_int64(st, k++, f.mtime[i]);
    if (!keep[i]) {
      char *title = stem(f.path[i]);
      sqlite3_bind_text(st, k++, title, -1, SQLITE_TRANSIENT);
      free(title);
      sqlite3_bind_int64(st, k++, (long long)time(NULL));
    }
    if (twin[i]) sqlite3_bind_int64(st, k++, twin[i]);
    else sqlite3_bind_null(st, k++);
    if (keep[i]) sqlite3_bind_int64(st, k++, keep[i]);
    int step = sqlite3_step(st);
    if (step != (keep[i] ? SQLITE_DONE : SQLITE_ROW)) goto sqlerr;
    id_add(ids, nids, -(keep[i] ? keep[i] : sqlite3_column_int64(st, 0)));
    sqlite3_reset(st);
  }
  if (*nids && db_stage_refresh(db, 1, err)) goto rollback;
  if (db_exec(db, "COMMIT", err)) goto rollback;
  rc = 0;
  goto done;
sqlerr:
  *err = xasprintf("the sync folder: %s", sqlite3_errmsg(h));
rollback:
  if (sqlite3_get_autocommit(h) == 0) {
    char *ignored = NULL;
    if (db_exec(db, "ROLLBACK", &ignored)) free(ignored);
  }
  free(*ids);
  *ids = NULL;
  *nids = 0;
done:
  sqlite3_finalize(rows);
  sqlite3_finalize(add);
  sqlite3_finalize(upd);
  sqlite3_finalize(del);
  for (int i = 0; i < f.n; i++) free(f.path[i]);
  free(f.path);
  free(f.size);
  free(f.mtime);
  free(keep);
  free(twin);
  free(drop);
  return rc;
}
