#include <stdlib.h>
#include <string.h>

#include "tui/tui.h"

struct prow {
  char **cells;
  int ncells;
  sqlite3_int64 id;
  int style;
};

struct panel {
  struct tui *t;
  int refs; /* the window and the opener */
  int open;
  char *title, *help;
  char **col_titles;
  int *col_widths;
  int ncols;
  struct prow *rows;
  int nrows, cap;
  int cur, top, page;
  int follow, moves, pending_g;
  panel_event_fn *event;
  void *event_ud;
};

static void free_rows(struct panel *p) {
  for (int i = 0; i < p->nrows; i++) {
    for (int c = 0; c < p->rows[i].ncells; c++) free(p->rows[i].cells[c]);
    free(p->rows[i].cells);
  }
  p->nrows = 0;
}

static void free_cols(struct panel *p) {
  for (int i = 0; i < p->ncols; i++) free(p->col_titles[i]);
  free(p->col_titles);
  free(p->col_widths);
  p->col_titles = NULL;
  p->col_widths = NULL;
  p->ncols = 0;
}

void panel_unref(struct panel *p) {
  if (--p->refs > 0) return;
  free_rows(p);
  free(p->rows);
  free_cols(p);
  free(p->title);
  free(p->help);
  free(p);
}

struct panel *panel_open(struct tui *t, float size, char side) {
  struct panel *p = xcalloc(1, sizeof *p);
  p->t = t;
  p->refs = 2;
  p->open = 1;
  p->title = xstrdup("");
  p->help = xstrdup("");
  p->page = 10;
  wm_dock(t, &view_panel, p, size, side);
  return p;
}

int panel_is_open(const struct panel *p) {
  return p->open;
}

void panel_close(struct panel *p) {
  if (!p->open) return;
  wm_undock(p->t, p); /* frees the window, which calls destroy() below */
}

/* The window is going away, by panel_close, <C-w>c, or at exit. */
static void destroy(struct tui *t, void *state) {
  struct panel *p = state;
  p->open = 0;
  panel_event_fn *fn = p->event;
  p->event = NULL;
  if (fn) fn(p, NULL, -1, p->event_ud);
  panel_unref(p);
}

void panel_on_event(struct panel *p, panel_event_fn *fn, void *ud) {
  p->event = fn;
  p->event_ud = ud;
}

void panel_set_title(struct panel *p, const char *title) {
  free(p->title);
  p->title = xstrdup(title ? title : "");
  tui_dirty(p->t);
}

void panel_set_help(struct panel *p, const char *help) {
  free(p->help);
  p->help = xstrdup(help ? help : "");
  tui_dirty(p->t);
}

void panel_set_follow(struct panel *p, int follow) {
  p->follow = follow;
}

void panel_set_columns(struct panel *p, int n, const char *const *titles, const int *widths) {
  free_cols(p);
  p->col_titles = xcalloc((size_t)n, sizeof *p->col_titles);
  p->col_widths = xcalloc((size_t)n, sizeof *p->col_widths);
  for (int i = 0; i < n; i++) {
    p->col_titles[i] = xstrdup(titles[i] ? titles[i] : "");
    p->col_widths[i] = widths[i];
  }
  p->ncols = n;
  tui_dirty(p->t);
}

void panel_clear_rows(struct panel *p) {
  free_rows(p);
  tui_dirty(p->t);
}

void panel_add_row(struct panel *p, int ncells, const char *const *cells, sqlite3_int64 id,
                   int style) {
  if (p->nrows == p->cap) {
    p->cap = p->cap ? p->cap * 2 : 64;
    p->rows = xrealloc(p->rows, (size_t)p->cap * sizeof *p->rows);
  }
  struct prow *r = &p->rows[p->nrows++];
  r->cells = xcalloc((size_t)(ncells > 0 ? ncells : 1), sizeof *r->cells);
  for (int i = 0; i < ncells; i++) r->cells[i] = xstrdup(cells[i] ? cells[i] : "");
  r->ncells = ncells;
  r->id = id;
  r->style = style;
  tui_dirty(p->t);
}

int panel_cursor(const struct panel *p) {
  return p->nrows ? p->cur : -1;
}

static void follow(struct panel *p) {
  if (!p->follow || !p->open || p->cur < 0 || p->cur >= p->nrows) return;
  sqlite3_int64 id = p->rows[p->cur].id;
  if (id > 0 && id != rows_current(p->t) && rows_goto_id(p->t, id)) preview_book_changed(p->t);
}

void panel_set_cursor(struct panel *p, int row) {
  if (row >= p->nrows) row = p->nrows - 1;
  if (row < 0) row = 0;
  p->cur = row;
  follow(p);
  tui_dirty(p->t);
}

void panel_set_moves(struct panel *p, int moves) {
  p->moves = moves;
}

/* Returns 1 for a key that moves the cursor (and moves it), else 0. */
static int motion(struct panel *p, uint32_t key, int was_g) {
  switch (key) {
    case 'j': case NCKEY_DOWN: panel_set_cursor(p, p->cur + 1); return 1;
    case 'k': case NCKEY_UP: panel_set_cursor(p, p->cur - 1); return 1;
    case 'G': case NCKEY_END: panel_set_cursor(p, p->nrows - 1); return 1;
    case NCKEY_HOME: panel_set_cursor(p, 0); return 1;
    case 'g':
      if (was_g) panel_set_cursor(p, 0);
      else p->pending_g = 1;
      return 1;
    case KEY_CTRL | 'd': panel_set_cursor(p, p->cur + p->page / 2 + 1); return 1;
    case KEY_CTRL | 'u': panel_set_cursor(p, p->cur - p->page / 2 - 1); return 1;
    case KEY_CTRL | 'f': case NCKEY_PGDOWN: panel_set_cursor(p, p->cur + p->page); return 1;
    case KEY_CTRL | 'b': case NCKEY_PGUP: panel_set_cursor(p, p->cur - p->page); return 1;
  }
  return 0;
}

