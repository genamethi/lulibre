/* The list model: ids matching the current filter, the cursor, and marks.
 *
 * The filter is compiled on the loop thread (so syntax errors show at once)
 * and executed on the thread pool against the reader connection. Typing
 * faster than queries finish is fine: a newer request interrupts the running
 * one and replaces any that is waiting. */
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#include "core/log.h"
#include "tui/tui.h"

enum { Q_LIST, Q_SEARCH };

struct lquery {
  uv_work_t req;
  struct tui *t;
  int kind;
  uint64_t gen;
  struct query q;
  sqlite3_int64 *ids;
  int n;
  char *err;
  double took;
};

static void lquery_free(struct lquery *lq) {
  if (!lq) return;
  query_free(&lq->q);
  free(lq->ids);
  free(lq->err);
  free(lq);
}

static void work_cb(uv_work_t *req) {
  struct lquery *lq = req->data;
  double t0 = now_s();
  sqlite3_stmt *st;
  if (query_prepare(&lq->t->rdb, &lq->q, "b.id", 0, &st, &lq->err)) return;
  int cap = 0, rc;
  while ((rc = sqlite3_step(st)) == SQLITE_ROW) {
    if (lq->n == cap) {
      cap = cap ? cap * 2 : 1024;
      lq->ids = xrealloc(lq->ids, (size_t)cap * sizeof *lq->ids);
    }
    lq->ids[lq->n++] = sqlite3_column_int64(st, 0);
  }
  if (rc != SQLITE_DONE) lq->err = xstrdup(sqlite3_errmsg(lq->t->rdb.h));
  sqlite3_finalize(st);
  lq->took = now_s() - t0;
}

static void after_cb(uv_work_t *req, int status);

static void start(struct tui *t, struct lquery *lq) {
  t->rows.running = 1;
  t->rows.running_kind = lq->kind;
  lq->req.data = lq;
  uv_queue_work(t->app->loop, &lq->req, work_cb, after_cb);
}

static void clamp(struct tui *t) {
  struct rows *r = &t->rows;
  if (r->cur >= r->n) r->cur = r->n - 1;
  if (r->cur < 0) r->cur = 0;
  if (r->anchor >= r->n) r->anchor = r->n - 1;
}

/* Bitmaps are indexed by book id. Staged files have negative ids, so ids
 * are folded onto the non-negative numbers first: 1, -1, 2, -2 ... */
static sqlite3_int64 bit_of(sqlite3_int64 id) {
  return id > 0 ? 2 * id : -2 * id + 1;
}

static void set_bit(unsigned char **bits, sqlite3_int64 *cap, sqlite3_int64 id) {
  if (id == 0) return;
  id = bit_of(id);
  if (id >= *cap) {
    sqlite3_int64 ncap = *cap ? *cap : 4096;
    while (ncap <= id) ncap *= 2;
    *bits = xrealloc(*bits, (size_t)(ncap >> 3));
    memset(*bits + (*cap >> 3), 0, (size_t)((ncap - *cap) >> 3));
    *cap = ncap;
  }
  (*bits)[id >> 3] |= (unsigned char)(1 << (id & 7));
}

static int get_bit(const unsigned char *bits, sqlite3_int64 cap, sqlite3_int64 id) {
  if (id == 0) return 0;
  id = bit_of(id);
  return id < cap && (bits[id >> 3] >> (id & 7) & 1);
}

static int search_pending(const struct rows *r) {
  return (r->running && r->running_kind == Q_SEARCH) || r->queued[Q_SEARCH] != NULL;
}

/* First hit at or after `from` (dir > 0) or at or before it (dir < 0),
 * wrapping around; -1 if the list holds no hit. */
static int find_hit(const struct tui *t, int from, int dir, int *wrapped) {
  const struct rows *r = &t->rows;
  if (wrapped) *wrapped = 0;
  if (r->n == 0) return -1;
  for (int k = 0; k < r->n; k++) {
    int i = from + k * dir;
    if (i >= r->n || i < 0) {
      i = ((i % r->n) + r->n) % r->n;
      if (wrapped) *wrapped = 1;
    }
    if (rows_hit(t, r->ids[i])) return i;
  }
  return -1;
}

