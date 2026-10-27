/* Drawing the screen: the windows, the status line, the bottom line, the
 * overlays and the bar of tabs. */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "core/log.h"
#include "lua/sched.h"
#include "tui/tui.h"

/* ---------------------------------------------------------------- render */

void tui_badge(struct tui *t, const char *name, const char *text, int color) {
  int i = 0;
  while (i < t->nbadges && strcmp(t->badges[i].name, name)) i++;
  if (i < t->nbadges) {
    free(t->badges[i].text);
    if (!text || !*text) { /* taken away: the later ones move up */
      free(t->badges[i].name);
      memmove(&t->badges[i], &t->badges[i + 1], (size_t)(t->nbadges - i - 1) * sizeof t->badges[0]);
      t->nbadges--;
    } else {
      t->badges[i].text = xstrdup(text);
      t->badges[i].color = color;
    }
  } else if (text && *text && t->nbadges < TUI_BADGES) {
    t->badges[i].name = xstrdup(name);
    t->badges[i].text = xstrdup(text);
    t->badges[i].color = color;
    t->nbadges++;
  }
  tui_dirty(t);
}

static void draw_status(struct tui *t, int y) {
  struct ncplane *n = t->std;
  struct rows *r = &t->rows;
  int W = t->cols_n;
  dr_style(n, C_DEFAULT, theme.bar_bg, 0);
  dr_fill(n, y, 0, W);

  const char *mode = t->mode == MODE_VISUAL ? " SELECT " : t->mode == MODE_PROMPT ? " TYPE "
                   : t->mode == MODE_PICKER ? " FIND " : " NORMAL ";
  dr_style(n, theme.on_accent, t->mode == MODE_VISUAL ? theme.warn : theme.accent, A_BOLD);
  int x = dr_text(n, y, 0, W, mode);
  if (r->source) { /* the list is showing the sync folder, not the library */
    dr_style(n, theme.on_accent, theme.ok, A_BOLD);
    x += dr_text(n, y, x, W - x, " SYNC ");
  }
  for (int i = 0; i < t->nbadges && x < W / 2; i++) { /* what scripts say is going on */
    dr_style(n, theme.on_accent, t->badges[i].color, A_BOLD);
    x += dr_text(n, y, x, 1, " ");
    x += dr_text(n, y, x, W / 2 - x, t->badges[i].text);
    x += dr_text(n, y, x, 1, " ");
  }

  /* right side first, so the filter gets whatever is left */
  sbuf right = SBUF_INIT;
  if (sched_live(t->app)) sb_printf(&right, "%d task%s   ", sched_live(t->app),
                                    sched_live(t->app) == 1 ? "" : "s");
  if (t->progress) sb_printf(&right, "%s   ", t->progress);
  uint64_t unseen = log_errors() - t->errors_seen;
  if (unseen) sb_printf(&right, "%llu error%s (%s)   ", (unsigned long long)unseen, unseen == 1 ? "" : "s",
                        key_hint("console"));
  if (t->ix) sb_printf(&right, "indexing %d/%d   ", t->ix_done, t->ix_total);
  if (r->search) sb_printf(&right, "/%s: %d   ", r->search, r->nhits);
  if (r->nmarks) sb_printf(&right, "%d marked   ", r->nmarks);
  if (r->n) sb_printf(&right, "%d/%d", r->cur + 1, r->n);
  else sb_puts(&right, "0");
  if (r->running) sb_puts(&right, " …");
  else sb_printf(&right, "  %.0f ms", r->took * 1000);
  sb_putc(&right, ' ');
  int rw = dr_width(right.s, right.len);
  if (rw < W - x) {
    dr_style(n, theme.dim, theme.bar_bg, 0);
    dr_text(n, y, W - rw, rw, right.s);
  } else {
    rw = 0;
  }
  sb_free(&right);

  int avail = W - x - rw - 2;
  if (r->error || r->search_error) {
    dr_style(n, theme.error, theme.bar_bg, 0);
    dr_text(n, y, x + 1, avail, r->error ? r->error : r->search_error);
  } else if (r->filter && r->filter[0]) {
    /* a narrowed list says so, and how to get everything back */
    int end = x + 1 + avail, fx = x + 1;
    dr_style(n, theme.warn, theme.bar_bg, A_BOLD);
    fx += dr_text(n, y, fx, end - fx, "filter ");
    dr_style(n, C_DEFAULT, theme.bar_bg, A_BOLD);
    fx += dr_text(n, y, fx, end - fx, r->filter);
    char *hint = xasprintf("   %d of %d   %s shows all", r->nall, r->total, key_hint("filter"));
    if (!r->running && fx + dr_width(hint, strlen(hint)) <= end) {
      dr_style(n, theme.dim, theme.bar_bg, 0);
      dr_text(n, y, fx, end - fx, hint);
    }
    free(hint);
  } else {
    dr_style(n, theme.dim, theme.bar_bg, 0);
    char *what = r->group && !r->source ? xasprintf("all books, by %s", r->group) : NULL;
    dr_text(n, y, x + 1, avail, r->source ? "every file in the sync folder" : what ? what : "all books");
    free(what);
  }
}

