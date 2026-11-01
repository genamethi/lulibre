/* The pager: a text over the windows (?, :help, :messages, :tasks), a
 * floating window drawn as a box of its own (wm_float, FLOAT_BARE). Its
 * keys are the place "pager"; any other key closes it. While it is up every
 * key is its own, and the mouse only selects (modal).
 *
 * The text is a struct rich (rich.c): its headings open sections, the
 * lines under one up to the next heading, which open and close; its spans
 * are drawn in their styles, its links as links. In a plain text, a line
 * that does not begin with a space is a heading (rich_plain). A
 * cursor line shows where the keys act; / searches as it is typed, opening
 * the sections the matches are in. Which sections were opened and closed is
 * kept, per title, for the next time a text of that title is shown.
 *
 * A text may have links (tui_pager_links): follow takes the one on the
 * cursor's line (a picker chooses among several) to what it names, through
 * the guides (guides.c), and back and forward go through the pages seen, as
 * vim's tag stack and jump list do. */
#include <stdlib.h>
#include <string.h>

#include "match/fold.h"
#include "tui/tui.h"

struct pline {
  size_t off, len;
  int sec; /* its section, -1 before the first heading */
  int head;
  int span0; /* the first of its spans (sorted by offset) */
};

/* what is shown, as kept in the pages gone back and forward through */
struct page {
  struct rich r;
  char *title, *where;   /* where: the file it is, for its links; NULL for none */
  unsigned char *folded; /* per section */
  int cur, top;          /* the cursor's line; the first row shown */
};

#define HISTORY_MAX 50

struct pager {
  struct page p;
  struct pline *ln;
  int n, nsec;
  int *sec_head;    /* each section's heading line */
  int w, body;      /* as last drawn: the text's width, the rows for it */
  int at_top;       /* the cursor's line goes to the top when next drawn */
  uint32_t pending; /* the first key of a two-key action */
  char *search;     /* folded; NULL for none */
  int search_from;
  struct page back[HISTORY_MAX], fwd[HISTORY_MAX];
  int nback, nfwd;
};

static void page_free(struct page *p) {
  rich_free(&p->r);
  free(p->title);
  free(p->where);
  free(p->folded);
  memset(p, 0, sizeof *p);
}

/* ---- which sections were closed, by title and heading: the interface thread's ---- */

static struct fold_memory {
  char *key; /* title, a tab, the heading */
  int folded;
} *memory;
static int nmemory;

static const char *text_of(const struct page *p) {
  return p->r.text.s ? p->r.text.s : "";
}

