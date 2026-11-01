/* Keys that belong to a place rather than to the interface as a whole:
 * moving inside a panel, editing the line being typed, the picker, the
 * pager, the console. The global keymap (keymap.c) binds keys to command
 * lines; here a key is bound to one of a place's named actions, and the code
 * for that place asks which action a key means. So these can be rebound
 * like any other:
 *
 *   keymap.set("panel", "n", "down")       keymap.set("line", "<C-g>", "cancel")
 *
 * A binding is one key, or two in a row ("gg"). An empty action unbinds.
 * With a description, what ? says the action does changes; hidden leaves
 * the action out of ?.
 *
 * lulibre's places come first, in the order of the enums in tui.h; a
 * screen made in Lua (scrnman.create) adds a place of its own after them,
 * with its actions and the ones its hint shows, and goes with the
 * lua_State (:restart-scripts). */
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
  {"top", "g <Home>", "the top"},
  {"bottom", "G <End>", "the end"},
  {"toggle", "<CR> za", "open or close the heading the cursor is under"},
  {"open", "l <Right> zo", "open it"},
  {"close", "h <Left> zc", "close it"},
  {"all", "zR", "open every heading"},
  {"none", "zM", "close every heading"},
  {"search", "/", "search as you type; the headings with a match open"},
  {"next", "n", "the next match"},
  {"prev", "N", "the match before"},
  {"follow", "<C-]> K", "follow the link on the cursor's line (choose, when it has several)"},
  {"back", "<C-t> <C-o>", "back to the page the link was followed from"},
  {"forward", "<Tab>", "forward again, to the page gone back from"},
  {"leave", "q <Esc>", "close the overlay"},
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

static const struct action form_actions[] = {
  {"edit", "e <CR>", "edit the field under the cursor"},
  {"drop", "x", "take the field's change back (a form that writes on w)"},
  {"write", "w", "write the changes (a form that writes on w)"},
};

/* hint: the actions the place's hint line shows, separated by spaces */
static const struct {
  const char *name, *title;
  const struct action *actions;
  int n;
  const char *hint;
} own[KC_N] = {
  [KC_PANEL] = {"panel", "IN A PANEL", panel_actions, (int)ARRAY_LEN(panel_actions), ""},
  [KC_LINE] = {"line", "WHILE TYPING", line_actions, (int)ARRAY_LEN(line_actions), ""},
  [KC_PICKER] = {"picker", "IN A PICKER (the line's editing keys work too)", picker_actions, (int)ARRAY_LEN(picker_actions),
                 "accept cancel"},
  [KC_PAGER] = {"pager", "IN AN OVERLAY SUCH AS THIS ONE (any other key closes it)", pager_actions,
                (int)ARRAY_LEN(pager_actions), "toggle search follow back leave"},
  [KC_CONSOLE] = {"console", "IN THE CONSOLE", console_actions, (int)ARRAY_LEN(console_actions),
                  "errors warnings notices everything clear close"},
  [KC_SELECT] = {"select", "SELECTING TEXT IN THE PREVIEW", select_actions, (int)ARRAY_LEN(select_actions),
                 "left down up right mark line copy leave"},
  [KC_FORM] = {"form", "IN A FORM (the edit form, a script's form; a panel's keys too)", form_actions,
               (int)ARRAY_LEN(form_actions), "edit drop write"},
  /* no actions: its keys are keymap.set("preview", ...)'s; here for where it goes */
  [KC_PREVIEW] = {"preview", "THE PREVIEW", NULL, 0, ""},
};

/* Every place: lulibre's (copied from own[] on first use) and those made
 * in Lua after them. The interface thread's. */
struct place {
  char *name, *title;
  struct action *actions; /* the strings are the place's */
  unsigned char *hidden;  /* per action: left out of ? (keymap.set's hidden) */
  int n;
  int *hint, nhint; /* the actions its hint line shows, by number */
  int lua;
  /* a screen's: where its views go (a panel's side: b l m f o t, 0 for
   * the opener's choice) and their size, and whether it is a tab of the bar */
  char side;
  float size;
  int tab;
  struct view_place { /* views of the screen beside its main one */
    char *name, side;
    float size;
  } *views;
  int nviews;
};
static struct place *ctxs;
static int nctxs;

