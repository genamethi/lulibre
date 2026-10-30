/* The pager: a text over the windows (?, :messages, :tasks), a floating
 * window drawn as a box of its own (wm_float, FLOAT_BARE). Its keys are the
 * place "pager"; any other key closes it. While it is up every key is its
 * own, and the mouse only selects (modal).
 *
 * A line that does not begin with a space is a heading, and the lines under
 * it up to the next heading are its section, which opens and closes. A
 * cursor line shows where the keys act; / searches as it is typed, opening
 * the sections the matches are in. Which sections were opened and closed is
 * kept, per title, for the next time a text of that title is shown. */
#include <stdlib.h>
#include <string.h>

#include "match/fold.h"
#include "tui/tui.h"

struct pline {
  size_t off, len;
  int sec; /* its section, -1 before the first heading */
  int head;
};

struct pager {
  char *text, *title;
  struct pline *ln;
  int n, nsec;
  int *sec_head;          /* each section's heading line */
  unsigned char *folded;  /* per section */
  int cur, top;           /* the cursor's line; the first row shown */
  int w, body;            /* as last drawn: the text's width, the rows for it */
  uint32_t pending;       /* the first key of a two-key action */
  char *search;           /* folded; NULL for none */
  int search_from;
};

/* ---- which sections were closed, by title and heading: the interface thread's ---- */

static struct fold_memory {
  char *key; /* title, a tab, the heading */
  int folded;
} *memory;
static int nmemory;

static char *memory_key(const struct pager *pg, int sec) {
  const struct pline *h = &pg->ln[pg->sec_head[sec]];
  return xasprintf("%s\t%.*s", pg->title, (int)h->len, pg->text + h->off);
}

static int remembered(const struct pager *pg, int sec) {
  char *key = memory_key(pg, sec);
  int r = -1;
  for (int i = 0; i < nmemory && r < 0; i++)
    if (!strcmp(memory[i].key, key)) r = memory[i].folded;
  free(key);
  return r;
}

static void set_fold(struct pager *pg, int sec, int folded) {
  pg->folded[sec] = (unsigned char)folded;
  char *key = memory_key(pg, sec);
  for (int i = 0; i < nmemory; i++)
    if (!strcmp(memory[i].key, key)) {
      memory[i].folded = folded;
      free(key);
      return;
    }
  memory = xrealloc(memory, (size_t)(nmemory + 1) * sizeof *memory);
  memory[nmemory++] = (struct fold_memory){key, folded};
}

/* ---- lines ---- */

static void split(struct pager *pg) {
  free(pg->ln);
  free(pg->sec_head);
  free(pg->folded);
  pg->n = pg->nsec = 0;
  size_t cap = 16;
  pg->ln = xcalloc(cap, sizeof *pg->ln);
  pg->sec_head = xcalloc(cap, sizeof *pg->sec_head);
  for (const char *p = pg->text; *p;) {
    const char *nl = strchr(p, '\n');
    size_t len = nl ? (size_t)(nl - p) : strlen(p);
    if ((size_t)pg->n == cap) {
      cap *= 2;
      pg->ln = xrealloc(pg->ln, cap * sizeof *pg->ln);
      pg->sec_head = xrealloc(pg->sec_head, cap * sizeof *pg->sec_head);
    }
    int head = len > 0 && p[0] != ' ';
    if (head) pg->sec_head[pg->nsec++] = pg->n;
    pg->ln[pg->n++] = (struct pline){(size_t)(p - pg->text), len, pg->nsec - 1, head};
    p = nl ? nl + 1 : p + len;
  }
  pg->folded = xcalloc((size_t)pg->nsec + 1, 1);
}

static int has_body(const struct pager *pg, int sec) {
  int h = pg->sec_head[sec];
  return h + 1 < pg->n && pg->ln[h + 1].sec == sec;
}

static int shown(const struct pager *pg, int i) {
  const struct pline *l = &pg->ln[i];
  return l->sec < 0 || l->head || !pg->folded[l->sec];
}

