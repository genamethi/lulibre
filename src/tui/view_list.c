/* The book list. Only the rows on screen are read from the index. */
#include <stdlib.h>
#include <string.h>

#include "tui/tui.h"

struct lstate {
  sqlite3_stmt *st;
};

static int page_rows = 20;

int list_page_rows(struct tui *t) {
  (void)t;
  return page_rows;
}

static void *create(struct tui *t) {
  struct lstate *ls = xcalloc(1, sizeof *ls);
  sqlite3_prepare_v2(t->app->db.h,
                     "SELECT title, authors, year, tags,"
                     " (SELECT s.twin FROM staged s WHERE s.id = -books.id) FROM books WHERE id = ?",
                     -1, &ls->st, NULL);
  return ls;
}

static void destroy(struct tui *t, void *state) {
  struct lstate *ls = state;
  sqlite3_finalize(ls->st);
  free(ls);
}

static int clampi(int v, int lo, int hi) {
  return v < lo ? lo : v > hi ? hi : v;
}

static int unknown_author(const char *a) {
  return !a || !*a || !strcmp(a, "Unknown") || !strcmp(a, "()");
}

static void draw(struct tui *t, void *state, struct rect r, int focused) {
  struct lstate *ls = state;
  struct ncplane *n = t->std;
  struct rows *R = &t->rows;

  int body = r.h - 1;
  if (body < 1) body = 1;
  page_rows = body;
  if (R->cur < R->top) R->top = R->cur;
  if (R->cur >= R->top + body) R->top = R->cur - body + 1;
  if (R->top > R->n - body) R->top = R->n - body;
  if (R->top < 0) R->top = 0;

  /* columns: mark, authors, title, year, subject; the narrow ones drop out
   * first as the window shrinks */
  int wyear = r.w >= 60 ? 4 : 0;
  int wtags = r.w >= 72 ? clampi(r.w / 5, 14, 28) : 0;
  int wauth = clampi(r.w * 26 / 100, 8, 30);
  int wtitle = r.w - 2 - wauth - 1 - (wyear ? wyear + 1 : 0) - (wtags ? wtags + 1 : 0);
  if (wtitle < 4) wtitle = 4;
  int xauth = r.x + 2, xtitle = xauth + wauth + 1, xyear = xtitle + wtitle + 1;
  int xtags = xyear + (wyear ? wyear + 1 : 0);

  dr_bar(n, r, focused);
  dr_text(n, r.y, xauth, wauth, "Author");
  dr_text(n, r.y, xtitle, wtitle, "Title");
  if (wyear) dr_text(n, r.y, xyear, wyear, "Year");
  if (wtags) dr_text(n, r.y, xtags, wtags, "Subject");

  if (R->n == 0) {
    dr_style(n, theme.dim, C_DEFAULT, 0);
    dr_text(n, r.y + 1 + (body > 2), r.x + 2, r.w - 2,
            R->running ? "loading…"
            : R->source ? (R->filter && R->filter[0] ? "no staged file matches this filter"
                                                     : "nothing is waiting in the sync folder (gl: the library)")
                        : "no books match this filter");
    return;
  }

  int va = -1, vb = -1;
  if (t->mode == MODE_VISUAL && R->anchor >= 0) {
    va = R->anchor < R->cur ? R->anchor : R->cur;
    vb = R->anchor < R->cur ? R->cur : R->anchor;
  }

  for (int i = 0; i < body && R->top + i < R->n; i++) {
    int row = R->top + i, y = r.y + 1 + i;
    sqlite3_int64 id = R->ids[row];
    int bg = row == R->cur ? (focused ? theme.cursor_bg : theme.cursor_bg_blur)
           : (row >= va && row <= vb) ? theme.visual_bg : C_DEFAULT;
    dr_style(n, C_DEFAULT, bg, 0);
    if (bg != C_DEFAULT) dr_fill(n, y, r.x, r.w);

    if (rows_marked(t, id)) {
      dr_style(n, theme.mark, bg, A_BOLD);
      ncplane_putstr_yx(n, y, r.x, "●");
    }
    int hit = rows_hit(t, id);
    if (hit) {
      dr_style(n, theme.ok, bg, A_BOLD);
      ncplane_putstr_yx(n, y, r.x + 1, "›");
    }
    sqlite3_bind_int64(ls->st, 1, id);
    if (sqlite3_step(ls->st) == SQLITE_ROW) {
      const char *title = (const char *)sqlite3_column_text(ls->st, 0);
      const char *auth = (const char *)sqlite3_column_text(ls->st, 1);
      const char *tags = (const char *)sqlite3_column_text(ls->st, 3);
      if (unknown_author(auth)) {
        dr_style(n, theme.dim, bg, 0);
        dr_text(n, y, xauth, wauth, "—");
      } else {
        dr_style(n, C_DEFAULT, bg, 0);
        dr_text(n, y, xauth, wauth, auth);
      }
      int held = sqlite3_column_type(ls->st, 4) != SQLITE_NULL; /* staged, and the library has it */
      if (held && !hit) {
        dr_style(n, theme.dim, bg, 0);
        ncplane_putstr_yx(n, y, r.x + 1, "=");
      }
      dr_style(n, hit ? theme.ok : held ? theme.dim : row == R->cur ? theme.title : C_DEFAULT, bg,
               row == R->cur ? A_BOLD : 0);
      dr_text(n, y, xtitle, wtitle, title ? title : "");
      if (wyear && sqlite3_column_type(ls->st, 2) != SQLITE_NULL) {
        dr_style(n, theme.dim, bg, 0);
        dr_text(n, y, xyear, wyear, (const char *)sqlite3_column_text(ls->st, 2));
      }
      if (wtags && tags) {
        dr_style(n, theme.accent, bg, 0);
        dr_text(n, y, xtags, wtags, tags);
      }
    }
    sqlite3_reset(ls->st);
  }
}

const struct view_class view_list = {"list", create, destroy, draw, NULL};
