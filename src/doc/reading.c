#include "doc/reading.h"

#include <stdlib.h>
#include <string.h>

#include "core/util.h"
#include "db/db.h"
#include "doc/doc.h"

static char *dup_col(sqlite3_stmt *st, int col) {
  const char *s = (const char *)sqlite3_column_text(st, col);
  return s ? xstrdup(s) : NULL;
}

struct reading *reading_load(struct db *db, long long file, char **err) {
  sqlite3_stmt *st;
  if (db_prepare(db,
                 "SELECT emb_title, emb_author, emb_subject, emb_keywords, emb_creator, emb_producer"
                 " FROM files WHERE id = ?",
                 &st, err))
    return NULL;
  sqlite3_bind_int64(st, 1, file);
  if (sqlite3_step(st) != SQLITE_ROW) {
    sqlite3_finalize(st);
    *err = xasprintf("no file %lld in the index", file);
    return NULL;
  }
  struct reading *r = xcalloc(1, sizeof *r);
  r->file = file;
  r->meta = (struct reading_meta){dup_col(st, 0), dup_col(st, 1), dup_col(st, 2),
                                  dup_col(st, 3), dup_col(st, 4), dup_col(st, 5)};
  sqlite3_finalize(st);

  if (db_prepare(db,
                 "SELECT id, page, n, text, size, flags, x0, y0, x1, y1, math FROM lines"
                 " WHERE file = ? ORDER BY page, n",
                 &st, err)) {
    reading_release(r);
    return NULL;
  }
  sqlite3_bind_int64(st, 1, file);
  sbuf text = SBUF_INIT;
  struct reading_line *lines = NULL;
  int n = 0, cap = 0, page = -1;
  while (sqlite3_step(st) == SQLITE_ROW) {
    if (n == cap) {
      cap = cap ? cap * 2 : 64;
      lines = xrealloc(lines, (size_t)cap * sizeof *lines);
    }
    int pg = sqlite3_column_int(st, 1);
    unsigned flags = (unsigned)sqlite3_column_int(st, 5);
    if (n) {
      if (pg != page) sb_putc(&text, '\f');
      else sb_puts(&text, flags & LINE_BLOCK ? "\n\n" : "\n");
    }
    if (pg != page) r->pages++;
    page = pg;
    const char *s = (const char *)sqlite3_column_text(st, 3);
    size_t len = (size_t)sqlite3_column_bytes(st, 3);
    lines[n] = (struct reading_line){
      .rowid = sqlite3_column_int64(st, 0),
      .page = pg,
      .n = sqlite3_column_int(st, 2),
      .start = text.len,
      .len = len,
      .size = (float)sqlite3_column_double(st, 4),
      .flags = flags,
      .x0 = (float)sqlite3_column_double(st, 6),
      .y0 = (float)sqlite3_column_double(st, 7),
      .x1 = (float)sqlite3_column_double(st, 8),
      .y1 = (float)sqlite3_column_double(st, 9),
      .math = dup_col(st, 10),
    };
    sb_putn(&text, s ? s : "", len);
    n++;
  }
  sqlite3_finalize(st);
  r->len = text.len;
  r->text = sb_take(&text);
  r->lines = lines;
  r->nlines = n;
  atomic_init(&r->holders, 1);
  return r;
}

void reading_hold(struct reading *r) {
  atomic_fetch_add(&r->holders, 1);
}

void reading_release(struct reading *r) {
  if (!r || atomic_fetch_sub(&r->holders, 1) > 1) return;
  for (int i = 0; i < r->nlines; i++) free((char *)r->lines[i].math);
  free((void *)r->lines);
  free((char *)r->text);
  const char **meta = (const char **)&r->meta;
  for (size_t i = 0; i < sizeof r->meta / sizeof *meta; i++) free((char *)meta[i]);
  free(r);
}

int reading_line_at(const struct reading *r, size_t pos) {
  if (pos >= r->len || r->text[pos] == '\f') return -1;
  int lo = 0, hi = r->nlines - 1, at = -1;
  while (lo <= hi) {
    int mid = (lo + hi) / 2;
    if (r->lines[mid].start <= pos) {
      at = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  return at;
}
