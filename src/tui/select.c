/* Selecting what is on the screen with the mouse.
 *
 * The text preview selects in its own text (view_preview.c), which knows
 * where lines were wrapped. Everywhere else (the list, panels, the status
 * line, the line being typed, the help overlay, the console) a drag selects
 * the characters as they are drawn: it is read back from the screen, so
 * what is copied is exactly what was highlighted. A double click takes the
 * word under the pointer and a triple click the row, or in a panel the whole
 * of the cell, including what its column cut off. What is selected is
 * copied at once; it stays highlighted until the next key or click. */
#include <stdlib.h>
#include <string.h>

#include "tui/tui.h"

/* What one screen cell holds, as UTF-8: " " for an empty one, NULL for the
 * second column of a wide character. Caller frees. */
static char *cell_text(struct ncplane *n, int y, int x) {
  nccell c = NCCELL_TRIVIAL_INITIALIZER;
  if (ncplane_at_yx_cell(n, y, x, &c) < 0) return xstrdup(" ");
  char *out = NULL;
  if (!nccell_wide_right_p(&c)) {
    const char *egc = nccell_extended_gcluster(n, &c);
    out = xstrdup(egc && (unsigned char)egc[0] >= 0x20 ? egc : " ");
  }
  nccell_release(n, &c);
  return out;
}

/* The selection in reading order, and the columns it covers on row y. */
static void ordered(const struct tui *t, int *ya, int *xa, int *yb, int *xb) {
  const int fwd = t->sel.y0 < t->sel.y1 || (t->sel.y0 == t->sel.y1 && t->sel.x0 <= t->sel.x1);
  *ya = fwd ? t->sel.y0 : t->sel.y1;
  *xa = fwd ? t->sel.x0 : t->sel.x1;
  *yb = fwd ? t->sel.y1 : t->sel.y0;
  *xb = fwd ? t->sel.x1 : t->sel.x0;
}

static int span(const struct tui *t, int y, int *from, int *to) {
  int ya, xa, yb, xb;
  ordered(t, &ya, &xa, &yb, &xb);
  const struct rect *c = &t->sel.clip;
  if (y < ya || y > yb) return 0;
  *from = y == ya ? xa : c->x;
  *to = y == yb ? xb : c->x + c->w - 1;
  return *from <= *to;
}

static void clamp(struct tui *t, int *y, int *x) {
  const struct rect *c = &t->sel.clip;
  if (*y < c->y) *y = c->y, *x = c->x;
  if (*y >= c->y + c->h) *y = c->y + c->h - 1, *x = c->x + c->w - 1;
  if (*x < c->x) *x = c->x;
  if (*x >= c->x + c->w) *x = c->x + c->w - 1;
}

/* The selected text: rows joined by line breaks, trailing blanks dropped. */
static void gather(struct tui *t, sbuf *out) {
  int ya, xa, yb, xb;
  ordered(t, &ya, &xa, &yb, &xb);
  for (int y = ya; y <= yb; y++) {
    int from, to;
    if (!span(t, y, &from, &to)) continue;
    size_t row_start = out->len;
    for (int x = from; x <= to; x++) {
      char *s = cell_text(t->std, y, x);
      if (s) sb_puts(out, s);
      free(s);
    }
    while (out->len > row_start && out->s[out->len - 1] == ' ') out->s[--out->len] = '\0';
    if (y < yb) sb_putc(out, '\n');
  }
}

static void copy(struct tui *t, const char *text, size_t len) {
  while (len && (text[len - 1] == ' ' || text[len - 1] == '\n')) len--;
  if (!len) return;
  int chars = dr_width(text, len);
  if (clip_copy(text, len))
    tui_msg(t, 0, "copied %d character%s   (<C-v> pastes into a field)", chars, chars == 1 ? "" : "s");
  else
    tui_msg(t, 1, "selected, but the terminal did not take the copy; <C-v> still pastes it inside lulibre");
}

