#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>

#include "core/log.h"
#include "lua/bridge.h"
#include "lua/sched.h"
#include "match/fold.h"
#include "match/fuzzy.h"
#include "tui/tui.h"

void tui_dirty(struct tui *t) {
  t->dirty = 1;
}

void tui_show_msg(struct tui *t, int error, const char *text) {
  free(t->msg);
  t->msg = xstrdup(text ? text : "");
  t->msg_error = error;
  tui_dirty(t);
}

void tui_msg(struct tui *t, int error, const char *fmt, ...) {
  va_list ap;
  char *s;
  va_start(ap, fmt);
  if (vasprintf(&s, fmt, ap) < 0) s = NULL;
  va_end(ap);
  log_text(error ? LOG_ERROR : LOG_INFO, s ? s : "");
  tui_show_msg(t, error, s);
  free(s);
}

void tui_pager(struct tui *t, const char *title, const char *text) {
  free(t->help);
  free(t->pager_title);
  t->help = xstrdup(text ? text : "");
  t->pager_title = xstrdup(title ? title : "");
  t->help_scroll = 0;
  tui_dirty(t);
}

void tui_progress(struct tui *t, const char *text) {
  free(t->progress);
  t->progress = text && *text ? xstrdup(text) : NULL;
  tui_dirty(t);
}

void tui_reload(struct tui *t) {
  char *err = NULL;
  /* while the indexer holds a transaction the periodic check picks this up */
  if (!t->ix && db_mirror(&t->app->db, t->app->cfg.library, 0, &err) < 0) {
    tui_msg(t, 1, "%s", err);
    free(err);
  }
  rows_reload(t);
}

/* ----------------------------------------------------------- suggestions */

static void suggest_clear(struct tui *t) {
  for (int i = 0; i < t->nsugg; i++) {
    free(t->sugg[i].text);
    free(t->sugg[i].folded);
    free(t->sugg[i].detail);
  }
  free(t->sugg);
  free(t->sugg_order);
  free(t->sugg_sep);
  t->sugg = NULL;
  t->sugg_order = NULL;
  t->sugg_sep = NULL;
  t->nsugg = t->nsugg_match = t->sugg_sel = 0;
}

/* Where the item being typed starts: after the last separator. */
static size_t segment_start(const struct tui *t) {
  const char *text = t->line.text.s ? t->line.text.s : "";
  size_t start = 0;
  if (t->sugg_sep && *t->sugg_sep) {
    /* accept the separator with or without its surrounding spaces */
    sbuf core = SBUF_INIT;
    for (const char *c = t->sugg_sep; *c; c++)
      if (*c != ' ') sb_putc(&core, *c);
    if (core.len) {
      for (const char *q = text; (q = strstr(q, core.s)); q += core.len)
        start = (size_t)(q - text) + core.len;
    } else if (strrchr(text, ' ')) { /* separated by spaces alone: the last word */
      start = (size_t)(strrchr(text, ' ') - text) + 1;
    }
    sb_free(&core);
  }
  while (text[start] == ' ') start++;
  return start;
}

static int by_sugg_score(const void *a, const void *b, void *arg) {
  const double *sugg_scores = arg;
  int ia = *(const int *)a, ib = *(const int *)b;
  if (sugg_scores[ia] != sugg_scores[ib]) return sugg_scores[ia] < sugg_scores[ib] ? 1 : -1;
  return ia - ib; /* ties keep the order given, which is already a ranking */
}

static void suggest_rematch(struct tui *t) {
  t->nsugg_match = t->sugg_sel = 0;
  if (!t->nsugg) return;
  const char *seg = (t->line.text.s ? t->line.text.s : "") + segment_start(t);
  sbuf q = SBUF_INIT;
  fold_utf8(&q, seg, strlen(seg));
  double *scores = xcalloc((size_t)t->nsugg, sizeof *scores);
  int empty = q.len == 0;
  for (int i = 0; i < t->nsugg; i++) {
    if (t->sugg_prefix) { /* completion: by prefix, in the order given, and not before a letter is typed */
      if ((empty && t->sugg_prefix != 2) || strncmp(t->sugg[i].folded, q.s, q.len) || !t->sugg[i].folded[q.len])
        continue;
      t->sugg_order[t->nsugg_match++] = i;
      continue;
    }
    scores[i] = empty ? 0 : fuzzy_score(q.s, t->sugg[i].folded);
    if (scores[i] <= FUZZY_NONE / 2) continue;
    if (!empty && !strcmp(q.s, t->sugg[i].folded) && t->nsugg > 1) continue; /* already typed */
    t->sugg_order[t->nsugg_match++] = i;
  }
  if (!empty && !t->sugg_prefix) {
    qsort_r(t->sugg_order, (size_t)t->nsugg_match, sizeof *t->sugg_order, by_sugg_score, scores);
  }
  free(scores);
  sb_free(&q);
}

void tui_input_suggest(struct tui *t, int n, const char *const *texts,
                       const char *const *details, const char *sep) {
  suggest_clear(t);
  if (n <= 0) return;
  t->sugg = xcalloc((size_t)n, sizeof *t->sugg);
  t->sugg_order = xcalloc((size_t)n, sizeof *t->sugg_order);
  for (int i = 0; i < n; i++) {
    sbuf f = SBUF_INIT;
    fold_utf8(&f, texts[i], strlen(texts[i]));
    t->sugg[i].text = xstrdup(texts[i]);
    t->sugg[i].folded = sb_take(&f);
    t->sugg[i].detail = details && details[i] ? xstrdup(details[i]) : NULL;
  }
  t->nsugg = n;
  t->sugg_sep = sep && *sep ? xstrdup(sep) : NULL;
  suggest_rematch(t);
  tui_dirty(t);
}

void tui_input_on_change(struct tui *t, input_fn *fn) {
  t->input_change = fn;
}

static void suggest_accept(struct tui *t) {
  if (t->sugg_sel >= t->nsugg_match) return;
  const char *pick = t->sugg[t->sugg_order[t->sugg_sel]].text;
  size_t start = segment_start(t);
  char *prefix = xstrndup(t->line.text.s ? t->line.text.s : "", start);
  char *whole = xasprintf("%s%s", prefix, pick);
  le_set(&t->line, whole);
  free(prefix);
  free(whole);
  suggest_rematch(t);
}

