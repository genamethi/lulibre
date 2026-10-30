/* A floating fuzzy finder over a list of strings: books, authors, subjects,
 * and later anything a script hands it. */
#include <stdlib.h>
#include <string.h>

#include "match/fold.h"
#include "match/fuzzy.h"
#include "tui/tui.h"

struct pitem {
  sqlite3_int64 id;
  char *text, *folded, *detail;
  double score;
};

struct picker {
  char *title;
  picker_accept *accept;
  picker_cancel_fn *cancel;
  int accepted;
  void *ud;
  struct pitem *items;
  int n, cap;
  int *order; /* indexes of matching items, best first */
  int nmatch;
  int sel, top;
  struct lineedit query;
  int page;
};

struct picker *picker_new(struct tui *t, const char *title, picker_accept *accept, void *ud) {
  struct picker *p = xcalloc(1, sizeof *p);
  p->title = xstrdup(title);
  p->accept = accept;
  p->ud = ud;
  p->page = 10;
  return p;
}

void picker_on_cancel(struct picker *p, picker_cancel_fn *fn) {
  p->cancel = fn;
}

void picker_add(struct picker *p, sqlite3_int64 id, const char *text, const char *detail) {
  if (p->n == p->cap) {
    p->cap = p->cap ? p->cap * 2 : 256;
    p->items = xrealloc(p->items, (size_t)p->cap * sizeof *p->items);
  }
  struct pitem *it = &p->items[p->n++];
  sbuf f = SBUF_INIT;
  fold_utf8(&f, text, strlen(text));
  it->id = id;
  it->text = xstrdup(text);
  it->folded = sb_take(&f);
  it->detail = detail ? xstrdup(detail) : NULL;
  it->score = 0;
}

static int by_score(const void *a, const void *b, void *arg) {
  const struct pitem *sort_items = arg;
  int ia = *(const int *)a, ib = *(const int *)b;
  double sa = sort_items[ia].score, sb = sort_items[ib].score;
  if (sa != sb) return sa < sb ? 1 : -1;
  return ia - ib; /* ties keep the order items were added in */
}

static void rematch(struct picker *p) {
  sbuf q = SBUF_INIT;
  fold_utf8(&q, p->query.text.s ? p->query.text.s : "", p->query.text.len);
  if (!p->order) p->order = xmalloc(((size_t)p->n + 1) * sizeof *p->order);
  p->nmatch = 0;
  int empty = q.len == 0 || strspn(q.s, " ") == q.len;
  for (int i = 0; i < p->n; i++) {
    p->items[i].score = empty ? 0 : fuzzy_score(q.s, p->items[i].folded);
    if (p->items[i].score > FUZZY_NONE / 2) p->order[p->nmatch++] = i;
  }
  if (!empty) {
    qsort_r(p->order, (size_t)p->nmatch, sizeof *p->order, by_score, p->items);
  }
  p->sel = p->top = 0;
  sb_free(&q);
}

static void picker_free(struct picker *p) {
  for (int i = 0; i < p->n; i++) {
    free(p->items[i].text);
    free(p->items[i].folded);
    free(p->items[i].detail);
  }
  free(p->items);
  free(p->order);
  free(p->title);
  le_free(&p->query);
  free(p);
}

void picker_open(struct tui *t, struct picker *p) {
  if (t->picker) picker_close(t); /* lets whoever was waiting on it know */
  /* the picker takes the keyboard: a line being typed is given up first, so
   * a script waiting on it hears so instead of waiting for ever */
  if (t->mode == MODE_PROMPT) {
    if (t->prompt == PROMPT_INPUT) tui_input_cancel(t);
    else tui_prompt_cancel(t);
  }
  t->picker = p;
  t->mode = MODE_PICKER;
  wm_float(t, &view_picker, p, 0, FLOAT_BARE);
  le_set(&p->query, "");
  rematch(p);
  tui_dirty(t);
}

void *picker_ud_if(struct tui *t, picker_accept *accept) {
  return t->picker && t->picker->accept == accept ? t->picker->ud : NULL;
}

void picker_close(struct tui *t) {
  struct picker *p = t->picker;
  if (!p) return;
  picker_cancel_fn *cancel = p->accepted ? NULL : p->cancel;
  void *ud = p->ud;
  t->picker = NULL;
  t->mode = MODE_NORMAL;
  wm_undock(t, p); /* its window; the picker itself is freed here */
  picker_free(p);
  tui_dirty(t);
  if (cancel) cancel(t, ud);
}

