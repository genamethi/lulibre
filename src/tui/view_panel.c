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
  float size; /* its share of the screen, and the edge it is docked on */
  char side;
  int hidden; /* taken off the screen for a while (panel_hide), not closed */
  uint32_t *own; /* keys the script handles itself; the rest may pass to global bindings */
  int nown;
  char *pass; /* first words of the global commands that may be reached from here */
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
  free(p->own);
  free(p->pass);
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
  p->size = size;
  p->side = side;
  wm_dock(t, &view_panel, p, size, side);
  return p;
}

int panel_is_open(const struct panel *p) {
  return p->open;
}

/* The panel is closed for good: say so, and drop the window's reference. */
static void gone(struct panel *p) {
  p->open = 0;
  panel_event_fn *fn = p->event;
  p->event = NULL;
  if (fn) fn(p, NULL, -1, p->event_ud);
  panel_unref(p);
}

void panel_close(struct panel *p) {
  if (!p->open) return;
  if (p->hidden) { /* it has no window to close */
    p->hidden = 0;
    gone(p);
    return;
  }
  wm_undock(p->t, p); /* frees the window, which calls destroy() below */
}

/* The window is going away, by panel_close, panel_hide, <C-w>c, or at exit. */
static void destroy(struct tui *t, void *state) {
  struct panel *p = state;
  t->peek = 0;
  if (!p->hidden) gone(p);
}

void panel_hide(struct panel *p) {
  if (!p->open || p->hidden) return;
  p->hidden = 1;
  wm_undock(p->t, p);
}

static void follow(struct panel *p);

void panel_show(struct panel *p) {
  if (!p->open || !p->hidden) return;
  p->hidden = 0;
  wm_dock(p->t, &view_panel, p, p->size, p->side);
  follow(p);
}

void panel_set_size(struct panel *p, float size) {
  p->size = size;
  if (p->open && !p->hidden) wm_set_size(p->t, p, size);
}

void panel_set_pass(struct panel *p, const char *commands) {
  free(p->pass);
  p->pass = commands && *commands ? xstrdup(commands) : NULL;
}

void panel_set_own(struct panel *p, int n, const uint32_t *keys) {
  free(p->own);
  p->own = n > 0 ? xmalloc((size_t)n * sizeof *keys) : NULL;
  if (n > 0) memcpy(p->own, keys, (size_t)n * sizeof *keys);
  p->nown = n > 0 ? n : 0;
}

/* Is this key one that goes past the panel to a global binding? Only for a
 * panel that has said which keys are its own, only for a key that is not,
 * and only when it starts a binding to one of the commands let through. */
int panel_passes(const struct panel *p, uint32_t key) {
  if (!p->open || !p->pass || !p->nown) return 0;
  switch (key) { /* the panel's movement, always its own */
    case 'j': case 'k': case 'g': case 'G': case 'q': case NCKEY_ESC: case NCKEY_UP: case NCKEY_DOWN:
    case NCKEY_HOME: case NCKEY_END: case NCKEY_PGUP: case NCKEY_PGDOWN:
    case KEY_CTRL | 'd': case KEY_CTRL | 'u': case KEY_CTRL | 'f': case KEY_CTRL | 'b':
      return 0;
  }
  for (int i = 0; i < p->nown; i++)
    if (p->own[i] == key) return 0;
  return keymap_starts(p->t->km, MODE_NORMAL, key, p->pass);
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
  if (!p->follow || !p->open || p->hidden || p->cur < 0 || p->cur >= p->nrows) return;
  struct tui *t = p->t;
  sqlite3_int64 id = p->rows[p->cur].id; /* negative for a file staged from the sync folder */
  sqlite3_int64 was = t->peek;
  t->peek = 0;
  if (id != 0 && id != rows_current(t)) {
    /* a book the list does not hold (the filter leaves it out) can still be
     * looked at: the preview shows it without the list moving */
    if (!rows_goto_id(t, id)) t->peek = id;
    preview_book_changed(t);
  } else if (was) {
    preview_book_changed(t);
  }
}

int panel_points_at(const struct panel *p, sqlite3_int64 *id) {
  if (!p->follow || !p->open) return 0;
  *id = p->cur >= 0 && p->cur < p->nrows ? p->rows[p->cur].id : 0;
  return 1;
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
    case PSTYLE_DIM: case PSTYLE_NOTE: return theme.dim;
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
    if (row->style == PSTYLE_HEAD || row->style == PSTYLE_NOTE) { /* these span the row */
      dr_text(n, y, x[0], r.w - 2, row->ncells ? row->cells[0] : "");
      continue;
    }
    for (int c = 0; c < nc && c < row->ncells; c++) dr_text(n, y, x[c], w[c], row->cells[c]);
  }
}

const struct view_class view_panel = {"panel", NULL, destroy, draw, NULL};