#define SUGGEST_ROWS 8

static void draw_suggestions(struct tui *t, int bottom_y, int x) {
  struct ncplane *n = t->std;
  int rows = t->nsugg_match < SUGGEST_ROWS ? t->nsugg_match : SUGGEST_ROWS;
  if (rows <= 0 || bottom_y - rows < 0) return;
  int w = 0;
  int first = t->sugg_sel >= rows ? t->sugg_sel - rows + 1 : 0;
  for (int i = 0; i < rows; i++) {
    const struct suggestion *s = &t->sugg[t->sugg_order[first + i]];
    int cw = dr_width(s->text, strlen(s->text)) + (s->detail ? dr_width(s->detail, strlen(s->detail)) + 3 : 0);
    if (cw > w) w = cw;
  }
  w += 2;
  if (w < 14) w = 14;
  if (w > t->cols_n - x) w = t->cols_n - x;
  if (w < 12) return;
  for (int i = 0; i < rows; i++) {
    const struct suggestion *s = &t->sugg[t->sugg_order[first + i]];
    int y = bottom_y - rows + i, selected = first + i == t->sugg_sel;
    int bg = selected ? theme.cursor_bg : theme.bar_bg;
    dr_style(n, C_DEFAULT, bg, selected ? A_BOLD : 0);
    dr_fill(n, y, x, w);
    int dw = s->detail ? dr_width(s->detail, strlen(s->detail)) : 0;
    if (dw > w / 2) dw = w / 2;
    dr_text(n, y, x + 1, w - 2 - (dw ? dw + 2 : 0), s->text);
    if (dw) {
      dr_style(n, theme.dim, bg, 0);
      dr_text(n, y, x + w - 1 - dw, dw, s->detail);
    }
  }
}

/* ---------------------------------------------------------------- prompt */

void tui_input(struct tui *t, const char *label, const char *initial, input_fn *cb, void *ud) {
  if (t->prompt == PROMPT_INPUT) tui_input_cancel(t); /* one question at a time */
  tui_prompt(t, PROMPT_INPUT, initial);
  suggest_clear(t);
  t->sugg_prefix = 0;
  t->input_change = NULL;
  free(t->input_label);
  t->input_label = xstrdup(label && *label ? label : "> ");
  t->input_cb = cb;
  t->input_ud = ud;
}

/* ---- history: one per kind of line, kept between sessions ---- */

static const char *const hist_key[3] = {"history:command", "history:filter", "history:search"};

static int hist_of(enum prompt_kind kind) {
  return kind == PROMPT_COMMAND ? 0 : kind == PROMPT_FILTER ? 1 : kind == PROMPT_SEARCH ? 2 : -1;
}

static void history_save(struct tui *t, int k) {
  sbuf all = SBUF_INIT;
  for (int i = 0; i < t->hist[k].n; i++) sb_printf(&all, "%s\n", t->hist[k].v[i]);
  sqlite3_stmt *st;
  if (sqlite3_prepare_v2(t->app->db.h, "INSERT OR REPLACE INTO kv(key, value) VALUES(?, ?)", -1, &st, NULL) ==
      SQLITE_OK) {
    sqlite3_bind_text(st, 1, hist_key[k], -1, SQLITE_STATIC);
    sqlite3_bind_text(st, 2, all.s ? all.s : "", -1, SQLITE_STATIC);
    sqlite3_step(st);
    sqlite3_finalize(st);
  }
  sb_free(&all);
}

static void history_load(struct tui *t) {
  sqlite3_stmt *st;
  for (int k = 0; k < 3; k++) {
    if (sqlite3_prepare_v2(t->app->db.h, "SELECT value FROM kv WHERE key = ?", -1, &st, NULL) != SQLITE_OK) return;
    sqlite3_bind_text(st, 1, hist_key[k], -1, SQLITE_STATIC);
    const char *all = sqlite3_step(st) == SQLITE_ROW ? (const char *)sqlite3_column_text(st, 0) : NULL;
    for (const char *p = all; p && *p;) {
      size_t len = strcspn(p, "\n");
      if (len) {
        t->hist[k].v = xrealloc(t->hist[k].v, ((size_t)t->hist[k].n + 1) * sizeof(char *));
        t->hist[k].v[t->hist[k].n++] = xstrndup(p, len);
      }
      p += len + (p[len] == '\n');
    }
    sqlite3_finalize(st);
  }
}

static void history_add(struct tui *t, enum prompt_kind kind, const char *line) {
  int k = hist_of(kind);
  if (k < 0 || !*line || strchr(line, '\n')) return;
  /* an entry used again moves to the end instead of appearing twice */
  for (int i = 0; i < t->hist[k].n; i++)
    if (!strcmp(t->hist[k].v[i], line)) {
      free(t->hist[k].v[i]);
      memmove(&t->hist[k].v[i], &t->hist[k].v[i + 1], (size_t)(t->hist[k].n - i - 1) * sizeof(char *));
      t->hist[k].n--;
      break;
    }
  if (t->hist[k].n >= 300) {
    free(t->hist[k].v[0]);
    memmove(&t->hist[k].v[0], &t->hist[k].v[1], (size_t)(t->hist[k].n - 1) * sizeof(char *));
    t->hist[k].n--;
  }
  t->hist[k].v = xrealloc(t->hist[k].v, ((size_t)t->hist[k].n + 1) * sizeof(char *));
  t->hist[k].v[t->hist[k].n++] = xstrdup(line);
  history_save(t, k);
}

/* Up and Down: the nearest entry, older or newer, that starts with what was
 * typed before the first of them was pressed. */
static void history_step(struct tui *t, int dir) {
  int k = hist_of(t->prompt);
  if (k < 0 || !t->hist[k].n) return;
  if (!t->hist_prefix) t->hist_prefix = xstrdup(t->line.text.s ? t->line.text.s : "");
  size_t plen = strlen(t->hist_prefix);
  for (int i = t->hist_pos + dir; i >= 0 && i <= t->hist[k].n; i += dir) {
    if (i == t->hist[k].n) { /* past the newest: back to what was typed */
      t->hist_pos = i;
      le_set(&t->line, t->hist_prefix);
      return;
    }
    if (!strncmp(t->hist[k].v[i], t->hist_prefix, plen)) {
      t->hist_pos = i;
      le_set(&t->line, t->hist[k].v[i]);
      return;
    }
  }
}