static void finish(struct tui *t) {
  sbuf text = SBUF_INIT;
  gather(t, &text);
  if (text.len) copy(t, text.s, text.len);
  sb_free(&text);
  t->sel.on = t->sel.active = 0;
  t->sel.shown = 1;
  tui_dirty(t);
}

void sel_clear(struct tui *t) {
  if (t->sel.on || t->sel.active || t->sel.shown) tui_dirty(t);
  t->sel.on = t->sel.active = t->sel.shown = 0;
}

static int blank(const char *s) {
  return !s || !strcmp(s, " ") || !strcmp(s, "│");
}

void sel_press(struct tui *t, int y, int x, struct rect clip, struct node *nd) {
  double now = now_s();
  struct ncplane *n = t->std;
  t->sel.clicks = now - t->sel.click_at < 0.4 && y == t->sel.click_y && x == t->sel.click_x ? t->sel.clicks + 1 : 1;
  t->sel.click_at = now;
  t->sel.click_y = y;
  t->sel.click_x = x;
  t->sel.on = t->sel.active = t->sel.shown = 0;
  t->sel.clip = clip;
  if (clip.w <= 0 || clip.h <= 0 || y < clip.y || y >= clip.y + clip.h || x < clip.x || x >= clip.x + clip.w) return;
  t->sel.y0 = t->sel.y1 = y;
  t->sel.x0 = t->sel.x1 = x;

  if (t->sel.clicks == 2) { /* the word: what stands between blanks */
    int a = x, b = x;
    char *s = cell_text(n, y, x);
    int on_blank = blank(s);
    free(s);
    if (on_blank) return;
    for (; a > clip.x; a--) {
      s = cell_text(n, y, a - 1);
      int stop = s && blank(s);
      free(s);
      if (stop) break;
    }
    for (; b < clip.x + clip.w - 1; b++) {
      s = cell_text(n, y, b + 1);
      int stop = s && blank(s);
      free(s);
      if (stop) break;
    }
    t->sel.x0 = a;
    t->sel.x1 = b;
    finish(t);
    return;
  }
  if (t->sel.clicks >= 3) {
    /* in a panel, the cell in full, with what its column cut off */
    const char *cell = nd && nd->cls == &view_panel ? panel_text_at(nd->state, nd->r, y, x) : NULL;
    t->sel.x0 = clip.x;
    t->sel.x1 = clip.x + clip.w - 1;
    if (cell && *cell) {
      copy(t, cell, strlen(cell));
      t->sel.shown = 1;
      tui_dirty(t);
    } else {
      finish(t);
    }
    return;
  }
  t->sel.on = 1;
}

void sel_move(struct tui *t, int y, int x) {
  if (!t->sel.on) return;
  clamp(t, &y, &x);
  if (y != t->sel.y0 || x != t->sel.x0) t->sel.active = 1;
  t->sel.y1 = y;
  t->sel.x1 = x;
  tui_dirty(t);
}

void sel_release(struct tui *t, int y, int x) {
  if (!t->sel.on) return;
  sel_move(t, y, x);
  if (t->sel.active) finish(t);
  else t->sel.on = 0; /* a plain click selects nothing */
}

/* Called once the frame is drawn: show the selection over it. */
void sel_draw(struct tui *t) {
  if (!t->sel.active && !t->sel.shown) return;
  int ya, xa, yb, xb;
  ordered(t, &ya, &xa, &yb, &xb);
  dr_style(t->std, C_DEFAULT, theme.visual_bg, 0);
  for (int y = ya; y <= yb; y++) {
    int from, to;
    if (y < 0 || y >= t->rows_n || !span(t, y, &from, &to)) continue;
    for (int x = from; x <= to && x < t->cols_n; x++) {
      char *s = cell_text(t->std, y, x);
      if (s) ncplane_putegc_yx(t->std, y, x, s, NULL);
      free(s);
    }
  }
}