static char *memory_key(const struct pager *pg, int sec) {
  const struct pline *h = &pg->ln[pg->sec_head[sec]];
  return xasprintf("%s\t%.*s", pg->p.title, (int)h->len, text_of(&pg->p) + h->off);
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
  pg->p.folded[sec] = (unsigned char)folded;
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

static int by_offset(const void *a, const void *b) {
  const struct rich_span *x = a, *y = b;
  return x->off < y->off ? -1 : x->off > y->off;
}

/* The lines and sections of the page's text; its folds stay if it has them. */
static void split(struct pager *pg) {
  struct rich *r = &pg->p.r;
  const char *text = text_of(&pg->p);
  free(pg->ln);
  free(pg->sec_head);
  pg->n = pg->nsec = 0;
  qsort(r->spans, (size_t)r->nspans, sizeof *r->spans, by_offset);
  size_t cap = 16;
  pg->ln = xcalloc(cap, sizeof *pg->ln);
  pg->sec_head = xcalloc(cap, sizeof *pg->sec_head);
  int h = 0, sp = 0;
  for (const char *p = text; *p;) {
    const char *nl = strchr(p, '\n');
    size_t len = nl ? (size_t)(nl - p) : strlen(p), off = (size_t)(p - text);
    if ((size_t)pg->n == cap) {
      cap *= 2;
      pg->ln = xrealloc(pg->ln, cap * sizeof *pg->ln);
      pg->sec_head = xrealloc(pg->sec_head, cap * sizeof *pg->sec_head);
    }
    while (h < r->nheads && r->heads[h].line < pg->n) h++;
    int head = h < r->nheads && r->heads[h].line == pg->n;
    if (head) pg->sec_head[pg->nsec++] = pg->n;
    while (sp < r->nspans && r->spans[sp].off < off) sp++;
    pg->ln[pg->n++] = (struct pline){off, len, pg->nsec - 1, head, sp};
    p = nl ? nl + 1 : p + len;
  }
  if (!pg->p.folded) pg->p.folded = xcalloc((size_t)pg->nsec + 1, 1);
}

static int has_body(const struct pager *pg, int sec) {
  int h = pg->sec_head[sec];
  return h + 1 < pg->n && pg->ln[h + 1].sec == sec;
}

static int shown(const struct pager *pg, int i) {
  const struct pline *l = &pg->ln[i];
  return l->sec < 0 || l->head || !pg->p.folded[l->sec];
}

static int matches(const struct pager *pg, int i) {
  if (!pg->search) return 0;
  sbuf f = SBUF_INIT;
  fold_utf8(&f, text_of(&pg->p) + pg->ln[i].off, pg->ln[i].len);
  int hit = f.s && strstr(f.s, pg->search);
  sb_free(&f);
  return hit;
}

/* Each line wraps at the text's width, and what wraps lines up under the
 * column the text gives it (its hang), else under its last column: what
 * follows the last gap of two spaces or more on its first row, in its first
 * two thirds, or a list item's text (else under the line's own indent).
 * Calls fn for each row of line i as shown and returns how many rows it
 * takes. */
typedef void row_fn(struct tui *t, int row, int indent, const char *s, size_t len, void *ud);

static int hanging(const char *p, size_t len, int w) {
  size_t first = dr_wrap(p, len, w), ind = 0;
  while (ind < len && p[ind] == ' ') ind++;
  if (ind + 1 < len && p[ind] == '-' && p[ind + 1] == ' ') ind += 2; /* "- an item" */
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
  const char *p = text_of(&pg->p) + pg->ln[i].off;
  size_t len = pg->ln[i].len;
  const struct rich *r = &pg->p.r;
  int w = pg->w > 0 ? pg->w : 1, n = 0;
  int ind = r->hang && i < r->nlines && r->hang[i] >= 0 ? r->hang[i] : hanging(p, len, w);
  if (ind > w * 2 / 3) ind = 0;
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
    int next = step(pg, pg->p.cur, dir);
    if (next == pg->p.cur) break;
    pg->p.cur = next;
    used += rows_of(t, pg, next, NULL, NULL);
  }
}

static void cursor_to(struct pager *pg, int i) {
  const struct pline *l = &pg->ln[i];
  if (l->sec >= 0 && !l->head && pg->p.folded[l->sec]) set_fold(pg, l->sec, 0);
  pg->p.cur = i;
}

/* ---- drawing ---- */

struct pager_draw {
  const struct pager *pg;
  int x, y, row0, rows; /* the screen's first text row; the text's row it shows; how many */
  int at;               /* the text's row the line being drawn begins on */
  int line, heading, current;
};

/* a row, its spans in their styles and its links drawn as links */
static void draw_row(struct tui *t, int row, int indent, const char *s, size_t len, void *ud) {
  struct pager_draw *d = ud;
  int r = d->at + row - d->row0;
  if (r < 0 || r >= d->rows) return;
  const struct rich *rt = &d->pg->p.r;
  const char *text = text_of(&d->pg->p);
  const struct pline *ln = &d->pg->ln[d->line];
  int bg = d->current ? theme.cursor_bg : theme.bar_bg, x = d->x + indent;
  size_t off = (size_t)(s - text), end = off + len, line_end = ln->off + ln->len;
  int l = 0;
  while (l < rt->nlinks && rt->links[l].off + rt->links[l].len <= off) l++;
  for (size_t at = off; at < end;) {
    int in = l < rt->nlinks && rt->links[l].off <= at;
    size_t to = in ? rt->links[l].off + rt->links[l].len : l < rt->nlinks ? rt->links[l].off : end;
    unsigned style = 0;
    for (int k = ln->span0; k < rt->nspans && rt->spans[k].off < line_end; k++) {
      const struct rich_span *sp = &rt->spans[k];
      size_t e = sp->off + sp->len;
      if (sp->off <= at && e > at) style |= sp->style;
      if (sp->off > at && sp->off < to) to = sp->off;
      if (e > at && e < to) to = e;
    }
    if (to > end) to = end;
    unsigned attrs = (style & RS_STRONG || d->heading ? A_BOLD : 0) | (style & RS_EM ? A_ITALIC : 0) |
                     (style & RS_STRIKE ? A_STRUCK : 0) | (in ? A_UNDERLINE : 0);
    int fg = in || d->heading ? theme.accent : style & RS_CODE ? theme.ok : C_DEFAULT;
    dr_style(t->std, fg, bg, attrs);
    x += dr_textn(t->std, d->y + r, x, 1 << 30, text + at, to - at);
    if (in && to >= rt->links[l].off + rt->links[l].len) l++;
    at = to;
  }
}