void tui_prompt(struct tui *t, enum prompt_kind kind, const char *initial) {
  /* a question still open is answered "cancelled" before the line is reused,
   * or whoever asked it would wait for ever */
  if (t->prompt == PROMPT_INPUT && kind != PROMPT_INPUT) tui_input_cancel(t);
  t->prompt = kind;
  t->mode = MODE_PROMPT;
  le_set(&t->line, initial ? initial : "");
  free(t->prompt_saved);
  t->prompt_saved = kind == PROMPT_FILTER ? xstrdup(t->rows.filter ? t->rows.filter : "") : NULL;
  suggest_clear(t);
  free(t->comp_ctx);
  t->comp_ctx = NULL;
  free(t->hist_prefix);
  t->hist_prefix = NULL;
  t->hist_pos = hist_of(kind) >= 0 ? t->hist[hist_of(kind)].n : 0;
  complete_refresh(t);
  free(t->msg);
  t->msg = NULL;
  if (kind == PROMPT_SEARCH) rows_search_begin(t);
  tui_dirty(t);
}

static void prompt_close(struct tui *t) {
  t->prompt = PROMPT_NONE;
  t->mode = MODE_NORMAL;
  uv_timer_stop(&t->ftimer);
  notcurses_cursor_disable(t->nc);
  tui_dirty(t);
}

static void input_done(struct tui *t, const char *text) {
  input_fn *cb = t->input_cb;
  void *ud = t->input_ud;
  t->input_cb = NULL;
  t->input_change = NULL;
  suggest_clear(t);
  prompt_close(t);
  if (cb) cb(t, text, ud);
}

void tui_input_cancel(struct tui *t) {
  if (t->prompt == PROMPT_INPUT) input_done(t, NULL);
}

void tui_prompt_cancel(struct tui *t) {
  if (t->mode != MODE_PROMPT) return;
  if (t->prompt == PROMPT_FILTER && t->prompt_saved) rows_set_filter(t, t->prompt_saved);
  if (t->prompt == PROMPT_SEARCH) rows_search_end(t, "", 0);
  if (t->prompt == PROMPT_INPUT) input_done(t, NULL);
  else prompt_close(t);
}

static void filter_timer_cb(uv_timer_t *h) {
  struct tui *t = h->data;
  const char *text = t->line.text.s ? t->line.text.s : "";
  if (t->prompt == PROMPT_FILTER) rows_set_filter(t, text);
  else if (t->prompt == PROMPT_SEARCH) rows_search(t, text);
}

static void prompt_changed(struct tui *t);
static void prompt_paste(struct tui *t);

static void prompt_key(struct tui *t, uint32_t key, const struct ncinput *ni) {
  const char *text = t->line.text.s ? t->line.text.s : "";
  int action = ctx_feed(KC_LINE, NULL, key);
  switch (action) {
    case LA_ACCEPT: {
      char *line = xstrdup(text);
      enum prompt_kind kind = t->prompt;
      if (kind == PROMPT_INPUT) {
        input_done(t, line);
        free(line);
        return;
      }
      prompt_close(t);
      history_add(t, kind, line);
      if (kind == PROMPT_COMMAND) {
        tui_exec(t, line);
      } else if (kind == PROMPT_SEARCH) {
        rows_search_end(t, line, *line != '\0');
      } else {
        rows_set_filter(t, line);
      }
      free(line);
      return;
    }
    case LA_PASTE: /* what was last copied, as one line */
      prompt_paste(t);
      return;
    case LA_COPY: /* the line as it stands */
      if (*text && clip_copy(text, strlen(text))) tui_show_msg(t, 0, "copied the line");
      return;
    case LA_PREVIEW_UP: /* the preview stays readable while a field is typed */
      preview_scroll(t, -8);
      return;
    case LA_PREVIEW_DOWN:
      preview_scroll(t, 8);
      return;
    case LA_CANCEL:
      tui_prompt_cancel(t);
      return;
    case LA_COMPLETE:
      if (t->nsugg_match) {
        suggest_accept(t);
        prompt_changed(t);
      }
      return;
    case LA_NEXT:
    case LA_PREV:
    case LA_UP:
    case LA_DOWN: {
      /* in a field up and down walk the suggestions; at a command line they
       * walk the history, and next and prev the completions */
      int stepping = action == LA_NEXT || action == LA_PREV;
      if (t->nsugg_match && (t->prompt == PROMPT_INPUT || stepping)) {
        int down = action == LA_DOWN || action == LA_NEXT;
        t->sugg_sel = (t->sugg_sel + (down ? 1 : t->nsugg_match - 1)) % t->nsugg_match;
        tui_dirty(t);
        return;
      }
      if (!stepping) {
        history_step(t, action == LA_UP ? -1 : 1);
        complete_refresh(t);
        suggest_rematch(t);
        tui_dirty(t);
      }
      return;
    }
    case LA_BACKSPACE:
      if (t->line.text.len == 0) {
        /* A field that has been emptied stays open: Enter then answers with
         * nothing, which is how a value is blanked. The other prompts are
         * left by backspacing out of them. */
        if (t->prompt == PROMPT_INPUT) return;
        if (t->prompt == PROMPT_FILTER) rows_set_filter(t, "");
        if (t->prompt == PROMPT_SEARCH) rows_search_end(t, "", 0);
        prompt_close(t);
        return;
      }
      break;
  }
  if (le_key(&t->line, key, ni)) prompt_changed(t);
}

/* the text being typed changed: filters and suggestions follow it */
static void prompt_changed(struct tui *t) {
  free(t->hist_prefix); /* typing ends a walk through the history */
  t->hist_prefix = NULL;
  if (t->prompt == PROMPT_FILTER || t->prompt == PROMPT_SEARCH)
    uv_timer_start(&t->ftimer, filter_timer_cb, 40, 0);
  if (t->prompt != PROMPT_INPUT) {
    complete_refresh(t);
    suggest_rematch(t);
  }
  if (t->prompt == PROMPT_INPUT) {
    suggest_rematch(t);
    if (t->input_change) t->input_change(t, t->line.text.s ? t->line.text.s : "", t->input_ud);
  }
  tui_dirty(t);
}

