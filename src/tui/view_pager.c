/* The pager: a text over the windows (?, :messages, :tasks), a floating
 * window drawn as a box of its own (wm_float, FLOAT_BARE). Its keys are the
 * place "pager"; any other key closes it. While it is up every key is its
 * own, and the mouse only selects (modal). */
#include <stdlib.h>
#include <string.h>

#include "tui/tui.h"

struct pager {
  char *text, *title;
  int scroll;
};

/* Each line wraps at the box's width, and what wraps lines up under the
 * line's own indent. Calls fn for every line as shown and returns how many
 * there are. */
typedef void pager_line_fn(struct tui *t, int i, int indent, const char *s, size_t len, int heading, void *ud);

static int pager_lines(struct tui *t, const char *text, int w, pager_line_fn *fn, void *ud) {
  int n = 0;
  for (const char *p = text; *p;) {
    const char *nl = strchr(p, '\n');
    size_t len = nl ? (size_t)(nl - p) : strlen(p);
    int heading = len > 0 && p[0] != ' ';
    size_t ind = 0;
    while (ind < len && p[ind] == ' ') ind++;
    if ((int)ind > w / 2) ind = 0;
    size_t i = 0;
    do {
      int lead = i ? (int)ind : 0;
      size_t k = dr_wrap(p + i, len - i, w - lead), shown = k;
      if (i + k < len)
        while (shown > 0 && p[i + shown - 1] == ' ') shown--;
      if (fn) fn(t, n, lead, p + i, shown, heading, ud);
      n++;
      i += k;
      while (i && i < len && p[i] == ' ') i++; /* a wrapped line starts at a word */
    } while (i < len);
    p = nl ? nl + 1 : p + len;
  }
  return n;
}

struct pager_draw {
  int x, y, h, from;
};

static void draw_line(struct tui *t, int i, int indent, const char *s, size_t len, int heading, void *ud) {
  struct pager_draw *d = ud;
  int r = i - d->from + 1; /* the box's first row is its title */
  if (r < 1 || r >= d->h - 1) return;
  dr_style(t->std, heading ? theme.accent : C_DEFAULT, theme.bar_bg, heading ? A_BOLD : 0);
  dr_textn(t->std, d->y + r, d->x + indent, 1 << 30, s, len);
}

static void draw(struct tui *t, void *state, struct rect area, int focused) {
  struct pager *pg = state;
  struct ncplane *n = t->std;
  int W = t->cols_n, H = t->rows_n;
  int w = W > 84 ? 80 : W - 2, h = H - 4;
  if (w < 20 || h < 4) return;
  int x = (W - w) / 2, y = 1;
  int total = pager_lines(t, pg->text, w - 4, NULL, NULL);
  if (pg->scroll > total - h + 2) pg->scroll = total - h + 2;
  if (pg->scroll < 0) pg->scroll = 0;

  for (int r = 0; r < h; r++) {
    dr_style(n, C_DEFAULT, theme.bar_bg, 0);
    dr_fill(n, y + r, x, w);
  }
  dr_style(n, theme.dim, theme.bar_bg, 0);
  dr_text(n, y, x + 2, w - 4, pg->title);
  struct pager_draw d = {x + 2, y, h, pg->scroll};
  pager_lines(t, pg->text, w - 4, draw_line, &d);
}

static void destroy(struct tui *t, void *state) {
  struct pager *pg = state;
  free(pg->text);
  free(pg->title);
  free(pg);
}

static int key(struct tui *t, void *state, uint32_t k, const struct ncinput *ni) {
  struct pager *pg = state;
  switch (ctx_feed(KC_PAGER, NULL, k)) {
    case GA_DOWN: pg->scroll++; break;
    case GA_UP: pg->scroll--; break;
    case GA_PAGE_DOWN: pg->scroll += 10; break;
    case GA_PAGE_UP: pg->scroll -= 10; break;
    case GA_TOP: pg->scroll = 0; break;
    default: wm_undock(t, pg); /* frees it */
  }
  tui_dirty(t);
  return 1;
}

const struct view_class view_pager = {"pager", NULL, destroy, draw, NULL, key, 1};

void tui_pager(struct tui *t, const char *title, const char *text) {
  struct node *open = wm_find(t, &view_pager);
  struct pager *pg = open ? open->state : xcalloc(1, sizeof *pg);
  free(pg->text);
  free(pg->title);
  pg->text = xstrdup(text ? text : "");
  pg->title = xstrdup(title ? title : "");
  pg->scroll = 0;
  if (!open) wm_float(t, &view_pager, pg, 0, FLOAT_BARE);
  tui_dirty(t);
}

void tui_pager_end(struct tui *t) {
  struct node *open = wm_find(t, &view_pager);
  if (open) ((struct pager *)open->state)->scroll = 1 << 20; /* drawing clamps it */
}