static void land_list(struct tui *t, struct lquery *lq) {
  struct rows *r = &t->rows;
  free(r->error);
  r->error = NULL;
  if (lq->err) {
    r->error = lq->err;
    lq->err = NULL;
    return;
  }
  sqlite3_int64 keep = r->want_id ? r->want_id : rows_current(t);
  free(r->ids);
  r->ids = lq->ids;
  r->n = lq->n;
  lq->ids = NULL;
  r->took = lq->took;
  r->want_id = 0;
  r->total = r->n;
  sqlite3_stmt *st;
  if (r->filter && r->filter[0] &&
      sqlite3_prepare_v2(t->app->db.h, r->source ? "SELECT count(*) FROM books WHERE id < 0"
                                                 : "SELECT count(*) FROM books WHERE id > 0",
                         -1, &st, NULL) == SQLITE_OK) {
    if (sqlite3_step(st) == SQLITE_ROW) r->total = sqlite3_column_int(st, 0);
    sqlite3_finalize(st);
  }
  log_debug("list: %d %s for \"%s\" in %.1f ms", r->n, r->source ? "staged files" : "books",
            r->filter ? r->filter : "", r->took * 1000);
  if (!keep || !rows_goto_id(t, keep)) clamp(t);
  if (t->mode == MODE_VISUAL) {
    t->mode = MODE_NORMAL; /* the range no longer means what it did */
    r->anchor = -1;
  }
}

static void land_search(struct tui *t, struct lquery *lq) {
  struct rows *r = &t->rows;
  free(r->search_error);
  r->search_error = lq->err;
  lq->err = NULL;
  if (r->hits) memset(r->hits, 0, (size_t)(r->hits_cap >> 3));
  for (int i = 0; i < lq->n; i++) set_bit(&r->hits, &r->hits_cap, lq->ids[i]);
  r->nhits = 0;
  for (int i = 0; i < r->n; i++) r->nhits += rows_hit(t, r->ids[i]);
  if (r->search_origin >= 0) { /* still deciding where this search lands */
    int i = find_hit(t, r->search_origin, 1, NULL);
    r->cur = i >= 0 ? i : r->search_origin;
    clamp(t);
    if (!r->search_live) {
      r->search_origin = -1;
      if (i < 0 && !r->search_error) tui_msg(t, 1, "no match: %s", r->search);
    }
  }
}

static void after_cb(uv_work_t *req, int status) {
  struct lquery *lq = req->data;
  struct tui *t = lq->t;
  struct rows *r = &t->rows;
  r->running = 0;
  if (t->quit) {
    lquery_free(lq);
    for (int k = 0; k < 2; k++) {
      lquery_free(r->queued[k]);
      r->queued[k] = NULL;
    }
    return;
  }
  if (lq->kind == Q_LIST && lq->gen == r->gen) land_list(t, lq);
  else if (lq->kind == Q_SEARCH && lq->gen == r->sgen) land_search(t, lq);
  preview_book_changed(t);
  tui_dirty(t);
  lquery_free(lq);
  for (int k = 0; k < 2; k++)
    if (r->queued[k]) {
      struct lquery *next = r->queued[k];
      r->queued[k] = NULL;
      start(t, next);
      break;
    }
}

static void submit(struct tui *t, struct lquery *lq) {
  struct rows *r = &t->rows;
  lq->t = t;
  lq->gen = lq->kind == Q_LIST ? ++r->gen : ++r->sgen;
  if (r->running) {
    lquery_free(r->queued[lq->kind]);
    r->queued[lq->kind] = lq;
    if (r->running_kind == lq->kind) sqlite3_interrupt(t->rdb.h); /* superseded */
  } else {
    start(t, lq);
  }
  tui_dirty(t);
}

void rows_set_filter(struct tui *t, const char *filter) {
  struct rows *r = &t->rows;
  struct lquery *lq = xcalloc(1, sizeof *lq);
  char *err = NULL;
  if (query_compile_in(filter, r->source ? SCOPE_SYNC : SCOPE_LIBRARY, &lq->q, &err)) {
    free(lq);
    free(r->error);
    r->error = err;
    tui_dirty(t);
    return;
  }
  char *copy = xstrdup(filter ? filter : "");
  free(r->filter);
  r->filter = copy;
  lq->kind = Q_LIST;
  submit(t, lq);
}

/* ---- search: which books in the list match, without narrowing it ---- */

int rows_hit(const struct tui *t, sqlite3_int64 id) {
  return t->rows.search && get_bit(t->rows.hits, t->rows.hits_cap, id);
}

void rows_search(struct tui *t, const char *expr) {
  struct rows *r = &t->rows;
  free(r->search_error);
  r->search_error = NULL;
  if (!expr || !*expr) {
    free(r->search);
    r->search = NULL;
    r->nhits = 0;
    r->sgen++; /* anything in flight is now stale */
    tui_dirty(t);
    return;
  }
  struct lquery *lq = xcalloc(1, sizeof *lq);
  if (query_compile_in(expr, r->source ? SCOPE_SYNC : SCOPE_LIBRARY, &lq->q, &r->search_error)) {
    free(lq);
    tui_dirty(t);
    return;
  }
  char *copy = xstrdup(expr);
  free(r->search);
  r->search = copy;
  lq->kind = Q_SEARCH;
  submit(t, lq);
}

void rows_search_begin(struct tui *t) {
  t->rows.search_origin = t->rows.cur;
  t->rows.search_live = 1;
}