/* ----------------------------------------------------------------- input */

static void help_key(struct tui *t, uint32_t key) {
  switch (ctx_feed(KC_PAGER, NULL, key)) {
    case GA_DOWN: t->help_scroll++; break;
    case GA_UP: t->help_scroll--; break;
    case GA_PAGE_DOWN: t->help_scroll += 10; break;
    case GA_PAGE_UP: t->help_scroll -= 10; break;
    case GA_TOP: t->help_scroll = 0; break;
    default:
      free(t->help);
      t->help = NULL;
  }
  tui_dirty(t);
}

/* Insert what was last copied into the field being typed, as one line. */
static void prompt_insert_flat(struct tui *t, const char *text) {
  sbuf flat = SBUF_INIT;
  int gap = 0;
  for (const char *p = text; *p; p++) {
    if (*p == ' ' || *p == '\n' || *p == '\t' || *p == '\r' || *p == '\f') {
      gap = flat.len > 0;
    } else {
      if (gap) sb_putc(&flat, ' ');
      gap = 0;
      sb_putc(&flat, *p);
    }
  }
  if (flat.len) {
    le_insert(&t->line, flat.s, flat.len);
    prompt_changed(t);
  }
  sb_free(&flat);
}

static void prompt_paste(struct tui *t) {
  char *text = clip_paste();
  if (!text) {
    tui_msg(t, 0, "nothing has been copied yet");
    return;
  }
  prompt_insert_flat(t, text);
  free(text);
}

/* A click focuses the window under it and, in a list or panel, picks the row;
 * the wheel scrolls whatever it is over; a drag in a text preview selects
 * and copies. While a field is being typed the list and panels are left
 * alone, but the preview can still be scrolled and selected from, and the
 * middle or right button pastes. Overlays ignore the mouse. */
/* The line of the screen a position is on, as a rectangle: what a selection
 * begun outside any window (the status line, the line being typed) keeps to. */
static struct rect line_at(const struct tui *t, int y) {
  return (struct rect){y, 0, 1, t->cols_n};
}

/* The button has come up after a press in a preview: if nothing was
 * selected it was a plain click, and the cursor's window moves there. */
static void preview_click_done(struct tui *t) {
  void *pv = t->pv.state;
  t->pv.state = NULL;
  struct node *nd = pv ? wm_leaf_of(t, pv) : NULL;
  if (!nd || nd->cls != &view_preview || nd == t->focus) return;
  if (preview_has_selection(pv) || t->sel.shown) return;
  t->pv.back = t->focus->state;
  t->focus = nd;
  tui_dirty(t);
}

static const char *tab_command(const struct tui *t, int i);

static void on_mouse(struct tui *t, const struct ncinput *ni) {
  int release = ni->evtype == NCTYPE_RELEASE;
  int wheel = ni->id == NCKEY_SCROLL_UP ? -3 : ni->id == NCKEY_SCROLL_DOWN ? 3 : 0;
  int left = ni->id == NCKEY_BUTTON1;

  /* a drag that began in a preview goes on wherever the pointer is */
  if (t->drag && (left || ni->id == NCKEY_MOTION)) {
    struct node *in = wm_leaf_of(t, t->drag);
    if (!in || in->cls != &view_preview || !preview_mouse(t, in->state, ni->y, ni->x, release ? 2 : 1))
      t->drag = NULL;
    if (release) preview_click_done(t);
    return;
  }
  /* a line between windows follows the pointer */
  if (t->rs.on && (left || ni->id == NCKEY_MOTION)) {
    if (!wm_divider_drag(t, &t->rs.y, &t->rs.x, ni->y, ni->x)) t->rs.on = 0; /* its windows are gone */
    if (release) t->rs.on = 0;
    return;
  }
  /* a press on a window's bar becomes a resize if the pointer then goes up
   * or down, and stays a selection if it goes sideways */
  if (t->rs.armed && (left || ni->id == NCKEY_MOTION)) {
    if (!release && ni->y != t->rs.y) {
      sel_clear(t);
      t->rs.armed = 0;
      t->rs.on = 1;
      on_mouse(t, ni);
      return;
    }
    if (release || ni->x != t->rs.x) t->rs.armed = 0;
  }
  /* and so does one selecting what is on the screen */
  if (t->sel.on && (left || ni->id == NCKEY_MOTION)) {
    if (release) {
      sel_release(t, ni->y, ni->x);
      preview_click_done(t);
    } else {
      sel_move(t, ni->y, ni->x);
    }
    return;
  }
  if (release && left) preview_click_done(t);
  if (release || ni->id == NCKEY_MOTION) return;
  sel_clear(t);

  /* over an overlay the mouse only selects */
  if (t->help || t->mode == MODE_PICKER) {
    if (left) sel_press(t, ni->y, ni->x, (struct rect){0, 0, t->rows_n, t->cols_n}, NULL);
    return;
  }
  struct node *nd = wm_at(t, ni->y, ni->x);
  struct rect clip = nd ? nd->r : line_at(t, ni->y);
  if (left) {
    char split = wm_divider_at(t, ni->y, ni->x);
    t->rs.split = split;
    t->rs.y = ni->y;
    t->rs.x = ni->x;
    t->rs.on = split == 'v'; /* the rule between windows is nothing but a handle */
    t->rs.armed = split == 'h';
    if (t->rs.on) return;
  }
  if (t->mode == MODE_PROMPT) {
    if (ni->id == NCKEY_BUTTON2 || ni->id == NCKEY_BUTTON3) prompt_paste(t);
    else if (nd && nd->cls == &view_preview && wheel) preview_scroll(t, wheel);
    else if (nd && nd->cls == &view_preview && left && preview_owns(nd->state, ni->y, ni->x)) {
      if (preview_mouse(t, nd->state, ni->y, ni->x, 0)) t->drag = nd->state;
    } else if (left) {
      sel_press(t, ni->y, ni->x, clip, nd); /* from a panel's row, say, into the field */
    }
    return;
  }
  if (t->mode != MODE_NORMAL && t->mode != MODE_VISUAL) return;
  if (left && ni->y == 0) { /* a click on one of the bar's tabs */
    for (int i = 0; i < t->tab_n; i++)
      if (ni->x >= t->tab_x[i] && ni->x < t->tab_x[i + 1]) tui_exec(t, tab_command(t, i));
    return;
  }
  if (!nd) { /* the status line, the message line */
    if (left) sel_press(t, ni->y, ni->x, clip, NULL);
    return;
  }
  if (!wheel && !left) return;
  int in_text = 0;
  if (nd->cls == &view_list) {
    int row = wheel ? t->rows.cur + wheel : t->rows.top + ni->y - nd->r.y - 1;
    if (wheel || (ni->y > nd->r.y && row < t->rows.n)) {
      if (row < 0) row = 0;
      if (row >= t->rows.n) row = t->rows.n - 1;
      if (t->rows.n > 0) rows_move(t, row);
      /* a click on a heading opens or closes it */
      if (!wheel && t->rows.n > 0 && rows_head(t, row)) rows_fold(t, 't');
    }
  } else if (nd->cls == &view_panel) {
    if (wheel) panel_wheel(nd->state, wheel);
    else panel_click(nd->state, ni->y - nd->r.y, ni->x - nd->r.x);
  } else if (nd->cls == &view_preview) {
    if (wheel) preview_scroll(t, wheel);
    else if ((in_text = preview_owns(nd->state, ni->y, ni->x)) && preview_mouse(t, nd->state, ni->y, ni->x, 0))
      t->drag = nd->state;
  } else if (nd->cls == &view_console && wheel) {
    console_wheel(nd->state, wheel);
  }
  if (!wheel) {
    if (nd->cls != &view_preview) {
      t->focus = nd;
    } else {
      /* in a preview the click may be the start of a copy: see t->pv */
      double now = now_s();
      int again = now - t->pv.at < 0.4;
      t->pv.at = now;
      t->pv.state = again ? NULL : nd->state;
      if (again) { /* a double click: put the cursor back where the first click took it from */
        struct node *back = t->pv.back ? wm_leaf_of(t, t->pv.back) : NULL;
        if (back) t->focus = back;
        t->pv.back = NULL;
      }
    }
    if (!in_text) sel_press(t, ni->y, ni->x, clip, nd);
  }
  tui_dirty(t);
}