static void draw(struct tui *t, void *state, struct rect area, int focused) {
  struct pager *pg = state;
  struct ncplane *n = t->std;
  int W = t->cols_n, H = t->rows_n;
  int w = W > PAGER_WIDTH + 8 ? PAGER_WIDTH + 4 : W - 2, h = H - 4;
  if (w < 20 || h < 4) return;
  int x = (W - w) / 2, y = 1;
  pg->w = w - 4;
  pg->body = h - 2; /* the title above, a margin below */
  if (pg->n && !shown(pg, pg->p.cur)) pg->p.cur = pg->sec_head[pg->ln[pg->p.cur].sec];

  /* where each line begins, so that the cursor's line is in view */
  int cur_at = 0, cur_rows = 0, total = 0;
  for (int i = 0; i < pg->n; i++) {
    if (!shown(pg, i)) continue;
    int k = rows_of(t, pg, i, NULL, NULL);
    if (i == pg->p.cur) cur_at = total, cur_rows = k;
    total += k;
  }
  if (pg->at_top) pg->p.top = cur_at;
  pg->at_top = 0;
  if (cur_at < pg->p.top) pg->p.top = cur_at;
  if (cur_at + cur_rows > pg->p.top + pg->body) pg->p.top = cur_at + cur_rows - pg->body;
  if (pg->p.top > total - pg->body) pg->p.top = total - pg->body;
  if (pg->p.top < 0) pg->p.top = 0;

  for (int r = 0; r < h; r++) {
    dr_style(n, C_DEFAULT, theme.bar_bg, 0);
    dr_fill(n, y + r, x, w);
  }
  dr_style(n, theme.dim, theme.bar_bg, 0);
  int used = dr_text(n, y, x + 2, w - 4, pg->p.title);
  sbuf hint = SBUF_INIT; /* the place's hint (scrnman.set), on the title's line */
  int hw = ctx_hint_line(KC_PAGER, &hint) ? dr_width(hint.s, hint.len) : 0;
  if (hw && used + hw + 6 <= w) dr_text(n, y, x + w - hw - 2, hw, hint.s);
  sb_free(&hint);
  struct pager_draw d = {pg, x + 2, y + 1, pg->p.top, pg->body, 0, 0, 0, 0};
  for (int i = 0; i < pg->n; i++) {
    if (!shown(pg, i)) continue;
    d.line = i;
    d.heading = pg->ln[i].head;
    d.current = i == pg->p.cur;
    int k = rows_of(t, pg, i, NULL, NULL);
    if (d.current)
      for (int r = d.at; r < d.at + k; r++)
        if (r >= pg->p.top && r < pg->p.top + pg->body) {
          dr_style(n, C_DEFAULT, theme.cursor_bg, 0);
          dr_fill(n, d.y + r - pg->p.top, x, w);
        }
    int r = d.at - pg->p.top;
    if (r >= 0 && r < pg->body) {
      int bg = d.current ? theme.cursor_bg : theme.bar_bg;
      /* in the margin: a heading's ▸ or ▾, a match's › (a heading that
       * matches has its mark in the match's colour) */
      int hit = matches(pg, i), fold = d.heading && has_body(pg, pg->ln[i].sec);
      dr_style(n, hit ? theme.accent : theme.dim, bg, hit ? A_BOLD : 0);
      if (fold) dr_text(n, d.y + r, x, 1, pg->p.folded[pg->ln[i].sec] ? "▸" : "▾");
      else if (hit) dr_text(n, d.y + r, x, 1, "›");
    }
    rows_of(t, pg, i, draw_row, &d);
    d.at += k;
  }
}

static void destroy(struct tui *t, void *state) {
  struct pager *pg = state;
  page_free(&pg->p);
  for (int i = 0; i < pg->nback; i++) page_free(&pg->back[i]);
  for (int i = 0; i < pg->nfwd; i++) page_free(&pg->fwd[i]);
  free(pg->ln);
  free(pg->sec_head);
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
      if (i <= pg->p.cur) at = n;
    }
  char *m = n ? xasprintf("/%s: %d of %d lines", pg->search, at, n) : xasprintf("/%s: no line holds it", pg->search);
  tui_show_msg(t, !n, m);
  free(m);
}