static int matches(const struct pager *pg, int i) {
  if (!pg->search) return 0;
  sbuf f = SBUF_INIT;
  fold_utf8(&f, pg->text + pg->ln[i].off, pg->ln[i].len);
  int hit = f.s && strstr(f.s, pg->search);
  sb_free(&f);
  return hit;
}

/* Each line wraps at the text's width, and what wraps lines up under its
 * last column: what follows the last gap of two spaces or more on its first
 * row, in its first two thirds (else under the line's own indent). Calls fn
 * for each row of line i as shown and returns how many rows it takes. */
typedef void row_fn(struct tui *t, int row, int indent, const char *s, size_t len, void *ud);

static int hanging(const char *p, size_t len, int w) {
  size_t first = dr_wrap(p, len, w), ind = 0;
  while (ind < len && p[ind] == ' ') ind++;
  if (first < len)
    for (size_t j = ind; j + 2 < first; j++)
      if (p[j] == ' ' && p[j + 1] == ' ' && p[j + 2] != ' ') {
        int col = dr_width(p, j + 2);
        if (col <= w * 2 / 3) ind = j + 2;
      }
  int col = dr_width(p, ind);
  return col > w * 2 / 3 ? 0 : col;
}

static int rows_of(struct tui *t, const struct pager *pg, int i, row_fn *fn, void *ud) {
  const char *p = pg->text + pg->ln[i].off;
  size_t len = pg->ln[i].len;
  int w = pg->w > 0 ? pg->w : 1, n = 0, ind = hanging(p, len, w);
  size_t k = 0;
  do {
    int lead = k ? ind : 0;
    size_t took = dr_wrap(p + k, len - k, w - lead), drawn = took;
    if (k + took < len)
      while (drawn > 0 && p[k + drawn - 1] == ' ') drawn--;
    if (fn) fn(t, n, lead, p + k, drawn, ud);
    n++;
    k += took;
    while (k && k < len && p[k] == ' ') k++; /* a wrapped line starts at a word */
  } while (k < len);
  return n;
}

/* the next line shown from i in direction dir, or i when there is none */
static int step(const struct pager *pg, int i, int dir) {
  for (int j = i + dir; j >= 0 && j < pg->n; j += dir)
    if (shown(pg, j)) return j;
  return i;
}

/* the cursor `rows` rows on, by whole lines */
static void move_rows(struct tui *t, struct pager *pg, int dir, int rows) {
  int used = 0;
  while (used < rows) {
    int next = step(pg, pg->cur, dir);
    if (next == pg->cur) break;
    pg->cur = next;
    used += rows_of(t, pg, next, NULL, NULL);
  }
}

static void cursor_to(struct pager *pg, int i) {
  const struct pline *l = &pg->ln[i];
  if (l->sec >= 0 && !l->head && pg->folded[l->sec]) set_fold(pg, l->sec, 0);
  pg->cur = i;
}

/* ---- drawing ---- */

struct pager_draw {
  int x, y, row0, rows; /* the screen's first text row; the text's row it shows; how many */
  int at;               /* the text's row the line being drawn begins on */
  int heading, current;
};

static void draw_row(struct tui *t, int row, int indent, const char *s, size_t len, void *ud) {
  struct pager_draw *d = ud;
  int r = d->at + row - d->row0;
  if (r < 0 || r >= d->rows) return;
  int bg = d->current ? theme.cursor_bg : theme.bar_bg;
  dr_style(t->std, d->heading ? theme.accent : C_DEFAULT, bg, d->heading ? A_BOLD : 0);
  dr_textn(t->std, d->y + r, d->x + indent, 1 << 30, s, len);
}