static void set_hint(struct place *pl, int nhint, const char *const *hint) {
  free(pl->hint);
  pl->nhint = 0;
  pl->hint = xcalloc((size_t)nhint + 1, sizeof *pl->hint);
  for (int h = 0; h < nhint; h++)
    for (int a = 0; a < pl->n; a++)
      if (!strcmp(hint[h], pl->actions[a].name)) pl->hint[pl->nhint++] = a + 1;
}

/* lulibre's place c as it comes: its actions, what ? says of them, its hint */
static void own_place(int c) {
  struct place *pl = &ctxs[c];
  pl->name = xstrdup(own[c].name);
  pl->title = xstrdup(own[c].title);
  pl->n = own[c].n;
  pl->actions = xcalloc((size_t)pl->n, sizeof *pl->actions);
  pl->hidden = xcalloc((size_t)pl->n, 1);
  for (int a = 0; a < pl->n; a++)
    pl->actions[a] = (struct action){xstrdup(own[c].actions[a].name), xstrdup(own[c].actions[a].keys),
                                     xstrdup(own[c].actions[a].about)};
  const char *words[32];
  char *list = xstrdup(own[c].hint), *save = NULL;
  int nh = 0;
  for (char *w = strtok_r(list, " ", &save); w && nh < 32; w = strtok_r(NULL, " ", &save)) words[nh++] = w;
  set_hint(pl, nh, words);
  free(list);
}

static void own_places(void) {
  if (nctxs) return;
  ctxs = xcalloc(KC_N, sizeof *ctxs);
  for (int c = 0; c < KC_N; c++) own_place(c);
  nctxs = KC_N;
}

static void place_free(struct place *pl) {
  for (int a = 0; a < pl->n; a++) {
    free((char *)pl->actions[a].name);
    free((char *)pl->actions[a].keys);
    free((char *)pl->actions[a].about);
  }
  free(pl->actions);
  free(pl->hidden);
  free(pl->hint);
  free(pl->name);
  free(pl->title);
  for (int v = 0; v < pl->nviews; v++) free(pl->views[v].name);
  free(pl->views);
  memset(pl, 0, sizeof *pl);
}

int ctx_is_own(const char *name) { /* own[] is constant: any thread */
  for (int c = 0; c < KC_N; c++)
    if (!strcmp(own[c].name, name)) return 1;
  return 0;
}

int ctx_count(void) {
  own_places();
  return nctxs;
}