static void on_key(struct tui *t, const struct ncinput *ni) {
  /* the mouse first: the end of a drag is a release */
  if (ni->id >= NCKEY_MOTION && ni->id <= NCKEY_BUTTON11) {
    on_mouse(t, ni);
    return;
  }
  if (ni->evtype == NCTYPE_RELEASE) return;
  sel_clear(t); /* a selection is shown until the next key */
  if (ni->id == NCKEY_RESIZE) {
    unsigned y, x;
    notcurses_refresh(t->nc, &y, &x);
    tui_dirty(t);
    return;
  }
  if (ni->id == NCKEY_EOF) {
    t->quit = 1;
    uv_stop(t->app->loop);
    return;
  }
  /* other synthesized events are not keys */
  if (nckey_synthesized_p(ni->id) && ni->id >= NCKEY_CAPS_LOCK) return;

  uint32_t key = key_from_input(ni);
  if (t->help) {
    help_key(t, key);
    return;
  }
  if (t->mode == MODE_PICKER) {
    picker_key(t, key, ni);
    return;
  }
  if (t->mode == MODE_PROMPT) {
    prompt_key(t, key, ni);
    return;
  }
  if (key == (KEY_CTRL | 'c')) key = NCKEY_ESC;
  /* selecting text in the preview with the keys: they are its own first */
  if (t->mode == MODE_NORMAL && t->km->npending == 0 && preview_selecting(t) && preview_select_key(t, key)) return;
  if (key == NCKEY_ESC && t->km->npending == 0 && t->mode == MODE_NORMAL &&
      t->focus->cls == &view_panel) {
    panel_key(t, t->focus->state, key);
    return;
  }
  if (key == NCKEY_ESC && t->km->npending == 0) {
    if (t->mode == MODE_VISUAL) tui_exec(t, "visual");
    else if (t->rows.search) rows_search(t, NULL);
    free(t->msg);
    t->msg = NULL;
    tui_dirty(t);
    return;
  }
  if (key == NCKEY_ESC) {
    t->km->npending = 0;
    tui_dirty(t);
    return;
  }
  if (t->mode == MODE_NORMAL && t->focus->cls == &view_console && t->km->npending == 0 &&
      console_key(t, t->focus->state, key))
    return;
  /* a focused panel takes keys first, unless a global sequence is under way
   * or the key is one it lets through to a global binding */
  if (t->mode == MODE_NORMAL && t->focus->cls == &view_panel && t->km->npending == 0 &&
      !panel_passes(t->focus->state, key) && panel_key(t, t->focus->state, key))
    return;
  const char *cmd = keymap_feed(t->km, t->mode, key);
  if (cmd) {
    char *copy = xstrdup(cmd); /* the command may rebind keys */
    tui_exec(t, copy);
    free(copy);
  }
  tui_dirty(t); /* pending keys are shown */
}

/* ---- pastes from the terminal ----
 * With bracketed paste on, a terminal (or tmux) wraps what it pastes in
 * ESC[200~ ... ESC[201~. notcurses hands those markers over key by key, so
 * they are recognised here: what lies between is text, never keys. A line
 * break in it therefore cannot submit a field, and a paste outside a field
 * cannot run as commands. */

static void bracketed_paste(int on) {
  FILE *tty = fopen("/dev/tty", "w");
  if (!tty) return;
  fputs(on ? "\033[?2004h" : "\033[?2004l", tty);
  fclose(tty);
}

static void paste_done(struct tui *t) {
  if (t->mode == MODE_PROMPT) prompt_insert_flat(t, t->paste.s ? t->paste.s : "");
  else if (t->paste.len) tui_msg(t, 0, "pasted text goes into a field: open one first (:, &, /, or e)");
  sb_reset(&t->paste);
}

static void dispatch(struct tui *t, const struct ncinput *ni) {
  if (!t->pasting) {
    on_key(t, ni);
    return;
  }
  if (ni->evtype == NCTYPE_RELEASE) return;
  if (ni->id == NCKEY_ENTER) sb_putc(&t->paste, '\n');
  else if (ni->id == NCKEY_TAB) sb_putc(&t->paste, ' ');
  else if (!nckey_synthesized_p(ni->id) && ni->id >= 0x20 && ni->utf8[0]) sb_puts(&t->paste, ni->utf8);
}

