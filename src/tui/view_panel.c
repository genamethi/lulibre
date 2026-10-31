#include <stdlib.h>
#include <string.h>

#include "match/fold.h"
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
  char **tabs; /* names shown in the bar after the title; the script switches between them */
  int ntabs, tab;
  int tab_x[PANEL_TABS], tab_w[PANEL_TABS]; /* where each was drawn, for the mouse */
  char **col_titles;
  int *col_widths;
  int ncols;
  struct prow *rows;
  int nrows, cap;
  int cur, top, page;
  int follow, moves, reloads;
  /* what the preview shows while this panel is up, whatever its rows: a
   * book, or a note in place of one (panel_set_preview) */
  int pv_set;
  sqlite3_int64 pv_id;
  char *pv_note;
  int dialog; /* Esc closes it, as q does (panel_set_dialog) */
  uint32_t pending; /* the first key of a two-key binding such as gg */
  float size; /* its share of the screen, and the edge it is docked on */
  char side;
  int hidden; /* taken off the screen for a while (panel_hide), not closed */
  uint32_t *own; /* keys the script handles itself; the rest may pass to global bindings */
  int nown;
  char *pass; /* first words of the global commands that may be reached from here */
  panel_event_fn *event;
  void *event_ud;
  char *search;    /* what / looks for in the rows, folded; NULL for nothing */
  int search_from; /* the row the cursor was on when / was pressed */
  int place;          /* its screen's place (ctxkeys.c), whose actions its keys mean; -1 for none */
  uint32_t ppending;  /* the first key of a two-key action of that place */
  /* a form (panel_set_form): a row is a field */
  int form;
  char **names, **change; /* each field's name; its change in a staged form, NULL for none */
  int nfields, editing;   /* the row being typed, or -1 */
  uint32_t fpending;
};

static void free_rows(struct panel *p) {
  for (int i = 0; i < p->nrows; i++) {
    for (int c = 0; c < p->rows[i].ncells; c++) free(p->rows[i].cells[c]);
    free(p->rows[i].cells);
  }
  p->nrows = 0;
}

static void free_tabs(struct panel *p) {
  for (int i = 0; i < p->ntabs; i++) free(p->tabs[i]);
  free(p->tabs);
  p->tabs = NULL;
  p->ntabs = 0;
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
  free_tabs(p);
  free(p->own);
  free(p->pass);
  free(p->pv_note);
  free(p->search);
  for (int i = 0; i < p->nfields; i++) {
    free(p->names[i]);
    free(p->change[i]);
  }
  free(p->names);
  free(p->change);
  free(p);
}

/* its window, where its side says: over the list (m), floating (f), over
 * every window (o), beside the focused window (t), else docked on the left
 * (l) or along the bottom */
static void place_window(struct panel *p) {
  if (p->side == 'm') wm_over_list(p->t, &view_panel, p);
  else if (p->side == 'f' || p->side == 'o') wm_float(p->t, &view_panel, p, p->size, p->side == 'o' ? FLOAT_FULL : FLOAT_BOX);
  else if (p->side == 't') wm_tile(p->t, &view_panel, p, p->size);
  else wm_dock(p->t, &view_panel, p, p->size, p->side);
}

struct panel *panel_open(struct tui *t, float size, char side) {
  struct panel *p = xcalloc(1, sizeof *p);
  p->t = t;
  p->refs = 2;
  p->open = 1;
  p->title = xstrdup("");
  p->help = xstrdup("");
  p->page = 10;
  p->place = -1;
  p->editing = -1;
  p->size = size;
  p->side = side;
  place_window(p);
  return p;
}

int panel_is_open(const struct panel *p) {
  return p->open;
}

static void form_typed(struct tui *t, const char *text, void *ud);

/* The panel is closed for good: say so, and drop the window's reference. */
static void gone(struct panel *p) {
  p->open = 0;
  if (p->editing >= 0 && p->t->input_cb == form_typed && p->t->input_ud == p) tui_input_cancel(p->t);
  if (p->t->screen_tab == p) {
    p->t->screen_tab = NULL;
    tui_dirty(p->t);
  }
  panel_event_fn *fn = p->event;
  p->event = NULL;
  if (fn) fn(p, NULL, -1, NULL, p->event_ud);
  panel_unref(p);
}

void panel_set_screen_tab(struct panel *p) {
  if (!p->open) return;
  p->t->screen_tab = p;
  tui_dirty(p->t);
}