static void draw(struct tui *t, void *state, struct rect area, int focused) {
  struct pager *pg = state;
  struct ncplane *n = t->std;
  int W = t->cols_n, H = t->rows_n;
  int w = W > 84 ? 80 : W - 2, h = H - 4;
  if (w < 20 || h < 4) return;
  int x = (W - w) / 2, y = 1;
  pg->w = w - 4;
  pg->body = h - 2; /* the title above, a margin below */
  if (pg->n && !shown(pg, pg->cur)) pg->cur = pg->sec_head[pg->ln[pg->cur].sec];

  /* where each line begins, so that the cursor's line is in view */
  int cur_at = 0, cur_rows = 0, total = 0;
  for (int i = 0; i < pg->n; i++) {
    if (!shown(pg, i)) continue;
    int k = rows_of(t, pg, i, NULL, NULL);
    if (i == pg->cur) cur_at = total, cur_rows = k;
    total += k;
  }
  if (cur_at < pg->top) pg->top = cur_at;
  if (cur_at + cur_rows > pg->top + pg->body) pg->top = cur_at + cur_rows - pg->body;
  if (pg->top > total - pg->body) pg->top = total - pg->body;
  if (pg->top < 0) pg->top = 0;

  for (int r = 0; r < h; r++) {
    dr_style(n, C_DEFAULT, theme.bar_bg, 0);
    dr_fill(n, y + r, x, w);
  }
  dr_style(n, theme.dim, theme.bar_bg, 0);
  dr_text(n, y, x + 2, w - 4, pg->title);
  struct pager_draw d = {x + 2, y + 1, pg->top, pg->body, 0, 0, 0};
  for (int i = 0; i < pg->n; i++) {
    if (!shown(pg, i)) continue;
    d.heading = pg->ln[i].head;
    d.current = i == pg->cur;
    int k = rows_of(t, pg, i, NULL, NULL);
    if (d.current)
      for (int r = d.at; r < d.at + k; r++)
        if (r >= pg->top && r < pg->top + pg->body) {
          dr_style(n, C_DEFAULT, theme.cursor_bg, 0);
          dr_fill(n, d.y + r - pg->top, x, w);
        }
    int r = d.at - pg->top;
    if (r >= 0 && r < pg->body) {
      int bg = d.current ? theme.cursor_bg : theme.bar_bg;
      /* in the margin: a heading's ▸ or ▾, a match's › (a heading that
       * matches has its mark in the match's colour) */
      int hit = matches(pg, i), fold = d.heading && has_body(pg, pg->ln[i].sec);
      dr_style(n, hit ? theme.accent : theme.dim, bg, hit ? A_BOLD : 0);
      if (fold) dr_text(n, d.y + r, x, 1, pg->folded[pg->ln[i].sec] ? "▸" : "▾");
      else if (hit) dr_text(n, d.y + r, x, 1, "›");
    }
    rows_of(t, pg, i, draw_row, &d);
    d.at += k;
  }
}

static void destroy(struct tui *t, void *state) {
  struct pager *pg = state;
  free(pg->text);
  free(pg->title);
  free(pg->ln);
  free(pg->sec_head);
  free(pg->folded);
  free(pg->search);
  free(pg);
}

/* ---- search: as in a panel, on the line at the bottom ---- */

static struct pager *open_pager(struct tui *t) {
  struct node *open = wm_find(t, &view_pager);
  return open ? open->state : NULL;
}

static void search_set(struct pager *pg, const char *text) {
  free(pg->search);
  pg->search = NULL;
  if (text && *text) {
    sbuf f = SBUF_INIT;
    fold_utf8(&f, text, strlen(text));
    pg->search = sb_take(&f);
  }
}

/* the cursor to the first match from line `from` on, in direction dir,
 * coming round at the end; 0 when no line matches */
static int search_go(struct pager *pg, int from, int dir) {
  for (int k = 0; k < pg->n; k++) {
    int i = ((from + dir * k) % pg->n + pg->n) % pg->n;
    if (matches(pg, i)) {
      cursor_to(pg, i);
      return 1;
    }
  }
  return 0;
}

static void search_say(struct tui *t, struct pager *pg) {
  int n = 0, at = 0;
  for (int i = 0; i < pg->n; i++)
    if (matches(pg, i)) {
      n++;
      if (i <= pg->cur) at = n;
    }
  char *m = n ? xasprintf("/%s: %d of %d lines", pg->search, at, n) : xasprintf("/%s: no line holds it", pg->search);
  tui_show_msg(t, !n, m);
  free(m);
}