static void flush_held(struct tui *t) {
  int n = t->nheld;
  t->nheld = 0;
  for (int i = 0; i < n; i++) dispatch(t, &t->held[i]);
}

static void held_timer_cb(uv_timer_t *h) {
  flush_held(h->data); /* it was an Escape after all, or a paste cut short */
}

static void feed(struct tui *t, const struct ncinput *ni) {
  static const uint32_t marker[] = {NCKEY_ESC, '[', '2', '0', 0, '~'}; /* [4]: '0' opens, '1' closes */
  int at = t->nheld;
  int fits = ni->evtype != NCTYPE_RELEASE && at < 6 &&
             (at == 4 ? ni->id == '0' || ni->id == '1' : ni->id == marker[at]);
  if (!fits) {
    flush_held(t);
    /* the key that broke the pattern may itself start one */
    if (ni->evtype != NCTYPE_RELEASE && ni->id == NCKEY_ESC) {
      t->held[t->nheld++] = *ni;
      uv_timer_start(&t->held_timer, held_timer_cb, 30, 0);
    } else {
      dispatch(t, ni);
    }
    return;
  }
  t->held[t->nheld++] = *ni;
  if (t->nheld < 6) {
    uv_timer_start(&t->held_timer, held_timer_cb, 30, 0);
    return;
  }
  uv_timer_stop(&t->held_timer);
  int opening = t->held[4].id == '0';
  t->nheld = 0;
  if (opening) {
    t->pasting = 1;
    sb_reset(&t->paste);
  } else if (t->pasting) {
    t->pasting = 0;
    paste_done(t);
  }
}

static void input_cb(uv_poll_t *h, int status, int events) {
  struct tui *t = h->data;
  struct ncinput ni;
  while (!t->quit) {
    uint32_t id = notcurses_get_nblock(t->nc, &ni);
    if (id == 0 || id == (uint32_t)-1) break;
    feed(t, &ni);
  }
}

/* a log entry was written, on some thread: the console may need redrawing */
static void log_arrived(void *ud) {
  bridge_redraw(ud);
}

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

static void draw_bottom(struct tui *t, int y) {
  struct ncplane *n = t->std;
  int W = t->cols_n;
  if (t->mode == MODE_PROMPT) {
    const char *lead = t->prompt == PROMPT_FILTER ? "&" : t->prompt == PROMPT_SEARCH ? "/"
                     : t->prompt == PROMPT_INPUT && t->input_label ? t->input_label : ":";
    const char *text = t->line.text.s ? t->line.text.s : "";
    dr_style(n, theme.accent, C_DEFAULT, A_BOLD);
    int lw = dr_text(n, y, 0, W / 2, lead);
    dr_style(n, C_DEFAULT, C_DEFAULT, 0);
    /* keep the cursor in view on a long line */
    int cur = dr_width(text, t->line.cur);
    size_t skip = 0;
    while (cur - dr_width(text, skip) > W - lw - 2 && skip < t->line.cur) skip++;
    while (skip < t->line.text.len && ((unsigned char)text[skip] & 0xc0) == 0x80) skip++;
    dr_text(n, y, lw, W - lw, text + skip);
    if (t->nsugg_match) draw_suggestions(t, y, lw);
    notcurses_cursor_enable(t->nc, y, lw + cur - dr_width(text, skip));
    return;
  }
  if (t->msg) {
    dr_style(n, t->msg_error ? theme.error : C_DEFAULT, C_DEFAULT, 0);
    dr_text(n, y, 0, W - 12, t->msg);
  }
  if (t->km->npending) {
    sbuf k = SBUF_INIT;
    key_format(&k, t->km->pending, t->km->npending);
    dr_style(n, theme.dim, C_DEFAULT, 0);
    dr_text(n, y, W - 11, 10, k.s);
    sb_free(&k);
  }
}

