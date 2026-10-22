/* Keys that belong to a place rather than to the interface as a whole:
 * moving inside a panel, editing the line being typed, the picker, the
 * pager, the console. The global keymap (keymap.c) binds keys to command
 * lines; here a key is bound to one of a place's named actions, and the code
 * for that place asks which action a key means. So these can be rebound
 * like any other:
 *
 *   lulibre.map("panel", "n", "down")       lulibre.map("line", "<C-g>", "cancel")
 *
 * A binding is one key, or two in a row ("gg"). An empty action unbinds. */
#include <stdlib.h>
#include <string.h>

#include "tui/tui.h"

struct action {
  const char *name, *keys, *about; /* keys: the defaults, separated by spaces */
};

/* In the order of the enums in tui.h: an action's number is its place here plus one. */
static const struct action panel_actions[] = {
  {"down", "j <Down>", "down a row"},
  {"up", "k <Up>", "up a row"},
  {"top", "gg <Home>", "the first row"},
  {"bottom", "G <End>", "the last row"},
  {"half-down", "<C-d>", "half a page down"},
  {"half-up", "<C-u>", "half a page up"},
  {"page-down", "<C-f> <PageDown>", "a page down"},
  {"page-up", "<C-b> <PageUp>", "a page up"},
  {"close", "q", "close the panel"},
  {"back", "<Esc>", "back to the window this panel was reached from, leaving it open (a dialog closes)"},
};
static const struct action line_actions[] = {
  {"accept", "<CR>", "enter what was typed"},
  {"cancel", "<Esc> <C-c>", "leave without it"},
  {"paste", "<C-v>", "paste what was last copied, as one line"},
  {"copy", "<C-y>", "copy the line as it stands"},
  {"complete", "<Tab>", "take the highlighted suggestion or completion"},
  {"next", "<C-n>", "the next suggestion or completion"},
  {"prev", "<C-p>", "the previous one"},
  {"up", "<Up>", "back in the history (in a field: the previous suggestion)"},
  {"down", "<Down>", "forward in the history (in a field: the next suggestion)"},
  {"preview-up", "<PageUp>", "scroll the preview up without leaving the line"},
  {"preview-down", "<PageDown>", "scroll the preview down"},
  {"left", "<Left> <C-b>", "a character left"},
  {"right", "<Right> <C-f>", "a character right"},
  {"home", "<Home> <C-a>", "the start of the line"},
  {"end", "<End> <C-e>", "the end of the line"},
  {"backspace", "<BS> <C-h>", "delete the character before the cursor"},
  {"delete", "<Del>", "delete the character under it"},
  {"kill-start", "<C-u>", "delete back to the start"},
  {"kill-end", "<C-k>", "delete to the end"},
  {"kill-word", "<C-w>", "delete a word back"},
  {"word-left", "<C-Left> <M-Left>", "to the start of the word, or of the one before (as b)"},
  {"word-right", "<C-Right> <M-Right>", "to the start of the next word (as w)"},
};
static const struct action picker_actions[] = {
  {"accept", "<CR>", "take the highlighted entry"},
  {"cancel", "<Esc> <C-c>", "close without choosing"},
  {"down", "<Down> <C-n> <C-j>", "the next entry"},
  {"up", "<Up> <C-p> <C-k>", "the previous entry"},
  {"page-down", "<PageDown> <C-d>", "a page down"},
  {"page-up", "<PageUp> <C-u>", "a page up"},
};
static const struct action pager_actions[] = {
  {"down", "j <Down>", "down a line"},
  {"up", "k <Up>", "up a line"},
  {"page-down", "<C-d> <PageDown> <Space>", "a page down"},
  {"page-up", "<C-u> <PageUp>", "a page up"},
  {"top", "g", "the top"},
};
static const struct action console_actions[] = {
  {"up", "k <Up>", "back a line"},
  {"down", "j <Down>", "forward a line"},
  {"half-up", "<C-u> <PageUp>", "back half a page"},
  {"half-down", "<C-d> <PageDown>", "forward half a page"},
  {"top", "gg", "the oldest entry"},
  {"follow", "G <End>", "the newest entry, and follow new ones"},
  {"errors", "e", "show errors only"},
  {"warnings", "w", "errors and warnings"},
  {"notices", "i", "errors, warnings and notices"},
  {"everything", "d", "everything (the trace exists in debug builds)"},
  {"clear", "c", "forget what is shown"},
  {"close", "q <Esc>", "close the console"},
};

