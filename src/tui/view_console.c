/* The console: the log, live, in a window along the bottom.
 *
 * ` (or :console) opens and closes it without taking the focus, so it can be
 * watched while working. With the focus in it (<C-w>j, Tab, a click):
 *   j k  <C-d> <C-u>  gg  G     scroll; G goes back to following new entries
 *   e w i d                     show errors only / warnings too / notices too /
 *                               everything (the trace exists in debug builds)
 *   c                           forget what is shown
 *   q  Esc                      close
 * Errors are counted in the status line until the console has shown them. */
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "app.h"
#include "core/log.h"
#include "core/util.h"
#include "tui/tui.h"

struct cstate {
  int level;       /* show entries up to this level */
  int back;        /* lines scrolled up from the newest; 0 follows */
  int page, lines; /* as last drawn */
  uint32_t pending; /* the first key of a two-key binding such as gg */
};

struct cline {
  int level;
  char *text; /* owned */
};

struct gather {
  int level;
  struct cline *v;
  int n, cap;
};

static void put(struct gather *g, int level, char *text) {
  if (g->n == g->cap) {
    g->cap = g->cap ? g->cap * 2 : 256;
    g->v = xrealloc(g->v, (size_t)g->cap * sizeof *g->v);
  }
  g->v[g->n++] = (struct cline){level, text};
}

/* one entry -> its lines: "12:04:31 error  text", continuation lines indented */
static void collect(const struct log_entry *e, void *ud) {
  struct gather *g = ud;
  if (e->level > g->level) return;
  time_t secs = (time_t)e->when;
  struct tm tm;
  char stamp[16];
  localtime_r(&secs, &tm);
  strftime(stamp, sizeof stamp, "%H:%M:%S", &tm);
  const char *s = e->text;
  for (int first = 1;; first = 0) {
    const char *nl = strchr(s, '\n');
    size_t len = nl ? (size_t)(nl - s) : strlen(s);
    put(g, e->level,
        first ? xasprintf("%s %-5s  %.*s", stamp, log_level_name(e->level), (int)len, s)
              : xasprintf("                 %.*s", (int)len, s));
    if (!nl) break;
    s = nl + 1;
  }
}

static void *create(struct tui *t) {
  struct cstate *cs = xcalloc(1, sizeof *cs);
  cs->level = LULIBRE_DEBUG ? LOG_DEBUG : LOG_INFO;
  cs->page = 8;
  return cs;
}

static void destroy(struct tui *t, void *state) {
  free(state);
}

static int level_color(int level) {
  return level == LOG_ERROR ? theme.error : level == LOG_WARN ? theme.warn
       : level == LOG_DEBUG ? theme.dim : C_DEFAULT;
}

static void draw(struct tui *t, void *state, struct rect r, int focused) {
  struct cstate *cs = state;
  struct ncplane *n = t->std;
  struct gather g = {.level = cs->level};
  log_each(collect, &g);
  t->errors_seen = log_errors(); /* whatever went wrong has now been shown */

  dr_bar(n, r, focused);
  char title[200], scrolled[64];
  snprintf(scrolled, sizeof scrolled, "   (scrolled; %s follows)", ctx_hint(KC_CONSOLE, CA_FOLLOW));
  snprintf(title, sizeof title, "console  %s%s%s", cs->level == LOG_ERROR ? "errors"
           : cs->level == LOG_WARN ? "errors and warnings" : cs->level == LOG_INFO ? "errors, warnings, notices"
           : "everything",
           cs->back ? scrolled : "",
           LULIBRE_DEBUG ? "" : cs->level == LOG_DEBUG ? "   (no trace in a release build)" : "");
  int used = dr_text(n, r.y, r.x + 1, r.w - 2, title);
  sbuf keys = SBUF_INIT; /* the place's hint (scrnman.set) */
  int kw = ctx_hint_line(KC_CONSOLE, &keys) ? dr_width(keys.s, keys.len) : 0;
  if (kw && used + kw + 4 <= r.w) {
    dr_style(n, focused ? theme.on_accent : theme.dim, focused ? theme.accent : theme.bar_bg, 0);
    dr_text(n, r.y, r.x + r.w - kw - 1, kw, keys.s);
  }
  sb_free(&keys);

  int body = r.h - 1;
  cs->page = body > 1 ? body : 1;
  cs->lines = g.n;
  if (cs->back > g.n - body) cs->back = g.n - body;
  if (cs->back < 0) cs->back = 0;
  int first = g.n - body - cs->back;
  if (first < 0) first = 0;
  for (int i = 0; i < body && first + i < g.n; i++) {
    dr_style(n, level_color(g.v[first + i].level), C_DEFAULT, 0);
    dr_text(n, r.y + 1 + i, r.x + 1, r.w - 2, g.v[first + i].text);
  }
  if (g.n == 0 && body > 0) {
    dr_style(n, theme.dim, C_DEFAULT, 0);
    dr_text(n, r.y + 1, r.x + 1, r.w - 2, "nothing has been logged at this level");
  }
  for (int i = 0; i < g.n; i++) free(g.v[i].text);
  free(g.v);
}

static int key(struct tui *t, void *state, uint32_t k, const struct ncinput *ni) {
  return console_key(t, state, k);
}

const struct view_class view_console = {"console", create, destroy, draw, NULL, key, 0};

int console_key(struct tui *t, void *state, uint32_t key) {
  struct cstate *cs = state;
  switch (ctx_feed(KC_CONSOLE, &cs->pending, key)) {
    case CTX_PENDING: return 1;
    case CA_UP: cs->back++; break;
    case CA_DOWN: cs->back--; break;
    case CA_HALF_UP: cs->back += cs->page / 2 + 1; break;
    case CA_HALF_DOWN: cs->back -= cs->page / 2 + 1; break;
    case CA_FOLLOW: cs->back = 0; break;
    case CA_TOP: cs->back = cs->lines; break;
    case CA_ERRORS: cs->level = LOG_ERROR; break;
    case CA_WARNINGS: cs->level = LOG_WARN; break;
    case CA_NOTICES: cs->level = LOG_INFO; break;
    case CA_EVERYTHING: cs->level = LOG_DEBUG; break;
    case CA_CLEAR: log_clear(); cs->back = 0; break;
    case CA_CLOSE:
      wm_close(t); /* frees cs */
      tui_dirty(t);
      return 1;
    default: return 0; /* Tab, ':' and the rest keep their meaning */
  }
  if (cs->back < 0) cs->back = 0;
  tui_dirty(t);
  return 1;
}

void console_wheel(void *state, int delta) {
  struct cstate *cs = state;
  cs->back -= delta;
  if (cs->back < 0) cs->back = 0;
}