void rows_search_end(struct tui *t, const char *text, int accept) {
  struct rows *r = &t->rows;
  r->search_live = 0;
  if (!accept) {
    if (r->search_origin >= 0) r->cur = r->search_origin;
    r->search_origin = -1;
    clamp(t);
    rows_search(t, NULL);
    preview_book_changed(t);
    return;
  }
  if (!r->search || strcmp(text, r->search) != 0) rows_search(t, text);
  if (!search_pending(r)) {
    if (r->search && r->nhits == 0 && !r->search_error) tui_msg(t, 1, "no match: %s", r->search);
    r->search_origin = -1;
  }
}

void rows_search_next(struct tui *t, int dir) {
  struct rows *r = &t->rows;
  if (!r->search) {
    tui_msg(t, 1, "nothing searched for yet: press / first");
    return;
  }
  int wrapped, i = find_hit(t, r->cur + dir, dir, &wrapped);
  if (i < 0) {
    tui_msg(t, 1, "no match: %s", r->search);
    return;
  }
  if (wrapped) tui_msg(t, 0, dir > 0 ? "search hit the bottom, continuing at the top"
                                     : "search hit the top, continuing at the bottom");
  rows_move(t, i);
}

void rows_reload(struct tui *t) {
  char *f = xstrdup(t->rows.filter ? t->rows.filter : "");
  rows_set_filter(t, f);
  free(f);
  panels_reloaded(t); /* screens showing books may be showing old news */
  if (t->rows.search) {
    char *q = xstrdup(t->rows.search);
    rows_search(t, q);
    free(q);
  }
}

sqlite3_int64 rows_current(const struct tui *t) {
  const struct rows *r = &t->rows;
  return r->n > 0 && r->cur >= 0 && r->cur < r->n ? r->ids[r->cur] : 0;
}

void rows_move(struct tui *t, int to) {
  struct rows *r = &t->rows;
  int before = r->cur;
  r->cur = to;
  clamp(t);
  if (r->cur != before) preview_book_changed(t);
  tui_dirty(t);
}

void rows_set_source(struct tui *t, int source) {
  struct rows *r = &t->rows;
  if (r->source == !!source) return;
  r->source = !!source;
  atomic_store(&t->app->source, r->source);
  if (t->mode == MODE_VISUAL) r->anchor = -1;
  r->cur = r->top = 0;
  rows_search(t, NULL);
  rows_set_filter(t, ""); /* each source starts unfiltered */
}

int rows_goto_id(struct tui *t, sqlite3_int64 id) {
  struct rows *r = &t->rows;
  for (int i = 0; i < r->n; i++)
    if (r->ids[i] == id) {
      r->cur = i;
      return 1;
    }
  return 0;
}

/* ---- marks ---- */

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
    r->marks[bit_of(id) >> 3] &= (unsigned char)~(1 << (bit_of(id) & 7));
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
    for (int i = 0; i < r->n; i++) {
      int on = how > 0 ? 1 : !rows_marked(t, r->ids[i]);
      set_mark(r, r->ids[i], on);
      persist(t, r->ids[i], on);
    }
  }
  if (own_txn) sqlite3_exec(h, "COMMIT", NULL, NULL, NULL);
  tui_dirty(t);
}

sqlite3_int64 *rows_selection(const struct tui *t, int *n) {
  const struct rows *r = &t->rows;
  sqlite3_int64 *out = xmalloc(((size_t)r->n + 1) * sizeof *out);
  *n = 0;
  if (t->mode == MODE_VISUAL && r->anchor >= 0) {
    int a = r->anchor < r->cur ? r->anchor : r->cur, b = r->anchor < r->cur ? r->cur : r->anchor;
    for (int i = a; i <= b && i < r->n; i++) out[(*n)++] = r->ids[i];
    return out;
  }
  for (int i = 0; i < r->n; i++)
    if (rows_marked(t, r->ids[i])) out[(*n)++] = r->ids[i];
  if (*n == 0 && rows_current(t)) out[(*n)++] = rows_current(t);
  return out;
}

void rows_init(struct tui *t) {
  struct rows *r = &t->rows;
  memset(r, 0, sizeof *r);
  r->anchor = -1;
  r->search_origin = -1;
  r->filter = xstrdup("");
  sqlite3_stmt *st;
  if (sqlite3_prepare_v2(t->app->db.h, "SELECT id FROM marks", -1, &st, NULL) == SQLITE_OK) {
    while (sqlite3_step(st) == SQLITE_ROW) set_mark(r, sqlite3_column_int64(st, 0), 1);
    sqlite3_finalize(st);
  }
}

void rows_free(struct tui *t) {
  struct rows *r = &t->rows;
  free(r->ids);
  free(r->filter);
  free(r->error);
  free(r->marks);
  free(r->hits);
  free(r->search);
  free(r->search_error);
  for (int k = 0; k < 2; k++) lquery_free(r->queued[k]);
  memset(r, 0, sizeof *r);
}