static const struct action select_actions[] = {
  {"left", "<Left> h", "a character left"},
  {"right", "<Right> l", "a character right"},
  {"up", "<Up> k", "up a line"},
  {"down", "<Down> j", "down a line"},
  {"word", "w", "the next word"},
  {"back", "b", "the word before"},
  {"start", "<Home> 0", "the start of the line"},
  {"end", "<End> $", "the end of the line"},
  {"top", "gg", "the top of the page"},
  {"bottom", "G", "the end of the page"},
  {"mark", "v", "begin selecting at the cursor; press again to cancel"},
  {"line", "V", "select the whole line"},
  {"copy", "<CR> y", "copy what is selected (the line, when nothing is) and leave"},
  {"leave", "q <Esc>", "leave without copying"},
};

static const struct {
  const char *name, *title;
  const struct action *actions;
  int n;
} ctxs[KC_N] = {
  [KC_PANEL] = {"panel", "IN A PANEL", panel_actions, (int)ARRAY_LEN(panel_actions)},
  [KC_LINE] = {"line", "WHILE TYPING", line_actions, (int)ARRAY_LEN(line_actions)},
  [KC_PICKER] = {"picker", "IN A PICKER (the line's editing keys work too)", picker_actions, (int)ARRAY_LEN(picker_actions)},
  [KC_PAGER] = {"pager", "IN AN OVERLAY SUCH AS THIS (any other key closes it)", pager_actions, (int)ARRAY_LEN(pager_actions)},
  [KC_CONSOLE] = {"console", "IN THE CONSOLE", console_actions, (int)ARRAY_LEN(console_actions)},
  [KC_SELECT] = {"select", "SELECTING TEXT IN THE PREVIEW", select_actions, (int)ARRAY_LEN(select_actions)},
};

static struct cbind {
  int ctx, action, nkeys;
  uint32_t keys[2];
} *binds;
static int nbinds, capbinds;

static void ctx_unbind_keys(int ctx, const uint32_t *keys, int n) {
  for (int i = 0; i < nbinds; i++)
    if (binds[i].ctx == ctx && binds[i].nkeys == n && !memcmp(binds[i].keys, keys, (size_t)n * sizeof *keys)) {
      memmove(&binds[i], &binds[i + 1], (size_t)(nbinds - i - 1) * sizeof *binds);
      nbinds--;
      i--;
    }
}

static void ctx_bind_keys(int ctx, const uint32_t *keys, int n, int action) {
  ctx_unbind_keys(ctx, keys, n);
  if (nbinds == capbinds) {
    capbinds = capbinds ? capbinds * 2 : 128;
    binds = xrealloc(binds, (size_t)capbinds * sizeof *binds);
  }
  struct cbind *b = &binds[nbinds++];
  memset(b, 0, sizeof *b);
  b->ctx = ctx;
  b->action = action;
  b->nkeys = n;
  memcpy(b->keys, keys, (size_t)n * sizeof *keys);
}

void ctx_defaults(void) {
  nbinds = 0;
  for (int c = 0; c < KC_N; c++)
    for (int a = 0; a < ctxs[c].n; a++) {
      char *specs = xstrdup(ctxs[c].actions[a].keys), *save = NULL;
      for (char *s = strtok_r(specs, " ", &save); s; s = strtok_r(NULL, " ", &save)) {
        uint32_t keys[KEYSEQ_MAX];
        int n = key_parse(s, keys);
        if (n == 1 || n == 2) ctx_bind_keys(c, keys, n, a + 1);
      }
      free(specs);
    }
}

void ctx_free(void) {
  free(binds);
  binds = NULL;
  nbinds = capbinds = 0;
}