/* The bottom line, and the lines above it that a long question or message
 * takes. A question wraps so that its end (the choices: "[y/N]") is never
 * cut, and what is typed follows it, on a line of its own when the question
 * leaves less than a third of the width. */
#define BOTTOM_MAX 64
struct bottom {
  const char *s;  /* the question or the message, NULL for none */
  int n;          /* its lines, which may be more than are shown */
  int alone;      /* what is typed goes on a line of its own */
  int h;          /* the lines given to the bottom */
  size_t off[BOTTOM_MAX], len[BOTTOM_MAX];
};

static void bottom_wrap(struct tui *t, struct bottom *b) {
  int W = t->cols_n;
  b->s = NULL;
  b->n = b->alone = 0;
  if (t->mode == MODE_PROMPT) {
    b->s = t->prompt == PROMPT_FILTER ? "&" : t->prompt == PROMPT_SEARCH ? "/"
         : t->prompt == PROMPT_INPUT && t->input_label ? t->input_label : ":";
    b->n = dr_lines(b->s, W - 1, b->off, b->len, BOTTOM_MAX);
    int last = b->n <= BOTTOM_MAX ? b->n - 1 : BOTTOM_MAX - 1;
    b->alone = W - dr_width(b->s + b->off[last], b->len[last]) < W / 3;
  } else if (t->msg && *t->msg) {
    b->s = t->msg;
    b->n = dr_lines(b->s, W - 12, b->off, b->len, BOTTOM_MAX);
  }
  int cap = t->rows_n / 3;
  if (cap > BOTTOM_MAX) cap = BOTTOM_MAX;
  b->h = b->n + b->alone;
  if (b->h > cap) b->h = cap;
  if (b->h < 1) b->h = 1;
}

static void draw_bottom(struct tui *t, int y, const struct bottom *b) {
  struct ncplane *n = t->std;
  int W = t->cols_n;
  if (t->mode == MODE_PROMPT) {
    /* the question's last lines, which hold the choices, when not all fit */
    int rows = b->h - b->alone, have = b->n < BOTTOM_MAX ? b->n : BOTTOM_MAX;
    int first = b->n <= BOTTOM_MAX && have > rows ? have - rows : 0, lw = 0;
    if (rows < 1) rows = 1;
    dr_style(n, theme.accent, C_DEFAULT, A_BOLD);
    for (int i = 0; i < rows && first + i < have; i++) {
      int x = i == 0 && first > 0 ? dr_text(n, y + i, 0, W, "… ") : 0;
      lw = x + dr_textn(n, y + i, x, W - x, b->s + b->off[first + i], b->len[first + i]);
    }
    int yi = y + b->h - 1;
    if (b->alone) lw = 0;
    const char *text = t->line.text.s ? t->line.text.s : "";
    dr_style(n, C_DEFAULT, C_DEFAULT, 0);
    /* keep the cursor in view on a long line */
    int cur = dr_width(text, t->line.cur);
    size_t skip = 0;
    while (cur - dr_width(text, skip) > W - lw - 2 && skip < t->line.cur) skip++;
    while (skip < t->line.text.len && ((unsigned char)text[skip] & 0xc0) == 0x80) skip++;
    dr_text(n, yi, lw, W - lw, text + skip);
    if (t->nsugg_match) draw_suggestions(t, y, b->alone ? 0 : lw);
    notcurses_cursor_enable(t->nc, yi, lw + cur - dr_width(text, skip));
    return;
  }
  if (b->s) {
    dr_style(n, t->msg_error ? theme.error : C_DEFAULT, C_DEFAULT, 0);
    for (int i = 0; i < b->h && i < BOTTOM_MAX; i++) {
      int w = dr_textn(n, y + i, 0, W - 12, b->s + b->off[i], b->len[i]);
      /* more than fits: the rest is in the console */
      if (i == b->h - 1 && b->n > b->h) dr_text(n, y + i, w < W - 13 ? w + 1 : W - 13, 1, "…");
    }
  }
  if (t->km->npending) {
    sbuf k = SBUF_INIT;
    key_format(&k, t->km->pending, t->km->npending);
    dr_style(n, theme.dim, C_DEFAULT, 0);
    dr_text(n, y + b->h - 1, W - 11, 10, k.s);
    sb_free(&k);
  }
}

