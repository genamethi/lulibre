/* The list as a tree: the books the filter matched, set out under headings.
 *
 * A grouping names what the headings are: authors, subjects (which nest),
 * series, publishers, years, formats, or the folders of the calibre library.
 * rows.all stays what the filter matched; rows.ids, what is drawn, is built
 * from it here: each heading as a row with id 0, and under an open heading
 * the headings within it, then its books. A book with two authors stands
 * under both. Nothing is asked of the index but one query per rebuild. */
#include <stdlib.h>
#include <string.h>

#include "match/fold.h"
#include "tui/tui.h"

const char *const rows_groupings[] = {"author", "subject", "series", "publisher", "year", "format", "folder", NULL};

static const char *sql_of(const char *by) {
  if (!strcmp(by, "author"))
    return "SELECT ba.book, a.name FROM book_authors ba JOIN authors a ON a.id = ba.author"
           " WHERE ba.book > 0 AND a.name <> 'Unknown' ORDER BY ba.book, ba.ord";
  if (!strcmp(by, "subject"))
    return "SELECT bt.book, t.name FROM book_tags bt JOIN tags t ON t.id = bt.tag WHERE bt.book > 0 ORDER BY bt.book";
  if (!strcmp(by, "series")) return "SELECT id, series FROM books WHERE id > 0 AND series IS NOT NULL AND series <> '' ORDER BY id";
  if (!strcmp(by, "publisher"))
    return "SELECT id, publisher FROM books WHERE id > 0 AND publisher IS NOT NULL AND publisher <> '' ORDER BY id";
  if (!strcmp(by, "year")) return "SELECT id, CAST(year AS TEXT) FROM books WHERE id > 0 AND year IS NOT NULL ORDER BY id";
  if (!strcmp(by, "format")) return "SELECT book, lower(format) FROM files WHERE book > 0 ORDER BY book";
  /* a book's folder is "Author/Title (id)": the first part is the folder it is filed in */
  if (!strcmp(by, "folder")) return "SELECT id, path FROM books WHERE id > 0 AND path IS NOT NULL AND path <> '' ORDER BY id";
  return NULL;
}

void rows_group_free(struct rows *r) {
  for (int i = 0; i < r->nheads; i++) {
    struct ghead *h = &r->heads[i];
    free(h->path);
    free(h->label);
    free(h->sortkey);
    free(h->books);
    free(h->direct);
    free(h->kids);
  }
  free(r->heads);
  free(r->head_of);
  r->heads = NULL;
  r->head_of = NULL;
  r->nheads = 0;
}

/* ---- building ---- */

struct build {
  struct rows *r;
  int *slot; /* a hash of paths: heading number + 1 */
  int nslot, hcap;
};

static unsigned hash(const char *s, size_t n) {
  unsigned h = 2166136261u;
  for (size_t i = 0; i < n; i++) h = (h ^ (unsigned char)s[i]) * 16777619u;
  return h;
}

static void push(int **list, int *n, int *cap, int v) {
  if (*n == *cap) {
    *cap = *cap ? *cap * 2 : 4;
    *list = xrealloc(*list, (size_t)*cap * sizeof **list);
  }
  (*list)[(*n)++] = v;
}

static void rehash(struct build *b) {
  struct rows *r = b->r;
  b->nslot = b->nslot ? b->nslot * 2 : 256;
  free(b->slot);
  b->slot = xcalloc((size_t)b->nslot, sizeof *b->slot);
  for (int i = 0; i < r->nheads; i++) {
    unsigned at = hash(r->heads[i].path, strlen(r->heads[i].path)) & (unsigned)(b->nslot - 1);
    while (b->slot[at]) at = (at + 1) & (unsigned)(b->nslot - 1);
    b->slot[at] = i + 1;
  }
}

/* The heading of a path, made if it is new. */
static int head_of_path(struct build *b, const char *path, size_t n, const char *label, size_t ln, int parent, int depth) {
  struct rows *r = b->r;
  if (r->nheads * 2 >= b->nslot) rehash(b);
  unsigned at = hash(path, n) & (unsigned)(b->nslot - 1);
  while (b->slot[at]) {
    const struct ghead *h = &r->heads[b->slot[at] - 1];
    if (strlen(h->path) == n && !memcmp(h->path, path, n)) return b->slot[at] - 1;
    at = (at + 1) & (unsigned)(b->nslot - 1);
  }
  if (r->nheads == b->hcap) {
    b->hcap = b->hcap ? b->hcap * 2 : 64;
    r->heads = xrealloc(r->heads, (size_t)b->hcap * sizeof *r->heads);
  }
  struct ghead *h = &r->heads[r->nheads];
  memset(h, 0, sizeof *h);
  h->path = xstrndup(path, n);
  h->label = xstrndup(label, ln);
  sbuf key = SBUF_INIT;
  fold_utf8(&key, label, ln);
  h->sortkey = key.s ? sb_take(&key) : xstrdup("");
  h->parent = parent;
  h->depth = depth;
  b->slot[at] = ++r->nheads;
  return r->nheads - 1;
}