static void search_typed(struct tui *t, const char *text, void *ud) {
  struct pager *pg = open_pager(t);
  if (!pg) return;
  search_set(pg, text);
  if (!pg->search || !search_go(pg, pg->search_from, 1)) pg->cur = pg->search_from;
  tui_dirty(t);
}

static void search_done(struct tui *t, const char *text, void *ud) {
  struct pager *pg = open_pager(t);
  if (!pg) return;
  search_set(pg, text); /* Esc (NULL): back where it was, nothing marked */
  if (!pg->search || !search_go(pg, pg->search_from, 1)) pg->cur = pg->search_from;
  if (pg->search) search_say(t, pg);
  tui_dirty(t);
}

/* ---- keys ---- */

static void fold_all(struct pager *pg, int folded) {
  for (int s = 0; s < pg->nsec; s++)
    if (has_body(pg, s)) set_fold(pg, s, folded);
}

static int key(struct tui *t, void *state, uint32_t k, const struct ncinput *ni) {
  struct pager *pg = state;
  int sec = pg->n ? pg->ln[pg->cur].sec : -1;
  int body = pg->body > 1 ? pg->body : 10;
  int a = ctx_feed(KC_PAGER, &pg->pending, k);
  switch (a) {
    case CTX_PENDING: break;
    case GA_DOWN: pg->cur = step(pg, pg->cur, 1); break;
    case GA_UP: pg->cur = step(pg, pg->cur, -1); break;
    case GA_PAGE_DOWN: move_rows(t, pg, 1, body); break;
    case GA_PAGE_UP: move_rows(t, pg, -1, body); break;
    case GA_TOP: pg->cur = 0; break;
    case GA_BOTTOM: pg->cur = pg->n ? pg->n - 1 : 0; break;
    case GA_TOGGLE:
    case GA_OPEN:
    case GA_CLOSE:
      /* on a line of a section: its heading's */
      if (sec < 0 || !has_body(pg, sec)) break;
      set_fold(pg, sec, a == GA_TOGGLE ? !pg->folded[sec] : a == GA_CLOSE);
      if (pg->folded[sec]) pg->cur = pg->sec_head[sec];
      break;
    case GA_ALL: fold_all(pg, 0); break;
    case GA_NONE: fold_all(pg, 1); break;
    case GA_SEARCH:
      pg->search_from = pg->cur;
      tui_input(t, "/", "", search_done, NULL);
      tui_input_on_change(t, search_typed);
      break;
    case GA_NEXT:
    case GA_PREV:
      if (!pg->search) break;
      search_go(pg, pg->cur + (a == GA_NEXT ? 1 : -1), a == GA_NEXT ? 1 : -1);
      search_say(t, pg);
      break;
    default: wm_undock(t, pg); /* frees it */
  }
  (void)ni;
  tui_dirty(t);
  return 1;
}

const struct view_class view_pager = {"pager", NULL, destroy, draw, NULL, key, 1};

void tui_pager_folded(struct tui *t, const char *title, const char *text, int open) {
  struct pager *pg = open_pager(t);
  int fresh = !pg;
  if (fresh) pg = xcalloc(1, sizeof *pg);
  free(pg->text);
  free(pg->title);
  free(pg->search);
  pg->search = NULL;
  pg->text = xstrdup(text ? text : "");
  pg->title = xstrdup(title ? title : "");
  split(pg);
  for (int s = 0; s < pg->nsec; s++) {
    int r = open < 0 || s < open ? 0 : remembered(pg, s);
    pg->folded[s] = (unsigned char)(r >= 0 ? r : 1);
  }
  pg->cur = pg->top = 0;
  if (fresh) wm_float(t, &view_pager, pg, 0, FLOAT_BARE);
  tui_dirty(t);
}

void tui_pager(struct tui *t, const char *title, const char *text) {
  tui_pager_folded(t, title, text, 1 << 30);
}

void tui_pager_end(struct tui *t) {
  struct pager *pg = open_pager(t);
  if (pg && pg->n) pg->cur = pg->n - 1;
}

void tui_pager_forget(void) {
  for (int i = 0; i < nmemory; i++) free(memory[i].key);
  free(memory);
  memory = NULL;
  nmemory = 0;
}
