/* Input from the terminal: keys, the mouse, and pastes. */

#include <stdio.h>
#include <stdlib.h>

#include "lua/bridge.h"
#include "lua/lapi.h"
#include "tui/tui.h"

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

void prompt_paste(struct tui *t) {
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
  const struct binding *b = keymap_feed(t->km, t->mode, key);
  if (b && b->lua_ref) { /* a Lua function: a task, named after its keys */
    sbuf k = SBUF_INIT;
    key_format(&k, b->keys, b->nkeys);
    lapi_spawn_ref(t->app, b->lua_ref, k.s, "");
    sb_free(&k);
  } else if (b && b->command) {
    char *copy = xstrdup(b->command); /* the command may rebind keys */
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

void bracketed_paste(int on) {
  FILE *tty = fopen("/dev/tty", "w");
  if (!tty) return;
  fputs(on ? "\033[?2004h" : "\033[?2004l", tty);
  fclose(tty);
}

/* Handing the terminal back (to an editor, or at the end). notcurses pushes
 * the kitty keyboard protocol's flags on the alternate screen when it
 * starts (CSI > u, then CSI = 27 u) and does not pop them when it stops; the
 * protocol keeps the alternate screen's stack apart from the main screen's
 * and nothing resets it on leaving, so the next program on the alternate
 * screen (an editor, less) would be sent every key as an escape code. They
 * are popped here, while the alternate screen is still the one shown. */
void terminal_release(struct tui *t) {
  bracketed_paste(0);
  FILE *tty = fopen("/dev/tty", "w");
  if (tty) {
    fputs("\033[<u", tty);
    fclose(tty);
  }
  notcurses_stop(t->nc);
  t->nc = NULL;
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

void input_read_cb(uv_poll_t *h, int status, int events) {
  struct tui *t = h->data;
  struct ncinput ni;
  while (!t->quit) {
    uint32_t id = notcurses_get_nblock(t->nc, &ni);
    if (id == 0 || id == (uint32_t)-1) break;
    feed(t, &ni);
  }
}

/* a log entry was written, on some thread: the console may need redrawing */
void log_arrived(void *ud) {
  bridge_redraw(ud);
}