static void search_typed(struct tui *t, const char *text, void *ud) {
  struct pager *pg = open_pager(t);
  if (!pg) return;
  search_set(pg, text);
  if (!pg->search || !search_go(pg, pg->search_from, 1)) pg->p.cur = pg->search_from;
  tui_dirty(t);
}

static void search_done(struct tui *t, const char *text, void *ud) {
  struct pager *pg = open_pager(t);
  if (!pg) return;
  search_set(pg, text); /* Esc (NULL): back where it was, nothing marked */
  if (!pg->search || !search_go(pg, pg->search_from, 1)) pg->p.cur = pg->search_from;
  if (pg->search) search_say(t, pg);
  tui_dirty(t);
}

/* ---- links, and the pages gone through ---- */

/* the links on line i: the first's index, and how many */
static int links_on(const struct pager *pg, int i, int *first) {
  size_t from = pg->ln[i].off, to = from + pg->ln[i].len;
  const struct rich *r = &pg->p.r;
  int n = 0;
  *first = -1;
  for (int l = 0; l < r->nlinks; l++)
    if (r->links[l].off >= from && r->links[l].off < to) {
      if (*first < 0) *first = l;
      n++;
    }
  return n;
}

static void push(struct page *stack, int *n, struct page *p) {
  if (*n == HISTORY_MAX) { /* the oldest goes */
    page_free(&stack[0]);
    memmove(stack, stack + 1, (HISTORY_MAX - 1) * sizeof *stack);
    (*n)--;
  }
  stack[(*n)++] = *p;
  memset(p, 0, sizeof *p);
}

static void show_page(struct pager *pg, struct page *p) {
  page_free(&pg->p);
  pg->p = *p;
  memset(p, 0, sizeof *p);
  free(pg->search);
  pg->search = NULL;
  split(pg);
}

/* Follows link l: the page shown now is gone back to with back, unless the
 * link leads nowhere, when it stays. */
static void follow(struct tui *t, struct pager *pg, int l) {
  struct page was = pg->p;
  char *target = xstrdup(pg->p.r.links[l].target);
  memset(&pg->p, 0, sizeof pg->p); /* empty until the link's page comes */
  if (guides_follow(t, target, was.where)) {
    push(pg->back, &pg->nback, &was);
    for (int i = 0; i < pg->nfwd; i++) page_free(&pg->fwd[i]);
    pg->nfwd = 0;
  } else {
    show_page(pg, &was);
  }
  free(target);
}

static void link_chosen(struct tui *t, sqlite3_int64 id, const char *text, void *ud) {
  struct pager *pg = open_pager(t);
  if (pg && id >= 0 && id < pg->p.r.nlinks) follow(t, pg, (int)id);
  tui_dirty(t);
}

static void follow_cursor(struct tui *t, struct pager *pg) {
  int first, n = pg->n ? links_on(pg, pg->p.cur, &first) : 0;
  if (n == 0) {
    tui_show_msg(t, 0, "no link on this line");
  } else if (n == 1) {
    follow(t, pg, first);
  } else {
    struct picker *pk = picker_new(t, "follow", link_chosen, NULL);
    for (int l = first; l < first + n; l++) {
      const struct pager_link *k = &pg->p.r.links[l];
      char *text = xstrndup(text_of(&pg->p) + k->off, k->len);
      picker_add(pk, l, text, k->target);
      free(text);
    }
    picker_open(t, pk);
  }
}

/* back (dir -1) or forward through the pages followed */
static void go(struct tui *t, struct pager *pg, int dir) {
  struct page *from = dir < 0 ? pg->back : pg->fwd, *to = dir < 0 ? pg->fwd : pg->back;
  int *nfrom = dir < 0 ? &pg->nback : &pg->nfwd, *nto = dir < 0 ? &pg->nfwd : &pg->nback;
  if (!*nfrom) {
    tui_show_msg(t, 0, dir < 0 ? "at the first page" : "at the last page");
    return;
  }
  struct page now = pg->p;
  memset(&pg->p, 0, sizeof pg->p);
  push(to, nto, &now);
  show_page(pg, &from[--*nfrom]);
}