void panel_leave_screen_tab(struct tui *t) {
  if (t->screen_tab) panel_close(t->screen_tab);
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
  if (t->preview_note) {
    free(t->preview_note);
    t->preview_note = NULL;
  }
  preview_book_changed(t);
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
  place_window(p);
  follow(p);
}

/* The cursor to this panel, brought back first if it was hidden. */
void panel_focus(struct panel *p) {
  if (!p->open) return;
  panel_show(p);
  struct node *n = wm_leaf_of(p->t, p);
  if (n) p->t->focus = n;
  tui_dirty(p->t);
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

/* Is this key one that goes past the panel to a global binding? Not when
 * the panel has it: its movement, its screen's actions, the keys it said
 * are its own. Help (?) goes past any panel; other commands only past a
 * panel that has said which keys are its own, and only those let through. */
int panel_passes(const struct panel *p, uint32_t key) {
  if (!p->open) return 0;
  if (p->pending || ctx_bound(KC_PANEL, key)) return 0; /* the panel's movement, always its own */
  if (p->place >= 0 && (p->ppending || ctx_bound(p->place, key))) return 0; /* its screen's actions */
  if (p->form && (p->fpending || ctx_bound(KC_FORM, key))) return 0;         /* a form's */
  for (int i = 0; i < p->nown; i++)
    if (p->own[i] == key) return 0;
  if (keymap_starts(p->t->km, MODE_NORMAL, key, "help")) return 1;
  if (!p->pass || (!p->nown && p->place < 0)) return 0;
  return keymap_starts(p->t->km, MODE_NORMAL, key, p->pass);
}

int panel_place(const struct panel *p) {
  return p->place;
}

void panel_set_place(struct panel *p, int place) {
  p->place = place;
  p->ppending = 0;
  tui_dirty(p->t);
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

void panel_set_tabs(struct panel *p, int n, const char *const *names, int current) {
  free_tabs(p);
  if (n > PANEL_TABS) n = PANEL_TABS;
  if (n > 0) p->tabs = xcalloc((size_t)n, sizeof *p->tabs);
  for (int i = 0; i < n; i++) p->tabs[i] = xstrdup(names[i] ? names[i] : "");
  p->ntabs = n;
  p->tab = current < 0 ? 0 : current >= n ? n - 1 : current;
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

static struct prow *new_row(struct panel *p) {
  if (p->nrows == p->cap) {
    p->cap = p->cap ? p->cap * 2 : 64;
    p->rows = xrealloc(p->rows, (size_t)p->cap * sizeof *p->rows);
  }
  tui_dirty(p->t);
  return &p->rows[p->nrows++];
}

static void fill_row(struct prow *r, int ncells, const char *const *cells, sqlite3_int64 id, int style) {
  r->cells = xcalloc((size_t)(ncells > 0 ? ncells : 1), sizeof *r->cells);
  for (int i = 0; i < ncells; i++) r->cells[i] = xstrdup(cells[i] ? cells[i] : "");
  r->ncells = ncells;
  r->id = id;
  r->style = style;
}

void panel_add_row(struct panel *p, int ncells, const char *const *cells, sqlite3_int64 id,
                   int style) {
  fill_row(new_row(p), ncells, cells, id, style);
}

int panel_cursor(const struct panel *p) {
  return p->nrows ? p->cur : -1;
}

static void follow(struct panel *p) {
  if (p->pv_set && p->open && !p->hidden) {
    struct tui *t = p->t;
    free(t->preview_note);
    t->preview_note = p->pv_note ? xstrdup(p->pv_note) : NULL;
    t->peek = p->pv_note ? 0 : p->pv_id;
    preview_book_changed(t);
    return;
  }
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

void panel_set_preview(struct panel *p, int set, sqlite3_int64 id, const char *note) {
  free(p->pv_note);
  p->pv_set = set;
  p->pv_id = id;
  p->pv_note = set && note ? xstrdup(note) : NULL;
  if (set) {
    follow(p);
  } else if (p->open && !p->hidden) {
    free(p->t->preview_note);
    p->t->preview_note = NULL;
    p->t->peek = 0;
    preview_book_changed(p->t);
    follow(p);
  }
  tui_dirty(p->t);
}

void panel_set_moves(struct panel *p, int moves) {
  p->moves = moves;
}

void panel_set_dialog(struct panel *p, int dialog) {
  p->dialog = dialog;
}

void panel_set_reloads(struct panel *p, int reloads) {
  p->reloads = reloads;
}

void panels_reloaded(struct tui *t) {
  struct node *all[32];
  int n = wm_leaves(t, all, 32);
  for (int i = 0; i < n; i++) {
    if (all[i]->cls != &view_panel) continue;
    struct panel *p = all[i]->state;
    if (p->reloads && p->open && p->event) p->event(p, "<Reload>", p->nrows ? p->cur : -1, NULL, p->event_ud);
  }
}

/* Returns 1 for an action that moves the cursor (and moves it), else 0. */
static int motion(struct panel *p, int action) {
  switch (action) {
    case PA_DOWN: panel_set_cursor(p, p->cur + 1); return 1;
    case PA_UP: panel_set_cursor(p, p->cur - 1); return 1;
    case PA_BOTTOM: panel_set_cursor(p, p->nrows - 1); return 1;
    case PA_TOP: panel_set_cursor(p, 0); return 1;
    case PA_HALF_DOWN: panel_set_cursor(p, p->cur + p->page / 2 + 1); return 1;
    case PA_HALF_UP: panel_set_cursor(p, p->cur - p->page / 2 - 1); return 1;
    case PA_PAGE_DOWN: panel_set_cursor(p, p->cur + p->page); return 1;
    case PA_PAGE_UP: panel_set_cursor(p, p->cur - p->page); return 1;
  }
  return 0;
}

static void moved(struct panel *p, int before) {
  if (p->moves && p->event && p->cur != before) p->event(p, "<Move>", p->cur, NULL, p->event_ud);
}

void panel_click(struct panel *p, int line, int x) {
  int before = p->cur, row = p->top + line - 2; /* below the bar and the column titles */
  if (line == 0 && p->event) { /* a tab in the bar: the script is told which */
    for (int i = 0; i < p->ntabs; i++)
      if (p->tab_w[i] > 0 && x >= p->tab_x[i] && x < p->tab_x[i] + p->tab_w[i]) {
        p->event(p, "<Tab>", i, NULL, p->event_ud);
        return;
      }
  }
  if (line < 2 || row >= p->nrows) return;
  panel_set_cursor(p, row);
  moved(p, before);
}

void panel_wheel(struct panel *p, int delta) {
  int before = p->cur;
  panel_set_cursor(p, p->cur + delta);
  moved(p, before);
}

/* ---- / in a panel, as in the list: the rows holding the text (case and
 * accents aside) are marked, the cursor goes to the next one as it is typed,
 * n and N step through them. A key the screen handles itself stays the
 * screen's (help's own /, review's N). */

static int owns(const struct panel *p, uint32_t key) {
  for (int i = 0; i < p->nown; i++)
    if (p->own[i] == key) return 1;
  return 0;
}

static int row_matches(const struct panel *p, int i) {
  if (!p->search || !*p->search) return 0;
  const struct prow *row = &p->rows[i];
  for (int c = 0; c < row->ncells; c++) {
    sbuf f = SBUF_INIT;
    fold_utf8(&f, row->cells[c], strlen(row->cells[c]));
    int hit = f.s && strstr(f.s, p->search);
    sb_free(&f);
    if (hit) return 1;
  }
  return 0;
}

/* the cursor to the first match from row `from` on, in direction dir,
 * coming round at the end; 0 when no row matches */
static int search_go(struct panel *p, int from, int dir) {
  for (int k = 0; k < p->nrows; k++) {
    int i = ((from + dir * k) % p->nrows + p->nrows) % p->nrows;
    if (row_matches(p, i)) {
      panel_set_cursor(p, i);
      return 1;
    }
  }
  return 0;
}

static void search_say(struct panel *p) {
  int n = 0, at = 0;
  for (int i = 0; i < p->nrows; i++)
    if (row_matches(p, i)) {
      n++;
      if (i <= p->cur) at = n;
    }
  char *m = n ? xasprintf("/%s: %d of %d rows", p->search, at, n) : xasprintf("/%s: no row holds it", p->search);
  tui_show_msg(p->t, !n, m);
  free(m);
}

static void search_set(struct panel *p, const char *text) {
  free(p->search);
  p->search = NULL;
  if (text && *text) {
    sbuf f = SBUF_INIT;
    fold_utf8(&f, text, strlen(text));
    p->search = sb_take(&f);
  }
}

static void search_typed(struct tui *t, const char *text, void *ud) {
  struct panel *p = ud;
  if (!p->open) return;
  search_set(p, text);
  if (!p->search || !search_go(p, p->search_from, 1)) panel_set_cursor(p, p->search_from);
  tui_dirty(t);
}

static void search_done(struct tui *t, const char *text, void *ud) {
  struct panel *p = ud;
  if (p->open) {
    int from = p->search_from;
    search_set(p, text); /* Esc (NULL): back where it was, nothing marked */
    if (!p->search || !search_go(p, from, 1)) panel_set_cursor(p, from);
    if (p->search) search_say(p);
    moved(p, from);
    tui_dirty(t);
  }
  panel_unref(p);
}

static int search_key(struct tui *t, struct panel *p, uint32_t key) {
  if (owns(p, key)) return 0;
  if (key == '/') {
    p->refs++; /* until the line is done with it */
    p->search_from = p->cur;
    tui_input(t, "/", "", search_done, p);
    tui_input_on_change(t, search_typed);
    return 1;
  }
  if ((key == 'n' || key == 'N') && p->search) {
    int before = p->cur;
    if (search_go(p, p->cur + (key == 'n' ? 1 : -1), key == 'n' ? 1 : -1)) moved(p, before);
    search_say(p);
    return 1;
  }
  return 0;
}

/* ---- a form: its rows are fields ---- */

/* field i's row: its label, its value and its change (staged) or its note */
static void field_row(struct panel *p, struct prow *r, int i, const char *label, const char *value, const char *note) {
  const char *c = p->change[i], *cells[] = {label, value, c ? (*c ? c : "(blank)") : note ? note : ""};
  fill_row(r, p->form == FORM_STAGED || note ? 3 : 2, cells, 0, c ? PSTYLE_ACCENT : PSTYLE_NORMAL);
}

void panel_set_form(struct panel *p, int kind) {
  p->form = kind;
  const char *titles[] = {"Field", kind == FORM_STAGED ? "Now" : "Value", "To be"};
  int widths[] = {16, 0, 0};
  if (!p->ncols) panel_set_columns(p, kind == FORM_STAGED ? 3 : 2, titles, widths); /* unless the opener gave some */
}

int panel_form(const struct panel *p) {
  return p->form;
}

void panel_set_fields(struct panel *p, int n, const char *const *names, const char *const *labels,
                      const char *const *values, const char *const *notes) {
  char **was = p->names, **changes = p->change;
  int nwas = p->nfields, cur = p->cur;
  p->names = xcalloc((size_t)n + 1, sizeof *p->names);
  p->change = xcalloc((size_t)n + 1, sizeof *p->change);
  p->nfields = n;
  free_rows(p);
  for (int i = 0; i < n; i++) {
    p->names[i] = xstrdup(names[i] ? names[i] : "");
    for (int j = 0; j < nwas; j++) /* a staged change stays with its field */
      if (changes[j] && !strcmp(was[j], p->names[i])) {
        p->change[i] = changes[j];
        changes[j] = NULL;
      }
    field_row(p, new_row(p), i, labels[i] ? labels[i] : p->names[i], values[i] ? values[i] : "",
              p->form == FORM_DIRECT && notes ? notes[i] : NULL);
  }
  for (int j = 0; j < nwas; j++) {
    free(was[j]);
    free(changes[j]);
  }
  free(was);
  free(changes);
  panel_set_cursor(p, cur);
}

const char *panel_field(const struct panel *p, int i, const char **change) {
  if (i < 0 || i >= p->nfields) return NULL;
  if (change) *change = p->change[i];
  return p->names[i];
}

/* row i shown again, with the change it has now */
static void field_changed(struct panel *p, int i) {
  struct prow *r = &p->rows[i], was = *r;
  field_row(p, r, i, was.cells[0], was.ncells > 1 ? was.cells[1] : "",
            p->form == FORM_DIRECT && was.ncells > 2 ? was.cells[2] : NULL);
  for (int c = 0; c < was.ncells; c++) free(was.cells[c]);
  free(was.cells);
  tui_dirty(p->t);
}

static void form_typed(struct tui *t, const char *text, void *ud) {
  struct panel *p = ud;
  int i = p->editing;
  p->editing = -1;
  if (text && p->open && i >= 0 && i < p->nfields) {
    if (p->form == FORM_STAGED) {
      free(p->change[i]);
      p->change[i] = xstrdup(text);
      field_changed(p, i);
    } else if (p->event) {
      p->event(p, "edit", i, text, p->event_ud);
    }
  }
  panel_unref(p);
}

/* a form's action: 1 when it was the form's */
static int form_action(struct tui *t, struct panel *p, int a) {
  int i = p->nrows ? p->cur : -1, staged = p->form == FORM_STAGED;
  if (i < 0 || i >= p->nfields) return a == FA_EDIT;
  if (a == FA_EDIT) {
    const char *now = p->change[i] ? p->change[i] : p->rows[i].ncells > 1 ? p->rows[i].cells[1] : "";
    char *label = xasprintf("%s: ", p->rows[i].cells[0]);
    p->refs++; /* until the line is done with it */
    p->editing = i;
    tui_input(t, label, now, form_typed, p);
    free(label);
    return 1;
  }
  if (!staged) return 0;
  if (a == FA_DROP) {
    free(p->change[i]);
    p->change[i] = NULL;
    field_changed(p, i);
  } else if (a == FA_WRITE && p->event) {
    p->event(p, "write", i, NULL, p->event_ud);
  }
  return 1;
}

/* the actions a form's hint offers: drop and write only where they do something */
static int form_offers(int action, const void *ud) {
  return ((const struct panel *)ud)->form == FORM_STAGED || action == FA_EDIT;
}

int panel_key(struct tui *t, struct panel *p, uint32_t key) {
  int before = p->cur;
  int action = ctx_feed(KC_PANEL, &p->pending, key);
  if (action == CTX_PENDING) return 1; /* the first key of a pair such as gg */
  if (motion(p, action)) {
    moved(p, before);
    return 1;
  }
  if (action == PA_CLOSE || (action == PA_BACK && p->dialog)) {
    panel_close(p);
    return 1;
  }
  if (action == PA_BACK) {
    wm_focus_back(t);
    return 1;
  }
  if (p->form) {
    int a = ctx_feed(KC_FORM, &p->fpending, key);
    if (a == CTX_PENDING) return 1;
    if (a > 0 && form_action(t, p, a)) return 1;
  }
  /* a screen's own action, by its name: rebound with keymap.set(screen, ...) */
  if (p->place >= 0) {
    int a = ctx_feed(p->place, &p->ppending, key);
    if (a == CTX_PENDING) return 1;
    if (a > 0) {
      if (p->event) p->event(p, ctx_action_name(p->place, a), p->nrows ? p->cur : -1, NULL, p->event_ud);
      return 1;
    }
  }
  if (search_key(t, p, key)) return 1;
  switch (key) {
    /* these stay global, so the list and preview remain reachable */
    case NCKEY_TAB:
    case NCKEY_TAB | KEY_SHIFT:
    case ':':
    case KEY_CTRL | 'w':
      return 0;
  }
  /* so do Alt with anything (resizing) and the leader key, unless the script
   * has claimed the key */
  if ((key & KEY_ALT) || (t->km->leader && key == t->km->leader)) {
    int own = 0;
    for (int i = 0; i < p->nown; i++) own = own || p->own[i] == key;
    if (!own) return 0;
  }
  if (p->place >= 0) return 1; /* a screen's panel hears its actions, not its keys */
  if (p->event) {
    sbuf k = SBUF_INIT;
    key_format(&k, &key, 1);
    p->event(p, k.s, p->nrows ? p->cur : -1, NULL, p->event_ud);
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

/* Where the columns fall in a window: fixed widths first, the rest shared
 * by weight. Returns how many there are (at most 32). */
static int columns(const struct panel *p, struct rect r, int x[32], int w[32]) {
  int nc = p->ncols < 32 ? p->ncols : 32;
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
  return nc;
}

const char *panel_text_at(struct panel *p, struct rect r, int y, int x) {
  int row = p->top + (y - r.y - 2); /* below the bar and the column titles */
  if (y - r.y < 2 || row < 0 || row >= p->nrows) return NULL;
  const struct prow *pr = &p->rows[row];
  if (pr->style == PSTYLE_HEAD || pr->style == PSTYLE_NOTE) return pr->ncells ? pr->cells[0] : NULL;
  int cx[32], cw[32], nc = columns(p, r, cx, cw);
  for (int c = 0; c < nc && c < pr->ncells; c++)
    if (x >= cx[c] && x < cx[c] + cw[c]) return pr->cells[c];
  return NULL;
}

static void draw(struct tui *t, void *state, struct rect r, int focused) {
  struct panel *p = state;
  struct ncplane *n = t->std;

  /* title bar, with the key help on the right */
  dr_bar(n, r, focused);
  int used = dr_text(n, r.y, r.x + 1, r.w - 2, p->title);
  /* The tabs: the one being shown stands out from the bar, the others sit in
   * it. When they do not all fit, the strip starts as late as it must for the
   * one being shown to be on it, and says on which side there are more. */
  int tw[PANEL_TABS], from = 0, room = r.w - 2 - used - 4;
  for (int i = 0; i < p->ntabs; i++) {
    tw[i] = dr_width(p->tabs[i], strlen(p->tabs[i])) + 2;
    p->tab_w[i] = 0;
  }
  for (;;) {
    int need = 0;
    for (int i = from; i <= p->tab && i < p->ntabs; i++) need += tw[i] + 1;
    if (need <= room || from >= p->tab) break;
    from++;
  }
  if (from > 0) {
    dr_style(n, focused ? theme.on_accent : theme.dim, focused ? theme.accent : theme.bar_bg, 0);
    dr_text(n, r.y, r.x + 1 + used + 1, 1, "‹");
  }
  for (int i = from; i < p->ntabs; i++) {
    int tx = r.x + 1 + used + 2;
    if (used + 2 + tw[i] > r.w - 4) {
      dr_style(n, focused ? theme.on_accent : theme.dim, focused ? theme.accent : theme.bar_bg, 0);
      dr_text(n, r.y, tx, 1, "›");
      used += 1;
      break;
    }
    if (i == p->tab) dr_style(n, focused ? theme.bar_fg : theme.on_accent, focused ? theme.bar_bg : theme.accent, A_BOLD);
    else dr_style(n, focused ? theme.on_accent : theme.dim, focused ? theme.accent : theme.bar_bg, 0);
    dr_text(n, r.y, tx, 1, " ");
    dr_text(n, r.y, tx + 1, tw[i] - 2, p->tabs[i]);
    dr_text(n, r.y, tx + tw[i] - 1, 1, " ");
    p->tab_x[i] = tx - r.x;
    p->tab_w[i] = tw[i];
    used += tw[i] + 1;
  }
  if (p->ntabs) used += 2;
  /* the help: what the opener said, else the screen's hint, with the keys
   * its actions are on now */
  sbuf hint = SBUF_INIT;
  const char *help = p->help;
  if (!*help) { /* a form's hint, then its screen's */
    sbuf more = SBUF_INIT;
    if (p->form) ctx_hint_line_if(KC_FORM, &hint, form_offers, p);
    if (p->place >= 0 || !p->form) ctx_hint_line(p->place >= 0 ? p->place : KC_PANEL, &more);
    if (hint.len && more.len) sb_puts(&hint, "   ");
    if (more.len) sb_puts(&hint, more.s);
    sb_free(&more);
    if (hint.len) help = hint.s;
  }
  int hw = dr_width(help, strlen(help));
  if (hw && used + hw + 4 <= r.w) {
    dr_style(n, focused ? theme.on_accent : theme.dim, focused ? theme.accent : theme.bar_bg, 0);
    dr_text(n, r.y, r.x + r.w - hw - 1, hw, help);
  }
  sb_free(&hint);
  if (r.h < 3 || p->ncols == 0) return;

  int x[32], w[32], nc = columns(p, r, x, w);

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
    if (row_matches(p, p->top + i)) {
      dr_style(n, theme.accent, bg, A_BOLD);
      dr_text(n, y, r.x, 1, "›");
    }
    dr_style(n, style_color(row->style), bg, row->style == PSTYLE_HEAD ? A_BOLD : 0);
    if (row->style == PSTYLE_HEAD || row->style == PSTYLE_NOTE) { /* these span the row */
      dr_text(n, y, x[0], r.w - 2, row->ncells ? row->cells[0] : "");
      continue;
    }
    for (int c = 0; c < nc && c < row->ncells; c++) dr_text(n, y, x[c], w[c], row->cells[c]);
  }
}

/* a focused panel takes a key first, unless it is one it lets through to
 * a global binding */
static int key(struct tui *t, void *state, uint32_t k, const struct ncinput *ni) {
  return !panel_passes(state, k) && panel_key(t, state, k);
}

const struct view_class view_panel = {"panel", NULL, destroy, draw, NULL, key, 0};