/* A book is under a heading, and so under those the heading is within. The
 * pairs come book by book, which is what `seen` leans on to count once. */
static void under(struct rows *r, int head, int book) {
  for (int h = head; h >= 0; h = r->heads[h].parent) {
    struct ghead *g = &r->heads[h];
    if (g->seen == book + 1) continue;
    g->seen = book + 1;
    g->count++;
    push(&g->books, &g->nbooks, &g->bcap, book);
  }
  push(&r->heads[head].direct, &r->heads[head].ndirect, &r->heads[head].dcap, book);
}

static int by_int(const void *a, const void *b) {
  return *(const int *)a - *(const int *)b;
}

static int by_heading(const void *a, const void *b, void *arg) {
  const struct rows *sorting = arg;
  const struct ghead *x = &sorting->heads[*(const int *)a], *y = &sorting->heads[*(const int *)b];
  if (x->last != y->last) return x->last - y->last;
  if (sorting->group_by_count && x->count != y->count) return y->count - x->count;
  int c = strcmp(x->sortkey, y->sortkey);
  /* years: the newest first */
  if (!sorting->group_by_count && sorting->group && !strcmp(sorting->group, "year")) c = -c;
  return c ? c : strcmp(x->path, y->path);
}

/* What was said of a heading: '+' opened, '-' closed, 0 nothing yet. The
 * entries are "+grouping\tpath" and "-grouping\tpath". */
static int said_of(const struct rows *r, const struct ghead *h, int *at) {
  size_t gl = strlen(r->group);
  for (int i = 0; i < r->nopened; i++) {
    const char *e = r->opened[i];
    if (!strncmp(e + 1, r->group, gl) && e[1 + gl] == '\t' && !strcmp(e + 2 + gl, h->path)) {
      if (at) *at = i;
      return e[0];
    }
  }
  return 0;
}

static void row(struct rows *r, int *cap, sqlite3_int64 id, int head) {
  if (r->n == *cap) {
    *cap = *cap ? *cap * 2 : 1024;
    r->ids = xrealloc(r->ids, (size_t)*cap * sizeof *r->ids);
    r->head_of = xrealloc(r->head_of, (size_t)*cap * sizeof *r->head_of);
  }
  r->ids[r->n] = id;
  r->head_of[r->n++] = head;
}

static void emit(struct rows *r, int *cap, int head) {
  struct ghead *h = &r->heads[head];
  row(r, cap, 0, head);
  if (!h->open) return;
  for (int i = 0; i < h->nkids; i++) emit(r, cap, h->kids[i]);
  for (int i = 0; i < h->ndirect; i++) row(r, cap, r->all[h->direct[i]], head);
}