int ctx_named(const char *name) {
  for (int c = 0; c < KC_N; c++)
    if (!strcmp(ctxs[c].name, name)) return c;
  return -1;
}

int ctx_bind(const char *ctx, const char *spec, const char *action, char **err) {
  int c = ctx_named(ctx);
  if (c < 0) {
    *err = xasprintf("no place named '%s' has keys of its own", ctx);
    return -1;
  }
  uint32_t keys[KEYSEQ_MAX];
  int n = key_parse(spec, keys);
  if (n != 1 && n != 2) {
    *err = xasprintf("'%s' is not one key, or two in a row", spec);
    return -1;
  }
  if (!action || !*action) {
    ctx_unbind_keys(c, keys, n);
    return 0;
  }
  for (int a = 0; a < ctxs[c].n; a++)
    if (!strcmp(ctxs[c].actions[a].name, action)) {
      ctx_bind_keys(c, keys, n, a + 1);
      return 0;
    }
  sbuf names = SBUF_INIT;
  for (int a = 0; a < ctxs[c].n; a++) sb_printf(&names, "%s%s", a ? ", " : "", ctxs[c].actions[a].name);
  *err = xasprintf("%s has no action '%s' (it has: %s)", ctx, action, names.s);
  sb_free(&names);
  return -1;
}

int ctx_feed(int ctx, uint32_t *pending, uint32_t key) {
  if (pending && *pending) {
    uint32_t first = *pending;
    *pending = 0;
    for (int i = nbinds - 1; i >= 0; i--)
      if (binds[i].ctx == ctx && binds[i].nkeys == 2 && binds[i].keys[0] == first && binds[i].keys[1] == key)
        return binds[i].action;
    /* not a pair after all: the key counts on its own */
  }
  for (int i = nbinds - 1; i >= 0; i--)
    if (binds[i].ctx == ctx && binds[i].nkeys == 1 && binds[i].keys[0] == key) return binds[i].action;
  if (pending)
    for (int i = nbinds - 1; i >= 0; i--)
      if (binds[i].ctx == ctx && binds[i].nkeys == 2 && binds[i].keys[0] == key) {
        *pending = key;
        return CTX_PENDING;
      }
  return 0;
}

int ctx_bound(int ctx, uint32_t key) {
  for (int i = 0; i < nbinds; i++)
    if (binds[i].ctx == ctx && binds[i].keys[0] == key) return 1;
  return 0;
}

static int ctx_key_of(int ctx, int action, sbuf *out) {
  for (int i = nbinds - 1; i >= 0; i--)
    if (binds[i].ctx == ctx && binds[i].action == action) {
      key_format(out, binds[i].keys, binds[i].nkeys);
      return 1;
    }
  return 0;
}

const char *ctx_hint_in(char *buf, size_t size, int ctx, int action) {
  sbuf out = SBUF_INIT;
  if (ctx_key_of(ctx, action, &out)) snprintf(buf, size, "%s", out.s);
  else buf[0] = '\0';
  sb_free(&out);
  return buf;
}

/* One place's actions with the keys they are on, for the help overlay; with
 * names set, the action names too, which is what lulibre.map wants. */
void ctx_describe(int ctx, sbuf *out, int names) {
  sb_printf(out, "%s%s%s%s\n", ctxs[ctx].title, names ? "   lulibre.map(\"" : "", names ? ctxs[ctx].name : "",
            names ? "\", key, action)" : "");
  for (int a = 0; a < ctxs[ctx].n; a++) {
    sbuf keys = SBUF_INIT;
    for (int i = 0; i < nbinds; i++)
      if (binds[i].ctx == ctx && binds[i].action == a + 1) {
        if (keys.len) sb_puts(&keys, "  ");
        key_format(&keys, binds[i].keys, binds[i].nkeys);
      }
    if (names) sb_printf(out, "  %-22s %-13s %s\n", keys.s ? keys.s : "", ctxs[ctx].actions[a].name, ctxs[ctx].actions[a].about);
    else if (keys.len) sb_printf(out, "  %-22s %s\n", keys.s, ctxs[ctx].actions[a].about);
    sb_free(&keys);
  }
}