/* ---- keys ---- */

static void fold_all(struct pager *pg, int folded) {
  for (int s = 0; s < pg->nsec; s++)
    if (has_body(pg, s)) set_fold(pg, s, folded);
}

static int key(struct tui *t, void *state, uint32_t k, const struct ncinput *ni) {
  struct pager *pg = state;
  int sec = pg->n ? pg->ln[pg->p.cur].sec : -1;
  int body = pg->body > 1 ? pg->body : 10;
  int a = ctx_feed(KC_PAGER, &pg->pending, k);
  switch (a) {
    case CTX_PENDING: break;
    case GA_DOWN: pg->p.cur = step(pg, pg->p.cur, 1); break;
    case GA_UP: pg->p.cur = step(pg, pg->p.cur, -1); break;
    case GA_PAGE_DOWN: move_rows(t, pg, 1, body); break;
    case GA_PAGE_UP: move_rows(t, pg, -1, body); break;
    case GA_TOP: pg->p.cur = 0; break;
    case GA_BOTTOM: pg->p.cur = pg->n ? pg->n - 1 : 0; break;
    case GA_TOGGLE:
    case GA_OPEN:
    case GA_CLOSE:
      /* on a line of a section: its heading's */
      if (sec < 0 || !has_body(pg, sec)) break;
      set_fold(pg, sec, a == GA_TOGGLE ? !pg->p.folded[sec] : a == GA_CLOSE);
      if (pg->p.folded[sec]) pg->p.cur = pg->sec_head[sec];
      break;
    case GA_ALL: fold_all(pg, 0); break;
    case GA_NONE: fold_all(pg, 1); break;
    case GA_SEARCH:
      pg->search_from = pg->p.cur;
      tui_input(t, "/", "", search_done, NULL);
      tui_input_on_change(t, search_typed);
      break;
    case GA_NEXT:
    case GA_PREV:
      if (!pg->search) break;
      search_go(pg, pg->p.cur + (a == GA_NEXT ? 1 : -1), a == GA_NEXT ? 1 : -1);
      search_say(t, pg);
      break;
    case GA_FOLLOW: follow_cursor(t, pg); break;
    case GA_BACK: go(t, pg, -1); break;
    case GA_FORWARD: go(t, pg, 1); break;
    default: wm_undock(t, pg); /* frees it */
  }
  (void)ni;
  tui_dirty(t);
  return 1;
}

const struct view_class view_pager = {"pager", NULL, destroy, draw, NULL, key, 1};

void tui_pager_rich(struct tui *t, const char *title, struct rich *text, int open, const char *where) {
  struct pager *pg = open_pager(t);
  int fresh = !pg;
  if (fresh) pg = xcalloc(1, sizeof *pg);
  page_free(&pg->p);
  free(pg->search);
  pg->search = NULL;
  pg->p.r = *text;
  memset(text, 0, sizeof *text);
  pg->p.title = xstrdup(title ? title : "");
  pg->p.where = where ? xstrdup(where) : NULL;
  split(pg);
  for (int s = 0; s < pg->nsec; s++) {
    int r = open < 0 || s < open ? 0 : remembered(pg, s);
    pg->p.folded[s] = (unsigned char)(r >= 0 ? r : 1);
  }
  if (fresh) wm_float(t, &view_pager, pg, 0, FLOAT_BARE);
  tui_dirty(t);
}

void tui_pager_folded(struct tui *t, const char *title, const char *text, int open) {
  struct rich r = {0};
  sb_puts(&r.text, text ? text : "");
  rich_plain(&r);
  tui_pager_rich(t, title, &r, open, NULL);
}

void tui_pager(struct tui *t, const char *title, const char *text) {
  tui_pager_folded(t, title, text, 1 << 30);
}

void tui_pager_at(struct tui *t, int line) {
  struct pager *pg = open_pager(t);
  if (!pg || !pg->n) return;
  cursor_to(pg, line < 0 ? 0 : line < pg->n ? line : pg->n - 1);
  pg->at_top = 1;
}

void tui_pager_end(struct tui *t) {
  struct pager *pg = open_pager(t);
  if (pg && pg->n) pg->p.cur = pg->n - 1;
}

void tui_pager_forget(void) {
  for (int i = 0; i < nmemory; i++) free(memory[i].key);
  free(memory);
  memory = NULL;
  nmemory = 0;
}
