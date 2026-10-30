/* The command, filter and search lines: suggestions while typing, the
 * prompt itself, and the history kept between sessions. */

#include <stdlib.h>
#include <string.h>

#include "match/fold.h"
#include "match/fuzzy.h"
#include "tui/tui.h"

/* ----------------------------------------------------------- suggestions */

void suggest_clear(struct tui *t) {
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

void suggest_rematch(struct tui *t) {
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

void suggest_accept(struct tui *t) {
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

void draw_suggestions(struct tui *t, int bottom_y, int x) {
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

void history_load(struct tui *t) {
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

void *tui_input_ud_if(struct tui *t, input_fn *cb) {
  return t->prompt == PROMPT_INPUT && t->input_cb == cb ? t->input_ud : NULL;
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

void prompt_key(struct tui *t, uint32_t key, const struct ncinput *ni) {
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
void prompt_changed(struct tui *t) {
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