static void move(struct picker *p, int delta) {
  p->sel += delta;
  if (p->sel >= p->nmatch) p->sel = p->nmatch - 1;
  if (p->sel < 0) p->sel = 0;
}

void picker_key(struct tui *t, uint32_t key, const struct ncinput *ni) {
  struct picker *p = t->picker;
  switch (ctx_feed(KC_PICKER, NULL, key)) {
    case KA_CANCEL:
      picker_close(t);
      return;
    case KA_ACCEPT:
      if (p->nmatch > 0) {
        struct pitem *it = &p->items[p->order[p->sel]];
        sqlite3_int64 id = it->id;
        char *text = xstrdup(it->text);
        picker_accept *accept = p->accept;
        void *ud = p->ud;
        p->accepted = 1;
        picker_close(t);
        if (accept) accept(t, id, text, ud);
        free(text);
      }
      return;
    case KA_DOWN: move(p, 1); break;
    case KA_UP: move(p, -1); break;
    case KA_PAGE_DOWN: move(p, p->page); break;
    case KA_PAGE_UP: move(p, -p->page); break;
    default:
      if (le_key(&p->query, key, ni)) rematch(p);
  }
  tui_dirty(t);
}

void picker_draw(struct tui *t) {
  struct picker *p = t->picker;
  struct ncplane *n = t->std;
  int W = t->cols_n, H = t->rows_n;
  int w = W * 7 / 10, h = H * 6 / 10;
  if (w < 40) w = W - 2;
  if (h < 8) h = H - 2;
  if (w < 10 || h < 5) return;
  int x = (W - w) / 2, y = (H - h) / 3;
  int inner = w - 4, list_h = h - 4;
  p->page = list_h > 1 ? list_h - 1 : 1;

  /* frame, and the line under the query */
  dr_frame(n, (struct rect){y, x, h, w}, theme.bar_bg);
  dr_style(n, theme.border, theme.bar_bg, 0);
  for (int c = 1; c < w - 1; c++) ncplane_putstr_yx(n, y + 2, x + c, "─");
  ncplane_putstr_yx(n, y + 2, x, "├");
  ncplane_putstr_yx(n, y + 2, x + w - 1, "┤");

  dr_style(n, theme.accent, theme.bar_bg, A_BOLD);
  char *head = xasprintf(" %s ", p->title);
  dr_text(n, y, x + 2, inner, head);
  free(head);
  char *count = xasprintf(" %d/%d ", p->nmatch, p->n);
  dr_style(n, theme.dim, theme.bar_bg, 0);
  dr_text(n, y + h - 1, x + w - 2 - (int)strlen(count), (int)strlen(count), count);
  free(count);

  /* query line */
  dr_style(n, theme.accent, theme.bar_bg, A_BOLD);
  ncplane_putstr_yx(n, y + 1, x + 2, "›");
  dr_style(n, C_DEFAULT, theme.bar_bg, 0);
  const char *q = p->query.text.s ? p->query.text.s : "";
  dr_text(n, y + 1, x + 4, inner - 2, q);
  notcurses_cursor_enable(t->nc, y + 1, x + 4 + dr_width(q, p->query.cur));

  /* matches */
  if (p->sel < p->top) p->top = p->sel;
  if (p->sel >= p->top + list_h) p->top = p->sel - list_h + 1;
  for (int i = 0; i < list_h && p->top + i < p->nmatch; i++) {
    struct pitem *it = &p->items[p->order[p->top + i]];
    int selected = p->top + i == p->sel;
    int bg = selected ? theme.cursor_bg : theme.bar_bg;
    dr_style(n, C_DEFAULT, bg, selected ? A_BOLD : 0);
    dr_fill(n, y + 3 + i, x + 1, w - 2);
    int dw = it->detail ? dr_width(it->detail, strlen(it->detail)) : 0;
    if (dw > inner / 3) dw = inner / 3;
    dr_text(n, y + 3 + i, x + 2, inner - (dw ? dw + 2 : 0), it->text);
    if (dw) {
      dr_style(n, theme.dim, bg, 0);
      dr_text(n, y + 3 + i, x + 2 + inner - dw, dw, it->detail);
    }
  }
}

/* the picker as a floating window: it draws its own box, and every key is its own */
static void view_draw(struct tui *t, void *state, struct rect r, int focused) {
  if (t->picker == state) picker_draw(t);
}

static int view_key(struct tui *t, void *state, uint32_t key, const struct ncinput *ni) {
  if (t->picker == state) picker_key(t, key, ni);
  return 1;
}

const struct view_class view_picker = {"picker", NULL, NULL, view_draw, NULL, view_key, 1};