static void moved(struct panel *p, int before) {
  if (p->moves && p->event && p->cur != before) p->event(p, "<Move>", p->cur, p->event_ud);
}

void panel_click(struct panel *p, int line) {
  int before = p->cur, row = p->top + line - 2; /* below the bar and the column titles */
  if (line < 2 || row >= p->nrows) return;
  panel_set_cursor(p, row);
  moved(p, before);
}

void panel_wheel(struct panel *p, int delta) {
  int before = p->cur;
  panel_set_cursor(p, p->cur + delta);
  moved(p, before);
}

int panel_key(struct tui *t, struct panel *p, uint32_t key) {
  int was_g = p->pending_g, before = p->cur;
  p->pending_g = 0;
  if (motion(p, key, was_g)) {
    moved(p, before);
    return 1;
  }
  switch (key) {
    case 'q':
    case NCKEY_ESC:
      panel_close(p);
      return 1;
    /* these stay global, so the list and preview remain reachable */
    case NCKEY_TAB:
    case ':':
    case KEY_CTRL | 'w':
      return 0;
  }
  if (p->event) {
    sbuf k = SBUF_INIT;
    key_format(&k, &key, 1);
    p->event(p, k.s, p->nrows ? p->cur : -1, p->event_ud);
    sb_free(&k);
  }
  return 1;
}

static int style_color(int style) {
  switch (style) {
    case PSTYLE_DIM: return theme.dim;
    case PSTYLE_ACCENT: case PSTYLE_HEAD: return theme.accent;
    case PSTYLE_OK: return theme.ok;
    case PSTYLE_WARN: return theme.warn;
    case PSTYLE_ERROR: return theme.error;
    default: return C_DEFAULT;
  }
}

static void draw(struct tui *t, void *state, struct rect r, int focused) {
  struct panel *p = state;
  struct ncplane *n = t->std;

  /* title bar, with the key help on the right */
  dr_bar(n, r, focused);
  int used = dr_text(n, r.y, r.x + 1, r.w - 2, p->title);
  int hw = dr_width(p->help, strlen(p->help));
  if (hw && used + hw + 4 <= r.w) {
    dr_style(n, focused ? theme.on_accent : theme.dim, focused ? theme.accent : theme.bar_bg, 0);
    dr_text(n, r.y, r.x + r.w - hw - 1, hw, p->help);
  }
  if (r.h < 3 || p->ncols == 0) return;

  /* column positions: fixed widths first, the rest shared by weight */
  int x[32], w[32], nc = p->ncols < 32 ? p->ncols : 32;
  int fixed = 0, weight = 0, avail = r.w - 2 - (nc - 1);
  for (int c = 0; c < nc; c++) {
    if (p->col_widths[c] > 0) fixed += p->col_widths[c];
    else weight += p->col_widths[c] < 0 ? -p->col_widths[c] : 1;
  }
  int flex = avail - fixed > 0 ? avail - fixed : 0, pos = r.x + 1;
  for (int c = 0; c < nc; c++) {
    int cw = p->col_widths[c] > 0 ? p->col_widths[c]
           : weight ? flex * (p->col_widths[c] < 0 ? -p->col_widths[c] : 1) / weight : 0;
    x[c] = pos;
    w[c] = cw;
    pos += cw + 1;
  }

  dr_style(n, theme.dim, C_DEFAULT, A_BOLD);
  for (int c = 0; c < nc; c++) dr_text(n, r.y + 1, x[c], w[c], p->col_titles[c]);

  int body = r.h - 2;
  p->page = body > 1 ? body : 1;
  if (p->cur >= p->nrows) p->cur = p->nrows - 1;
  if (p->cur < 0) p->cur = 0;
  if (p->cur < p->top) p->top = p->cur;
  if (p->cur >= p->top + body) p->top = p->cur - body + 1;
  if (p->top > p->nrows - body) p->top = p->nrows - body;
  if (p->top < 0) p->top = 0;

  for (int i = 0; i < body && p->top + i < p->nrows; i++) {
    struct prow *row = &p->rows[p->top + i];
    int y = r.y + 2 + i, current = p->top + i == p->cur;
    int bg = current ? (focused ? theme.cursor_bg : theme.cursor_bg_blur) : C_DEFAULT;
    dr_style(n, C_DEFAULT, bg, 0);
    if (current) dr_fill(n, y, r.x, r.w);
    dr_style(n, style_color(row->style), bg, row->style == PSTYLE_HEAD ? A_BOLD : 0);
    if (row->style == PSTYLE_HEAD) { /* a heading spans the row */
      dr_text(n, y, x[0], r.w - 2, row->ncells ? row->cells[0] : "");
      continue;
    }
    for (int c = 0; c < nc && c < row->ncells; c++) dr_text(n, y, x[c], w[c], row->cells[c]);
  }
}

const struct view_class view_panel = {"panel", NULL, destroy, draw, NULL};
