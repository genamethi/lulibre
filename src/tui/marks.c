/* Marks: the books marked by hand, kept in the index's marks table so they
 * outlast the session and the filter is:marked reads them; and the
 * selection, the books an action applies to. */
#include <string.h>

#include "tui/bits.h"
#include "tui/tui.h"

int rows_marked(const struct tui *t, sqlite3_int64 id) {
  return get_bit(t->rows.marks, t->rows.marks_cap, id);
}

static void set_mark(struct rows *r, sqlite3_int64 id, int on) {
  if (id == 0) return;
  int was = get_bit(r->marks, r->marks_cap, id);
  if (on && !was) {
    set_bit(&r->marks, &r->marks_cap, id);
    r->nmarks++;
  } else if (!on && was) {
    clear_bit(r->marks, r->marks_cap, id);
    r->nmarks--;
  }
}

static void persist(struct tui *t, sqlite3_int64 id, int on) {
  sqlite3_stmt *st;
  const char *sql = on ? "INSERT OR IGNORE INTO marks(id) VALUES(?)" : "DELETE FROM marks WHERE id = ?";
  if (sqlite3_prepare_v2(t->app->db.h, sql, -1, &st, NULL) != SQLITE_OK) return;
  sqlite3_bind_int64(st, 1, id);
  sqlite3_step(st);
  sqlite3_finalize(st);
}

void rows_mark(struct tui *t, sqlite3_int64 id, int on) {
  if (on < 0) on = !rows_marked(t, id);
  set_mark(&t->rows, id, on);
  persist(t, id, on);
  tui_dirty(t);
}

void rows_mark_all(struct tui *t, int how) {
  struct rows *r = &t->rows;
  sqlite3 *h = t->app->db.h;
  int own_txn = sqlite3_get_autocommit(h);
  if (own_txn) sqlite3_exec(h, "BEGIN", NULL, NULL, NULL);
  if (how == 0) {
    sqlite3_exec(h, "DELETE FROM marks", NULL, NULL, NULL);
    if (r->marks) memset(r->marks, 0, (size_t)(r->marks_cap >> 3));
    r->nmarks = 0;
  } else {
    for (int i = 0; i < r->nall; i++) {
      int on = how > 0 ? 1 : !rows_marked(t, r->all[i]);
      set_mark(r, r->all[i], on);
      persist(t, r->all[i], on);
    }
  }
  if (own_txn) sqlite3_exec(h, "COMMIT", NULL, NULL, NULL);
  tui_dirty(t);
}

sqlite3_int64 *rows_selection(const struct tui *t, int *n) {
  const struct rows *r = &t->rows;
  sqlite3_int64 *out = xmalloc(((size_t)r->nall + (size_t)r->n + 1) * sizeof *out);
  *n = 0;
  if (t->mode == MODE_VISUAL && r->anchor >= 0) {
    int a = r->anchor < r->cur ? r->anchor : r->cur, b = r->anchor < r->cur ? r->cur : r->anchor;
    for (int i = a; i <= b && i < r->n; i++) {
      int dup = r->ids[i] == 0; /* a heading in the range is not a book; nor is a book taken twice */
      for (int k = 0; k < *n && !dup; k++) dup = out[k] == r->ids[i];
      if (!dup) out[(*n)++] = r->ids[i];
    }
    return out;
  }
  /* the marked books the filter matched, shown or under a closed heading */
  for (int i = 0; i < r->nall; i++)
    if (rows_marked(t, r->all[i])) out[(*n)++] = r->all[i];
  if (*n > 0) return out;
  /* on a heading: every book under it */
  const struct ghead *h = rows_head(t, r->cur);
  if (h) {
    for (int i = 0; i < h->nbooks; i++) out[(*n)++] = r->all[h->books[i]];
    return out;
  }
  if (rows_current(t)) out[(*n)++] = rows_current(t);
  return out;
}

void rows_marks_load(struct tui *t) {
  sqlite3_stmt *st;
  if (sqlite3_prepare_v2(t->app->db.h, "SELECT id FROM marks", -1, &st, NULL) != SQLITE_OK) return;
  while (sqlite3_step(st) == SQLITE_ROW) set_mark(&t->rows, sqlite3_column_int64(st, 0), 1);
  sqlite3_finalize(st);
}