static void build(struct tui *t) {
  struct rows *r = &t->rows;
  struct build b = {r, NULL, 0, 0};
  /* where each book stands in the list */
  sqlite3_int64 top = 0;
  for (int i = 0; i < r->nall; i++)
    if (r->all[i] > top) top = r->all[i];
  int *at = xmalloc(((size_t)top + 1) * sizeof *at);
  for (sqlite3_int64 i = 0; i <= top; i++) at[i] = -1;
  for (int i = 0; i < r->nall; i++)
    if (r->all[i] > 0) at[r->all[i]] = i;
  unsigned char *placed = xcalloc((size_t)r->nall + 1, 1);

  int nested = !strcmp(r->group, "subject"), first_part = !strcmp(r->group, "folder");
  sqlite3_stmt *st;
  if (sqlite3_prepare_v2(t->app->db.h, sql_of(r->group), -1, &st, NULL) == SQLITE_OK) {
    while (sqlite3_step(st) == SQLITE_ROW) {
      sqlite3_int64 id = sqlite3_column_int64(st, 0);
      const char *name = (const char *)sqlite3_column_text(st, 1);
      if (id <= 0 || id > top || at[id] < 0 || !name || !*name) continue;
      size_t len = strlen(name);
      int head = -1;
      if (first_part) {
        const char *slash = strchr(name, '/');
        if (slash) len = (size_t)(slash - name);
        head = head_of_path(&b, name, len, name, len, -1, 0);
      } else if (nested) {
        /* "a/b/c": under c, which is within b, which is within a */
        size_t from = 0;
        int depth = 0;
        for (size_t i = 0; i <= len; i++) {
          if (i < len && name[i] != '/') continue;
          if (i > from) head = head_of_path(&b, name, i, name + from, i - from, head, depth++);
          from = i + 1;
        }
      } else {
        head = head_of_path(&b, name, len, name, len, -1, 0);
      }
      if (head < 0) continue;
      under(r, head, at[id]);
      placed[at[id]] = 1;
    }
    sqlite3_finalize(st);
  }
  /* the books with nothing to be grouped by, under a heading of their own, last */
  int none = -1;
  for (int i = 0; i < r->nall; i++) {
    if (placed[i]) continue;
    if (none < 0) {
      none = head_of_path(&b, "\001none", 5, "(none)", 6, -1, 0);
      r->heads[none].last = 1;
    }
    under(r, none, i);
  }
  free(at);
  free(placed);
  free(b.slot);

  /* in the list's order under each heading; the headings in theirs */
  int *roots = NULL, nroots = 0, rcap = 0;
  for (int i = 0; i < r->nheads; i++) {
    struct ghead *h = &r->heads[i];
    if (h->nbooks > 1) qsort(h->books, (size_t)h->nbooks, sizeof *h->books, by_int);
    if (h->ndirect > 1) qsort(h->direct, (size_t)h->ndirect, sizeof *h->direct, by_int);
    if (h->parent >= 0) push(&r->heads[h->parent].kids, &r->heads[h->parent].nkids, &r->heads[h->parent].kcap, i);
    else push(&roots, &nroots, &rcap, i);
  }
  if (nroots > 1) qsort_r(roots, (size_t)nroots, sizeof *roots, by_heading, r);
  for (int i = 0; i < r->nheads; i++)
    if (r->heads[i].nkids > 1) qsort_r(r->heads[i].kids, (size_t)r->heads[i].nkids, sizeof(int), by_heading, r);
  /* a list short enough to see whole starts out open; one that is not, closed */
  int short_list = r->nall <= 40;
  for (int i = 0; i < r->nheads; i++) {
    int said = said_of(r, &r->heads[i], NULL);
    r->heads[i].open = said ? said == '+' : short_list;
  }

  int cap = 0;
  for (int i = 0; i < nroots; i++) emit(r, &cap, roots[i]);
  free(roots);
}

void rows_regroup(struct tui *t) {
  struct rows *r = &t->rows;
  /* where the cursor is, to put it back there */
  sqlite3_int64 keep = r->ids && r->cur >= 0 && r->cur < r->n ? r->ids[r->cur] : 0;
  char *under_path = NULL;
  if (r->head_of && r->cur >= 0 && r->cur < r->n && r->head_of[r->cur] >= 0) under_path = xstrdup(r->heads[r->head_of[r->cur]].path);
  if (r->want_id) keep = r->want_id;

  rows_group_free(r);
  free(r->ids);
  r->ids = NULL;
  r->n = 0;
  if (!r->group || r->source || r->nall == 0) {
    r->ids = xmalloc(((size_t)r->nall + 1) * sizeof *r->ids);
    memcpy(r->ids, r->all, (size_t)r->nall * sizeof *r->ids);
    r->n = r->nall;
  } else {
    build(t);
  }

  int found = -1;
  for (int i = 0; i < r->n && found < 0; i++) {
    int same_head = under_path && r->head_of && r->head_of[i] >= 0 && !strcmp(r->heads[r->head_of[i]].path, under_path);
    if (keep ? (r->ids[i] == keep && (same_head || !under_path)) : (r->ids[i] == 0 && same_head)) found = i;
  }
  if (found < 0 && keep)
    for (int i = 0; i < r->n && found < 0; i++)
      if (r->ids[i] == keep) found = i;
  /* a book that is no longer shown: the heading it was under */
  if (found < 0 && under_path)
    for (int i = 0; i < r->n && found < 0; i++)
      if (r->ids[i] == 0 && r->head_of && !strcmp(r->heads[r->head_of[i]].path, under_path)) found = i;
  free(under_path);
  if (found >= 0) r->cur = found;
  if (r->cur >= r->n) r->cur = r->n - 1;
  if (r->cur < 0) r->cur = 0;
  if (r->anchor >= r->n) r->anchor = r->n - 1;
}