/* The pager (help, lulibre.show): each line wraps at the box's width, and
 * what wraps lines up under the line's own indent. Calls fn for every line
 * as shown and returns how many there are. */
typedef void pager_line_fn(struct tui *t, int i, int indent, const char *s, size_t len, int heading, void *ud);

static int pager_lines(struct tui *t, int w, pager_line_fn *fn, void *ud) {
  int n = 0;
  for (const char *p = t->help; *p;) {
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

static void pager_draw_line(struct tui *t, int i, int indent, const char *s, size_t len, int heading, void *ud) {
  struct pager_draw *d = ud;
  int r = i - d->from + 1; /* the box's first row is its title */
  if (r < 1 || r >= d->h - 1) return;
  dr_style(t->std, heading ? theme.accent : C_DEFAULT, theme.bar_bg, heading ? A_BOLD : 0);
  dr_textn(t->std, d->y + r, d->x + indent, 1 << 30, s, len);
}

static void draw_help(struct tui *t) {
  struct ncplane *n = t->std;
  int W = t->cols_n, H = t->rows_n;
  int w = W > 84 ? 80 : W - 2, h = H - 4;
  if (w < 20 || h < 4) return;
  int x = (W - w) / 2, y = 1;
  int total = pager_lines(t, w - 4, NULL, NULL);
  if (t->help_scroll > total - h + 2) t->help_scroll = total - h + 2;
  if (t->help_scroll < 0) t->help_scroll = 0;

  for (int r = 0; r < h; r++) {
    dr_style(n, C_DEFAULT, theme.bar_bg, 0);
    dr_fill(n, y + r, x, w);
  }
  if (t->pager_title) {
    dr_style(n, theme.dim, theme.bar_bg, 0);
    dr_text(n, y, x + 2, w - 4, t->pager_title);
  }
  struct pager_draw d = {x + 2, y, h, t->help_scroll};
  pager_lines(t, w - 4, pager_draw_line, &d);
}

/* ---- the bar's tabs: which of the library and the sync folder the list
 * is showing, and the configuration window, which takes the list's place
 * while it is open. The sync folder's tab is there once one is set. */

static int count_books(struct tui *t, const char *where) {
  sqlite3_stmt *st;
  int n = 0;
  char sql[96];
  snprintf(sql, sizeof sql, "SELECT count(*) FROM books WHERE %s", where);
  if (sqlite3_prepare_v2(t->app->db.h, sql, -1, &st, NULL) != SQLITE_OK) return 0;
  if (sqlite3_step(st) == SQLITE_ROW) n = sqlite3_column_int(st, 0);
  sqlite3_finalize(st);
  return n;
}

/* The command a click on tab i runs. */
const char *tab_command(const struct tui *t, int i) {
  int sync = app_str(t->app, S_SYNC_DIR)[0] != '\0';
  if (i == 0) return "source library";
  if (i == 1 && sync) return "sync";
  return "source config";
}

static void draw_tabs(struct tui *t) {
  struct ncplane *n = t->std;
  dr_style(n, theme.dim, theme.bar_bg, 0);
  dr_fill(n, 0, 0, t->cols_n);
  int sync = app_str(t->app, S_SYNC_DIR)[0] != '\0';
  char label[3][96];
  int on[3], bg[3], k = 0;
  snprintf(label[k], sizeof label[k], " 1  Library  %d ", count_books(t, "id > 0"));
  on[k] = !t->screen_tab && t->rows.source == 0, bg[k++] = theme.accent;
  if (sync) {
    snprintf(label[k], sizeof label[k], " 2  Sync folder  %d ", count_books(t, "id < 0"));
    on[k] = !t->screen_tab && t->rows.source == 1, bg[k++] = theme.ok;
  }
  snprintf(label[k], sizeof label[k], " 3  Configuration ");
  on[k] = t->screen_tab != NULL, bg[k++] = theme.accent;
  t->tab_n = k;
  int x = 0;
  for (int i = 0; i < k; i++) {
    dr_style(n, on[i] ? theme.on_accent : theme.bar_fg, on[i] ? bg[i] : theme.bar_bg, on[i] ? A_BOLD : 0);
    t->tab_x[i] = x;
    x += dr_text(n, 0, x, t->cols_n - x, label[i]);
    t->tab_x[i + 1] = x;
    dr_style(n, theme.border, theme.bar_bg, 0);
    if (i + 1 < k) x += dr_text(n, 0, x, t->cols_n - x, "│");
  }
  char hint[200];
  if (t->screen_tab)
    snprintf(hint, sizeof hint, "%s back to the library", key_hint("source library"));
  else if (t->rows.source)
    snprintf(hint, sizeof hint, "%s add   %s add and remove   %s drop   %s library", key_hint("sync add"),
             key_hint("sync move"), key_hint("sync drop"), key_hint("source library"));
  else if (sync)
    snprintf(hint, sizeof hint, "%s shows what is waiting in the sync folder", key_hint("sync"));
  else
    hint[0] = '\0';
  int hw = dr_width(hint, strlen(hint));
  if (hw && x + hw + 3 < t->cols_n) {
    dr_style(n, theme.dim, theme.bar_bg, 0);
    dr_text(n, 0, t->cols_n - hw - 1, hw, hint);
  }
}

static void render(struct tui *t) {
  unsigned rows, cols;
  ncplane_dim_yx(t->std, &rows, &cols);
  t->rows_n = (int)rows;
  t->cols_n = (int)cols;
  ncplane_erase(t->std);
  notcurses_cursor_disable(t->nc);
  keymap_set_leader(t->km, app_str(t->app, S_LEADER));
  wm_note_focus(t);
  /* the panel that was looking has lost the cursor to the list, which says
   * again what the preview shows (in the preview itself, to page or copy
   * from it, the cursor keeps what it was showing) */
  if ((t->peek || t->preview_note) && t->focus->cls == &view_list) {
    t->peek = 0;
    free(t->preview_note);
    t->preview_note = NULL;
    preview_book_changed(t);
  }
  if (t->rows_n >= 4 && t->cols_n >= 20) {
    int top = 1; /* the bar of tabs */
    struct bottom b;
    bottom_wrap(t, &b);
    wm_layout(t, (struct rect){top, 0, t->rows_n - 1 - b.h - top, t->cols_n});
    wm_draw(t);
    if (top) draw_tabs(t);
    draw_status(t, t->rows_n - 1 - b.h);
    draw_bottom(t, t->rows_n - b.h, &b);
    if (t->help) draw_help(t);
    if (t->picker) picker_draw(t);
    sel_draw(t);
  }
  dr_style(t->std, C_DEFAULT, C_DEFAULT, 0);
  notcurses_render(t->nc);
}

void render_prepare_cb(uv_prepare_t *h) {
  struct tui *t = h->data;
  if (t->dirty && !t->quit) {
    t->dirty = 0;
    render(t);
  }
}