static void draw_help(struct tui *t) {
  struct ncplane *n = t->std;
  int W = t->cols_n, H = t->rows_n;
  int w = W > 84 ? 80 : W - 2, h = H - 4;
  if (w < 20 || h < 4) return;
  int x = (W - w) / 2, y = 1;
  int total = 0;
  for (const char *p = t->help; *p; p++) total += *p == '\n';
  if (t->help_scroll > total - h + 2) t->help_scroll = total - h + 2;
  if (t->help_scroll < 0) t->help_scroll = 0;

  const char *p = t->help;
  for (int i = 0; i < t->help_scroll && *p; i++) {
    const char *nl = strchr(p, '\n');
    p = nl ? nl + 1 : p + strlen(p);
  }
  for (int r = 0; r < h; r++) {
    dr_style(n, C_DEFAULT, theme.bar_bg, 0);
    dr_fill(n, y + r, x, w);
    if (r == 0 && t->pager_title) {
      dr_style(n, theme.dim, theme.bar_bg, 0);
      dr_text(n, y, x + 2, w - 4, t->pager_title);
    }
    if (r == 0 || r == h - 1 || !*p) continue;
    const char *nl = strchr(p, '\n');
    size_t len = nl ? (size_t)(nl - p) : strlen(p);
    int heading = len > 0 && p[0] != ' ';
    dr_style(n, heading ? theme.accent : C_DEFAULT, theme.bar_bg, heading ? A_BOLD : 0);
    dr_textn(n, y + r, x + 2, w - 4, p, len);
    p = nl ? nl + 1 : p + len;
  }
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
static const char *tab_command(const struct tui *t, int i) {
  int sync = t->app->cfg.sync_dir[0] != '\0';
  if (i == 0) return "source library";
  if (i == 1 && sync) return "sync";
  return "config";
}

static void draw_tabs(struct tui *t) {
  struct ncplane *n = t->std;
  dr_style(n, theme.dim, theme.bar_bg, 0);
  dr_fill(n, 0, 0, t->cols_n);
  int sync = t->app->cfg.sync_dir[0] != '\0';
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
  keymap_set_leader(t->km, t->app->cfg.leader);
  wm_note_focus(t);
  if (t->peek && t->focus->cls != &view_panel) { /* the panel that was looking has lost the cursor */
    t->peek = 0;
    preview_book_changed(t);
  }
  if (t->rows_n >= 4 && t->cols_n >= 20) {
    int top = 1; /* the bar of tabs */
    wm_layout(t, (struct rect){top, 0, t->rows_n - 2 - top, t->cols_n});
    wm_draw(t);
    if (top) draw_tabs(t);
    draw_status(t, t->rows_n - 2);
    draw_bottom(t, t->rows_n - 1);
    if (t->help) draw_help(t);
    if (t->picker) picker_draw(t);
    sel_draw(t);
  }
  dr_style(t->std, C_DEFAULT, C_DEFAULT, 0);
  notcurses_render(t->nc);
}

static void prepare_cb(uv_prepare_t *h) {
  struct tui *t = h->data;
  if (t->dirty && !t->quit) {
    t->dirty = 0;
    render(t);
  }
}

/* --------------------------------------------------------- background work */

static void ix_progress(struct indexer *ix, const struct index_stats *st, void *ud) {
  struct tui *t = ud;
  t->ix_done = st->done;
  t->ix_total = st->queued;
  t->ix_failed = st->failed;
  tui_dirty(t);
}

static void ix_done(struct indexer *ix, const struct index_stats *st, void *ud) {
  struct tui *t = ud;
  struct index_stats s = *st; /* st lives inside the indexer being freed */
  indexer_free(t->ix);
  t->ix = NULL;
  /* tell whoever was waiting, even when leaving: their memory is theirs to free */
  int nhook = t->nix_hook;
  t->nix_hook = 0;
  for (int i = 0; i < nhook; i++) t->ix_hook[i](&s, t->ix_hook_ud[i]);
  if (t->quit) return;
  if (s.queued)
    tui_msg(t, 0, "indexed %d files in %.1fs (%d could not be read)", s.ok, s.elapsed, s.failed);
  else
    tui_msg(t, 0, "index is up to date");
  rows_reload(t); /* text-based filters may now match more */
  if (s.ok > 0 && !strcmp(t->app->cfg.ocr, "auto")) tui_exec(t, "run ocr");
  else if (s.ok > 0 && !strcmp(t->app->cfg.ocr, "always")) tui_exec(t, "run ocr is:indexed -is:ocr");
}

void tui_start_index(struct tui *t, int force) {
  if (t->ix) {
    tui_msg(t, 1, "indexing is already running");
    return;
  }
  struct index_opts o = {0};
  char *err = NULL;
  o.pages = t->app->cfg.pages;
  o.layout_pages = t->app->cfg.layout_pages < o.pages ? t->app->cfg.layout_pages : o.pages;
  o.force = force;
  o.inflight = app_jobs(t->app) + app_jobs(t->app) / 2;
  t->ix_done = t->ix_total = t->ix_failed = 0;
  t->ix = indexer_start(t->app->loop, &t->app->db, &o, ix_progress, ix_done, t, &err);
  if (!t->ix) {
    tui_msg(t, 1, "%s", err);
    free(err);
  }
  tui_dirty(t);
}

int tui_index(struct tui *t, const struct index_opts *o, void (*done)(const struct index_stats *st, void *ud),
              void *ud, char **err) {
  if (t->nix_hook == 8) {
    *err = xstrdup("too many scripts are waiting for the indexer");
    return -1;
  }
  if (!t->ix) {
    t->ix_done = t->ix_total = t->ix_failed = 0;
    t->ix = indexer_start(t->app->loop, &t->app->db, o, ix_progress, ix_done, t, err);
    if (!t->ix) return -1;
    tui_dirty(t);
  }
  t->ix_hook[t->nix_hook] = done;
  t->ix_hook_ud[t->nix_hook++] = ud;
  return 0;
}

/* Calibre changed underneath us (the content server, calibredb, another
 * lulibre): pick it up without being asked. */
static void tick_cb(uv_timer_t *h) {
  struct tui *t = h->data;
  char *err = NULL;
  if (t->ix || t->quit) return; /* the indexer holds a write transaction */
  int rc = db_mirror(&t->app->db, t->app->cfg.library, 0, &err);
  if (rc > 0) {
    rows_reload(t);
    tui_start_index(t, 0);
  } else if (rc < 0) {
    free(err);
  }
}

/* -------------------------------------------------------------------- run */

void tui_setup(void) {
  static int done;
  if (done) return;
  done = 1;
  commands_builtin();
  keymap_defaults(&tui_keymap);
  ctx_defaults();
}

void tui_teardown(void) {
  commands_free();
  keymap_free(&tui_keymap);
  ctx_free();
}

static void closed(uv_handle_t *h) {
  (void)h;
}

static void freed(uv_handle_t *h) {
  free(h);
}

/* Take the terminal: notcurses, raw keys, the mouse. */
static void terminal_start(struct tui *t) {
  struct notcurses_options no = {.flags = NCOPTION_SUPPRESS_BANNERS};
  t->nc = notcurses_core_init(&no, NULL);
  if (!t->nc) die("cannot initialise the terminal (TERM=%s)", getenv("TERM") ? getenv("TERM") : "");
  notcurses_linesigs_disable(t->nc); /* Ctrl-C is a key, not a signal */
  crash_install(); /* again, to run before notcurses' handlers, which give the terminal back */
  bracketed_paste(1);
  if (t->app->cfg.mouse) notcurses_mice_enable(t->nc, NCMICE_BUTTON_EVENT | NCMICE_DRAG_EVENT);
  t->std = notcurses_stdplane(t->nc);
  t->nc_gen++;
}

/* notcurses reads the terminal on a thread of its own and says when it has
 * keys through a descriptor of its own: that is watched */
static void input_watch(struct tui *t) {
  t->input = xcalloc(1, sizeof *t->input);
  uv_poll_init(t->app->loop, t->input, notcurses_inputready_fd(t->nc));
  t->input->data = t;
  uv_poll_start(t->input, UV_READABLE, input_cb);
}

static void input_unwatch(struct tui *t) {
  if (!t->input) return;
  uv_poll_stop(t->input);
  uv_close((uv_handle_t *)t->input, freed);
  t->input = NULL;
}

/* a program on $PATH, as a malloc'd path; NULL when there is none */
static char *which(const char *name) {
  const char *path = getenv("PATH");
  if (!path) path = "/usr/bin:/bin";
  while (*path) {
    const char *end = strchr(path, ':');
    size_t n = end ? (size_t)(end - path) : strlen(path);
    char *full = xasprintf("%.*s/%s", (int)n, path, name);
    if (access(full, X_OK) == 0) return full;
    free(full);
    path += n + (end ? 1 : 0);
  }
  return NULL;
}

/* The editor is given the terminal whole. notcurses cannot simply step
 * aside (its input thread would take the editor's keys), so it is stopped
 * and started again around the editor; the planes it held go with it
 * (nc_gen tells the preview so), and everything is drawn afresh. */
int tui_edit_file(struct tui *t, const char *path) {
  const char *editor = getenv("VISUAL");
  if (!editor || !*editor) editor = getenv("EDITOR");
  char *fallback = NULL;
  if (!editor || !*editor) {
    fallback = which("vim");
    if (!fallback) fallback = which("vi");
    if (!fallback) return -1;
    editor = fallback;
  }
  input_unwatch(t);
  bracketed_paste(0);
  notcurses_stop(t->nc);
  t->nc = NULL;
  int status = -1;
  struct sigaction ign = {.sa_handler = SIG_IGN}, old_int, old_quit;
  sigaction(SIGINT, &ign, &old_int);
  sigaction(SIGQUIT, &ign, &old_quit);
  pid_t pid = fork();
  if (pid == 0) {
    signal(SIGINT, SIG_DFL);
    signal(SIGQUIT, SIG_DFL);
    /* through the shell, so that EDITOR="code --wait" works */
    execl("/bin/sh", "sh", "-c", "exec $0 \"$1\"", editor, path, (char *)NULL);
    _exit(127);
  } else if (pid > 0) {
    int st;
    while (waitpid(pid, &st, 0) < 0 && errno == EINTR) {
    }
    status = WIFEXITED(st) ? WEXITSTATUS(st) : -1;
  }
  sigaction(SIGINT, &old_int, NULL);
  sigaction(SIGQUIT, &old_quit, NULL);
  free(fallback);
  terminal_start(t);
  input_watch(t);
  notcurses_refresh(t->nc, NULL, NULL);
  tui_dirty(t);
  return status;
}

int tui_run(struct app *app) {
  if (!isatty(STDIN_FILENO) || !isatty(STDOUT_FILENO)) {
    warnf("the interactive interface needs a terminal; see `lulibre -h` for commands");
    return 2;
  }
  app_open_db(app);

  struct tui tui, *t = &tui;
  memset(t, 0, sizeof *t);
  t->app = app;
  char *err = NULL;
  if (db_open_reader(&t->rdb, app->db.path, &err)) die("%s", err);

  terminal_start(t);

  t->mode = MODE_NORMAL;
  tui_setup();
  t->km = &tui_keymap;
  app->tui = t;
  rows_init(t);
  wm_init(t);

  uv_loop_t *loop = app->loop;
  input_watch(t);
  uv_prepare_init(loop, &t->prepare);
  uv_timer_init(loop, &t->tick);
  uv_timer_init(loop, &t->settle);
  uv_timer_init(loop, &t->ftimer);
  uv_timer_init(loop, &t->held_timer);
  t->held_timer.data = t;
  t->prepare.data = t->tick.data = t->settle.data = t->ftimer.data = t;
  uv_prepare_start(&t->prepare, prepare_cb);
  uv_timer_start(&t->tick, tick_cb, 2000, 2000);

  rows_set_filter(t, "");
  history_load(t);
  /* first run, or books added since the last one: index in the background */
  sqlite3_stmt *st;
  if (sqlite3_prepare_v2(app->db.h, "SELECT count(*) FROM files WHERE status = 0", -1, &st, NULL) ==
      SQLITE_OK) {
    int pending = sqlite3_step(st) == SQLITE_ROW ? sqlite3_column_int(st, 0) : 0;
    sqlite3_finalize(st);
    const char *policy = app->cfg.auto_index;
    if (pending && !strcmp(policy, "auto")) tui_start_index(t, 0);
    else if (pending && !strcmp(policy, "ask"))
      tui_msg(t, 0, "%d file%s not indexed yet; :index reads them", pending, pending == 1 ? " is" : "s are");
  }
  char *mismatch = lstate_tree_mismatch();
  if (mismatch) tui_msg(t, 1, "%s", mismatch);
  free(mismatch);
  tui_dirty(t);
  log_to_stderr(0); /* the terminal is ours; the console shows the log */
  log_on_entry(log_arrived, app);
  log_debug("interface up: %d books listed from %s", t->rows.n, app->cfg.library);
  bridge_start(app); /* from here on Lua runs on its own thread */
  uv_run(loop, UV_RUN_DEFAULT);

  /* Give the terminal back first, then let work in flight finish. */
  t->quit = 1;
  if (t->picker) picker_close(t);
  tui_input_cancel(t);
  bridge_stop(app); /* scripts stop with the interface; their thread ends */
  log_on_entry(NULL, NULL);
  wm_free(t);
  bracketed_paste(0);
  notcurses_stop(t->nc);
  t->nc = NULL;
  log_to_stderr(1);
  if (t->ix) indexer_cancel(t->ix);
  input_unwatch(t);
  uv_close((uv_handle_t *)&t->prepare, closed);
  uv_close((uv_handle_t *)&t->tick, closed);
  uv_close((uv_handle_t *)&t->settle, closed);
  uv_close((uv_handle_t *)&t->ftimer, closed);
  uv_close((uv_handle_t *)&t->held_timer, closed);
  uv_run(loop, UV_RUN_DEFAULT);

  rows_free(t);
  sb_free(&t->paste);
  clip_free();
  app->tui = NULL;
  le_free(&t->line);
  for (int k = 0; k < 3; k++) {
    for (int i = 0; i < t->hist[k].n; i++) free(t->hist[k].v[i]);
    free(t->hist[k].v);
  }
  free(t->hist_prefix);
  free(t->comp_ctx);
  free(t->prompt_saved);
  free(t->input_label);
  free(t->progress);
  for (int i = 0; i < t->nbadges; i++) {
    free(t->badges[i].name);
    free(t->badges[i].text);
  }
  suggest_clear(t);
  free(t->pager_title);
  free(t->help);
  free(t->msg);
  db_close(&t->rdb);
  return 0;
}