/* ---- asking ---- */

const struct ghead *rows_head(const struct tui *t, int row) {
  const struct rows *r = &t->rows;
  if (!r->head_of || row < 0 || row >= r->n || r->ids[row] != 0 || r->head_of[row] < 0) return NULL;
  return &r->heads[r->head_of[row]];
}

int rows_depth(const struct tui *t, int row) {
  const struct rows *r = &t->rows;
  if (!r->head_of || row < 0 || row >= r->n || r->head_of[row] < 0) return 0;
  const struct ghead *h = &r->heads[r->head_of[row]];
  return r->ids[row] == 0 ? h->depth : h->depth + 1;
}

/* ---- opening and closing ---- */

static void set_open(struct rows *r, const struct ghead *h, int on) {
  int at = -1;
  if (said_of(r, h, &at)) {
    r->opened[at][0] = on ? '+' : '-';
    return;
  }
  r->opened = xrealloc(r->opened, ((size_t)r->nopened + 1) * sizeof *r->opened);
  r->opened[r->nopened++] = xasprintf("%c%s\t%s", on ? '+' : '-', r->group, h->path);
}

void rows_fold(struct tui *t, int how) {
  struct rows *r = &t->rows;
  if (!r->head_of || r->n == 0) return;
  if (how == 'O' || how == 'C') {
    for (int i = 0; i < r->nheads; i++) set_open(r, &r->heads[i], how == 'O');
  } else {
    int h = r->head_of[r->cur];
    if (h < 0) return;
    int on_head = r->ids[r->cur] == 0;
    const struct ghead *g = &r->heads[h];
    if (!on_head) {
      if (how != 'c') return;
      /* on a book: close what it is under, and stand on that */
      for (int i = r->cur; i >= 0; i--)
        if (r->ids[i] == 0 && r->head_of[i] == h) {
          r->cur = i;
          break;
        }
      set_open(r, g, 0);
    } else if (how == 'c' && !g->open && g->parent >= 0) {
      /* closed already: step out to the heading it is within */
      for (int i = r->cur; i >= 0; i--)
        if (r->ids[i] == 0 && r->head_of[i] == g->parent) {
          r->cur = i;
          break;
        }
      preview_book_changed(t);
      tui_dirty(t);
      return;
    } else {
      set_open(r, g, how == 'o' ? 1 : how == 'c' ? 0 : !g->open);
    }
  }
  r->anchor = -1;
  if (t->mode == MODE_VISUAL) t->mode = MODE_NORMAL;
  rows_regroup(t);
  preview_book_changed(t);
  tui_dirty(t);
}

int rows_reveal(struct tui *t, sqlite3_int64 id) {
  struct rows *r = &t->rows;
  if (rows_goto_id(t, id)) return 1;
  if (!r->head_of) return 0;
  int at = -1;
  for (int i = 0; i < r->nall && at < 0; i++)
    if (r->all[i] == id) at = i;
  if (at < 0) return 0;
  /* the first heading it stands right under, and those that one is within */
  for (int i = 0; i < r->nheads; i++) {
    const struct ghead *h = &r->heads[i];
    int here = 0;
    for (int k = 0; k < h->ndirect && !here; k++) here = h->direct[k] == at;
    if (!here) continue;
    for (int up = i; up >= 0; up = r->heads[up].parent) set_open(r, &r->heads[up], 1);
    r->want_id = id;
    rows_regroup(t);
    r->want_id = 0;
    return rows_goto_id(t, id);
  }
  return 0;
}

int rows_set_group(struct tui *t, const char *by, int by_count) {
  struct rows *r = &t->rows;
  if (by && (!*by || !strcmp(by, "none") || !strcmp(by, "flat"))) by = NULL;
  if (by) {
    int known = 0;
    for (int i = 0; rows_groupings[i]; i++) known = known || !strcmp(rows_groupings[i], by);
    if (!known) return -1;
  }
  char *copy = by ? xstrdup(by) : NULL;
  free(r->group);
  r->group = copy;
  r->group_by_count = by_count;
  r->anchor = -1;
  if (t->mode == MODE_VISUAL) t->mode = MODE_NORMAL;
  rows_regroup(t);
  preview_book_changed(t);
  tui_dirty(t);
  return 0;
}