static struct cbind {
  int ctx, action, nkeys;
  int own; /* bound by keymap.set, not one of the action's defaults */
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

static void ctx_bind_keys(int ctx, const uint32_t *keys, int n, int action, int own) {
  ctx_unbind_keys(ctx, keys, n);
  if (nbinds == capbinds) {
    capbinds = capbinds ? capbinds * 2 : 128;
    binds = xrealloc(binds, (size_t)capbinds * sizeof *binds);
  }
  struct cbind *b = &binds[nbinds++];
  memset(b, 0, sizeof *b);
  b->ctx = ctx;
  b->action = action;
  b->own = own;
  b->nkeys = n;
  memcpy(b->keys, keys, (size_t)n * sizeof *keys);
}

/* place c's keys as its actions name them */
static void bind_defaults(int c) {
  for (int a = 0; a < ctxs[c].n; a++) {
    char *specs = xstrdup(ctxs[c].actions[a].keys), *save = NULL;
    for (char *s = strtok_r(specs, " ", &save); s; s = strtok_r(NULL, " ", &save)) {
      uint32_t keys[KEYSEQ_MAX];
      int n = key_parse(s, keys);
      if (n == 1 || n == 2) ctx_bind_keys(c, keys, n, a + 1, 0);
    }
    free(specs);
  }
}

static void unbind_place(int c) {
  int k = 0;
  for (int i = 0; i < nbinds; i++)
    if (binds[i].ctx != c) binds[k++] = binds[i];
  nbinds = k;
}

void ctx_defaults(void) {
  if (nctxs) /* init.lua says again what it changes in lulibre's places */
    for (int c = 0; c < KC_N; c++) {
      place_free(&ctxs[c]);
      own_place(c);
    }
  own_places();
  nbinds = 0;
  for (int c = 0; c < nctxs; c++) bind_defaults(c);
}

void ctx_free(void) {
  free(binds);
  binds = NULL;
  nbinds = capbinds = 0;
  for (int c = 0; c < nctxs; c++) place_free(&ctxs[c]);
  free(ctxs);
  ctxs = NULL;
  nctxs = 0;
}

int ctx_named(const char *name) {
  own_places();
  for (int c = 0; c < nctxs; c++)
    if (!strcmp(ctxs[c].name, name)) return c;
  return -1;
}

int ctx_add(const char *name, const char *title, int n, const char *const *names, const char *const *keys,
            const char *const *abouts, int nhint, const char *const *hint, char side, float size, int tab,
            char **err) {
  own_places();
  int c = ctx_named(name);
  if (c >= 0 && !ctxs[c].lua) {
    *err = xasprintf("%s is one of lulibre's places: its keys are rebound with keymap.set", name);
    return -1;
  }
  for (int a = 0; a < n; a++)
    for (int b = 0; b < a; b++)
      if (!strcmp(names[a], names[b])) {
        *err = xasprintf("%s has two actions called %s", name, names[a]);
        return -1;
      }
  if (c < 0) {
    ctxs = xrealloc(ctxs, (size_t)(nctxs + 1) * sizeof *ctxs);
    c = nctxs++;
  } else { /* made again: its keys go back to what the new actions say */
    place_free(&ctxs[c]);
    unbind_place(c);
  }
  struct place *pl = &ctxs[c];
  memset(pl, 0, sizeof *pl);
  pl->name = xstrdup(name);
  pl->title = xstrdup(title && *title ? title : name);
  pl->lua = 1;
  pl->side = side;
  pl->size = size;
  pl->tab = tab;
  pl->n = n;
  pl->actions = xcalloc((size_t)n + 1, sizeof *pl->actions);
  pl->hidden = xcalloc((size_t)n + 1, 1);
  for (int a = 0; a < n; a++)
    pl->actions[a] = (struct action){xstrdup(names[a]), xstrdup(keys[a] ? keys[a] : ""), xstrdup(abouts[a] ? abouts[a] : "")};
  set_hint(pl, nhint, hint);
  bind_defaults(c);
  return c;
}

void ctx_add_view(int ctx, const char *name, char side, float size) {
  struct place *pl = &ctxs[ctx];
  pl->views = xrealloc(pl->views, (size_t)(pl->nviews + 1) * sizeof *pl->views);
  pl->views[pl->nviews++] = (struct view_place){xstrdup(name), side, size};
}

int ctx_view(int ctx, const char *name, char *side, float *size) {
  for (int v = 0; ctx >= 0 && ctx < nctxs && v < ctxs[ctx].nviews; v++)
    if (!strcmp(ctxs[ctx].views[v].name, name)) {
      *side = ctxs[ctx].views[v].side;
      *size = ctxs[ctx].views[v].size;
      return 1;
    }
  return 0;
}

int ctx_set(const char *name, const char *title, int nhint, const char *const *hint, char side, float size, char **err) {
  int c = ctx_named(name);
  if (c < 0) {
    *err = xasprintf("no screen or place is called %s", name);
    return -1;
  }
  struct place *pl = &ctxs[c];
  if (side && c < KC_N && c != KC_CONSOLE && c != KC_PREVIEW) {
    *err = xasprintf("%s is no window to place: the console and the preview are", name);
    return -1;
  }
  if (side && c == KC_PREVIEW && !strchr("blt", side)) {
    *err = xasprintf("the preview goes in a band, a column or tiled");
    return -1;
  }
  for (int h = 0; h < nhint; h++) {
    int found = 0;
    for (int a = 0; a < pl->n && !found; a++) found = !strcmp(hint[h], pl->actions[a].name);
    if (!found) {
      *err = xasprintf("%s has no action '%s' for its hint", name, hint[h]);
      return -1;
    }
  }
  if (nhint >= 0) set_hint(pl, nhint, hint);
  if (title) {
    free(pl->title);
    pl->title = xstrdup(*title ? title : name);
  }
  if (side) {
    pl->side = side;
    pl->size = size;
  }
  return 0;
}

void ctx_drop_lua(void) {
  own_places();
  for (int c = KC_N; c < nctxs; c++) place_free(&ctxs[c]);
  nctxs = KC_N;
  int k = 0;
  for (int i = 0; i < nbinds; i++)
    if (binds[i].ctx < KC_N) binds[k++] = binds[i];
  nbinds = k;
}

void ctx_placement(int ctx, char *side, float *size) {
  *side = ctx >= 0 && ctx < nctxs ? ctxs[ctx].side : 0;
  *size = ctx >= 0 && ctx < nctxs ? ctxs[ctx].size : 0;
}

int ctx_tab(int i, const char **name, const char **title) {
  for (int c = 0; c < nctxs; c++)
    if (ctxs[c].tab && i-- == 0) {
      *name = ctxs[c].name;
      *title = ctxs[c].title;
      return c;
    }
  return -1;
}

int ctx_is_tab(int ctx) {
  return ctx >= 0 && ctx < nctxs && ctxs[ctx].tab;
}

const char *ctx_name(int ctx) {
  return ctx >= 0 && ctx < nctxs ? ctxs[ctx].name : NULL;
}

const char *ctx_action_name(int ctx, int action) {
  if (ctx < 0 || ctx >= nctxs || action < 1 || action > ctxs[ctx].n) return NULL;
  return ctxs[ctx].actions[action - 1].name;
}

int ctx_bind(const char *ctx, const char *spec, const char *action, const char *desc, int hidden, char **err) {
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
      struct action *act = &ctxs[c].actions[a];
      ctx_bind_keys(c, keys, n, a + 1, 1);
      if (desc) {
        free((char *)act->about);
        act->about = xstrdup(desc);
      }
      if (hidden >= 0) ctxs[c].hidden[a] = (unsigned char)hidden;
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

static int ctx_key_of(int ctx, int action, sbuf *out);

int ctx_hint_line(int ctx, sbuf *out) {
  return ctx_hint_line_if(ctx, out, NULL, NULL);
}

int ctx_hint_line_if(int ctx, sbuf *out, int (*keep)(int action, const void *ud), const void *ud) {
  if (ctx < 0 || ctx >= nctxs) return 0;
  int n = 0;
  for (int h = 0; h < ctxs[ctx].nhint; h++) {
    sbuf k = SBUF_INIT;
    int a = ctxs[ctx].hint[h];
    if ((!keep || keep(a, ud)) && ctx_key_of(ctx, a, &k)) { /* an action left with no key is not offered */
      sb_printf(out, "%s%s %s", n++ ? "   " : "", k.s, ctxs[ctx].actions[a - 1].name);
    }
    sb_free(&k);
  }
  return n;
}

/* the key a hint shows for an action: the last one keymap.set put on it,
 * else the first of its defaults */
static int ctx_key_of(int ctx, int action, sbuf *out) {
  int pick = -1;
  for (int i = 0; i < nbinds; i++)
    if (binds[i].ctx == ctx && binds[i].action == action && (pick < 0 || binds[i].own)) pick = i;
  if (pick < 0) return 0;
  key_format(out, binds[pick].keys, binds[pick].nkeys);
  return 1;
}

const char *ctx_hint_in(char *buf, size_t size, int ctx, int action) {
  sbuf out = SBUF_INIT;
  if (ctx_key_of(ctx, action, &out)) snprintf(buf, size, "%s", out.s);
  else buf[0] = '\0';
  sb_free(&out);
  return buf;
}

/* One place's actions with the keys they are on, for the help overlay; with
 * names set, the action names too, which is what keymap.set wants. */
void ctx_describe(int ctx, sbuf *out, int names) {
  sb_printf(out, "%s%s%s%s\n", ctxs[ctx].title, names ? "   keymap.set(\"" : "", names ? ctxs[ctx].name : "",
            names ? "\", key, action)" : "");
  for (int a = 0; a < ctxs[ctx].n; a++) {
    if (ctxs[ctx].hidden[a]) continue;
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
