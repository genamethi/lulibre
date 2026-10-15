#include <ctype.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#include "match/fold.h"
#include "tui/tui.h"

static const struct { const char *name; uint32_t key; } named[] = {
  {"Space", ' '},          {"Tab", NCKEY_TAB},       {"Esc", NCKEY_ESC},
  {"CR", NCKEY_ENTER},     {"Enter", NCKEY_ENTER},   {"BS", NCKEY_BACKSPACE},
  {"Up", NCKEY_UP},        {"Down", NCKEY_DOWN},     {"Left", NCKEY_LEFT},
  {"Right", NCKEY_RIGHT},  {"PageUp", NCKEY_PGUP},   {"PageDown", NCKEY_PGDOWN},
  {"Home", NCKEY_HOME},    {"End", NCKEY_END},       {"Del", NCKEY_DEL},
  {"lt", '<'},            {"Leader", KEY_LEADER},
};

uint32_t key_from_input(const struct ncinput *ni) {
  uint32_t k = ni->id;
  if (k == '\r' || k == '\n') k = NCKEY_ENTER;
  if (k == 0x7f) k = NCKEY_BACKSPACE;
  if (ni->modifiers & NCKEY_MOD_CTRL) {
    if (k < 0x80 && isalpha((int)k)) k = (uint32_t)tolower((int)k);
    k |= KEY_CTRL;
  }
  if (ni->modifiers & NCKEY_MOD_ALT) k |= KEY_ALT;
  return k;
}

int key_parse(const char *spec, uint32_t out[KEYSEQ_MAX]) {
  int n = 0;
  size_t len = strlen(spec);
  for (size_t i = 0; i < len;) {
    if (n == KEYSEQ_MAX) return 0;
    const char *close = spec[i] == '<' ? strchr(spec + i, '>') : NULL;
    if (close && close > spec + i + 1) {
      char name[32];
      size_t nl = (size_t)(close - (spec + i + 1));
      if (nl >= sizeof name) return 0;
      memcpy(name, spec + i + 1, nl);
      name[nl] = '\0';
      uint32_t mods = 0;
      const char *p = name;
      while (p[0] && p[1] == '-' && p[2]) {
        if (p[0] == 'C' || p[0] == 'c') mods |= KEY_CTRL;
        else if (p[0] == 'M' || p[0] == 'A' || p[0] == 'm' || p[0] == 'a') mods |= KEY_ALT;
        else return 0;
        p += 2;
      }
      uint32_t key = 0;
      for (size_t k = 0; k < ARRAY_LEN(named); k++)
        if (strcasecmp(named[k].name, p) == 0) key = named[k].key;
      if (!key) {
        unsigned cp;
        int l = utf8_decode(p, strlen(p), &cp);
        if (p[l] != '\0') return 0;
        key = cp;
        if ((mods & KEY_CTRL) && key < 0x80) key = (uint32_t)tolower((int)key);
      }
      out[n++] = key | mods;
      i = (size_t)(close - spec) + 1;
    } else {
      unsigned cp;
      i += (size_t)utf8_decode(spec + i, len - i, &cp);
      out[n++] = cp;
    }
  }
  return n;
}

void key_format(sbuf *out, const uint32_t *keys, int n) {
  for (int i = 0; i < n; i++) {
    if (keys[i] == KEY_LEADER && tui_keymap.leader && tui_keymap.leader != KEY_LEADER) {
      key_format(out, &tui_keymap.leader, 1); /* shown as the key it is */
      continue;
    }
    uint32_t k = keys[i] & ~(KEY_CTRL | KEY_ALT);
    const char *name = NULL;
    for (size_t j = 0; j < ARRAY_LEN(named); j++)
      if (named[j].key == k) { name = named[j].name; break; }
    int mods = (keys[i] & (KEY_CTRL | KEY_ALT)) != 0;
    if (!mods && !name) {
      char u[8];
      sb_putn(out, u, (size_t)utf8_encode(u, k));
      continue;
    }
    sb_putc(out, '<');
    if (keys[i] & KEY_CTRL) sb_puts(out, "C-");
    if (keys[i] & KEY_ALT) sb_puts(out, "M-");
    if (name) {
      sb_puts(out, name);
    } else {
      char u[8];
      sb_putn(out, u, (size_t)utf8_encode(u, k));
    }
    sb_putc(out, '>');
  }
}

int keymap_bind(struct keymap *km, unsigned modes, const char *spec, const char *command) {
  return keymap_bind_as(km, modes, spec, command, NULL, 0);
}

int keymap_bind_as(struct keymap *km, unsigned modes, const char *spec, const char *command, const char *about,
                   int hidden) {
  uint32_t keys[KEYSEQ_MAX];
  int n = key_parse(spec, keys);
  if (!n) return -1;
  for (int i = 0; i < km->n; i++) {
    struct binding *b = &km->b[i];
    if (b->nkeys == n && (b->modes & modes) && !memcmp(b->keys, keys, (size_t)n * sizeof *keys)) {
      b->modes &= ~modes; /* the new binding takes these modes over */
    }
  }
  if (km->n == km->cap) {
    km->cap = km->cap ? km->cap * 2 : 64;
    km->b = xrealloc(km->b, (size_t)km->cap * sizeof *km->b);
  }
  struct binding *b = &km->b[km->n++];
  memset(b, 0, sizeof *b);
  b->modes = modes;
  b->nkeys = n;
  memcpy(b->keys, keys, (size_t)n * sizeof *keys);
  b->command = xstrdup(command);
  b->about = about && *about ? xstrdup(about) : NULL;
  b->hidden = hidden;
  return 0;
}

/* Does what was typed match a binding's keys? A <Leader> in the binding is
 * matched by the leader key. */
static int keys_match(const struct keymap *km, const uint32_t *bound, const uint32_t *typed, int n) {
  for (int i = 0; i < n; i++)
    if (bound[i] != typed[i] && !(bound[i] == KEY_LEADER && km->leader && typed[i] == km->leader)) return 0;
  return 1;
}

void keymap_set_leader(struct keymap *km, const char *spec) {
  uint32_t keys[KEYSEQ_MAX];
  km->leader = spec && key_parse(spec, keys) == 1 && keys[0] != KEY_LEADER ? keys[0] : 0;
}

int keymap_key_of(const struct keymap *km, unsigned mode, const char *command, sbuf *out) {
  for (int i = km->n - 1; i >= 0; i--) { /* the newest binding is the one to show */
    const struct binding *b = &km->b[i];
    if (!(b->modes & mode) || strcmp(b->command, command)) continue;
    key_format(out, b->keys, b->nkeys);
    return 1;
  }
  return 0;
}

const char *key_hint(const char *command) {
  static char ring[4][48];
  static int at;
  char *buf = ring[at++ % 4];
  sbuf out = SBUF_INIT;
  if (keymap_key_of(&tui_keymap, MODE_NORMAL, command, &out)) snprintf(buf, sizeof ring[0], "%s", out.s);
  else snprintf(buf, sizeof ring[0], ":%s", command);
  sb_free(&out);
  return buf;
}

const char *keymap_feed(struct keymap *km, unsigned mode, uint32_t key) {
  for (int attempt = 0; attempt < 2; attempt++) {
    if (km->npending == KEYSEQ_MAX) km->npending = 0;
    km->pending[km->npending++] = key;
    const struct binding *exact = NULL;
    int longer = 0;
    for (int i = 0; i < km->n; i++) {
      const struct binding *b = &km->b[i];
      if (!(b->modes & mode) || b->nkeys < km->npending) continue;
      if (!keys_match(km, b->keys, km->pending, km->npending)) continue;
      if (b->nkeys == km->npending) exact = b;
      else longer = 1;
    }
    if (exact && !longer) {
      km->npending = 0;
      return exact->command;
    }
    if (longer) return NULL; /* wait for the rest of the sequence */
    /* a dead end: drop the prefix and try this key on its own */
    int had_prefix = km->npending > 1;
    km->npending = 0;
    if (!had_prefix) break;
  }
  return NULL;
}

int keymap_starts(const struct keymap *km, unsigned mode, uint32_t key, const char *commands) {
  for (int i = 0; i < km->n; i++) {
    const struct binding *b = &km->b[i];
    if (!(b->modes & mode) || b->nkeys < 1 || !keys_match(km, b->keys, &key, 1)) continue;
    size_t len = strcspn(b->command, " ");
    for (const char *c = commands; *c;) {
      size_t cl = strcspn(c, " ");
      if (cl == len && !strncmp(c, b->command, len)) return 1;
      c += cl;
      while (*c == ' ') c++;
    }
  }
  return 0;
}

void keymap_free(struct keymap *km) {
  for (int i = 0; i < km->n; i++) {
    free(km->b[i].command);
    free(km->b[i].about);
  }
  free(km->b);
  memset(km, 0, sizeof *km);
}

struct keymap tui_keymap;

void keymap_defaults(struct keymap *km) {
  static const struct { unsigned modes; const char *keys, *command; } d[] = {
    /* moving */
    {MODE_NORMAL | MODE_VISUAL, "j", "move +1"},
    {MODE_NORMAL | MODE_VISUAL, "k", "move -1"},
    {MODE_NORMAL | MODE_VISUAL, "<Down>", "move +1"},
    {MODE_NORMAL | MODE_VISUAL, "<Up>", "move -1"},
    {MODE_NORMAL | MODE_VISUAL, "gg", "move top"},
    {MODE_NORMAL | MODE_VISUAL, "G", "move bottom"},
    {MODE_NORMAL | MODE_VISUAL, "<Home>", "move top"},
    {MODE_NORMAL | MODE_VISUAL, "<End>", "move bottom"},
    {MODE_NORMAL | MODE_VISUAL, "<C-d>", "move half-down"},
    {MODE_NORMAL | MODE_VISUAL, "<C-u>", "move half-up"},
    {MODE_NORMAL | MODE_VISUAL, "<C-f>", "move page-down"},
    {MODE_NORMAL | MODE_VISUAL, "<C-b>", "move page-up"},
    {MODE_NORMAL | MODE_VISUAL, "<PageDown>", "move page-down"},
    {MODE_NORMAL | MODE_VISUAL, "<PageUp>", "move page-up"},
    /* finding */
    {MODE_NORMAL | MODE_VISUAL, "/", "prompt search"},
    {MODE_NORMAL | MODE_VISUAL, "n", "search next"},
    {MODE_NORMAL | MODE_VISUAL, "N", "search prev"},
    {MODE_NORMAL, "&", "prompt filter"},
    {MODE_NORMAL, ":", "prompt command"},
    {MODE_NORMAL, "f", "pick books"},
    {MODE_NORMAL, "ga", "pick authors"},
    {MODE_NORMAL, "gs", "pick subjects"},
    {MODE_NORMAL, "gf", "pick filters"},
    {MODE_NORMAL, "<BS>", "filter"},
    /* selecting */
    {MODE_NORMAL, "<CR>", "enter"},
    {MODE_NORMAL, "l", "fold open"},
    {MODE_NORMAL, "<Right>", "fold open"},
    {MODE_NORMAL, "h", "fold close"},
    {MODE_NORMAL, "<Left>", "fold close"},
    {MODE_NORMAL, "za", "fold toggle"},
    {MODE_NORMAL, "zo", "fold open"},
    {MODE_NORMAL, "zc", "fold close"},
    {MODE_NORMAL, "zR", "fold all"},
    {MODE_NORMAL, "zM", "fold none"},
    {MODE_NORMAL, "gh", "pick group"},
    {MODE_NORMAL, "gH", "group none"},
    {MODE_NORMAL, "s", "pick sort"},
    {MODE_NORMAL, "<Space>", "mark toggle"},
    {MODE_NORMAL, "V", "visual"},
    {MODE_VISUAL, "V", "visual"},
    {MODE_VISUAL, "<Space>", "mark toggle"},
    {MODE_VISUAL, "<Esc>", "visual"},
    /* preview */
    {MODE_NORMAL | MODE_VISUAL, "J", "preview scroll +3"},
    {MODE_NORMAL | MODE_VISUAL, "K", "preview scroll -3"},
    {MODE_NORMAL | MODE_VISUAL, "]", "preview page +1"},
    {MODE_NORMAL | MODE_VISUAL, "[", "preview page -1"},
    {MODE_NORMAL | MODE_VISUAL, "P", "preview graphic"},
    {MODE_NORMAL, "v", "preview select"},
    {MODE_NORMAL, "a", "preview add"},
    {MODE_NORMAL | MODE_VISUAL, "+", "preview zoom +1"},
    {MODE_NORMAL | MODE_VISUAL, "-", "preview zoom -1"},
    {MODE_NORMAL | MODE_VISUAL, "=", "preview zoom 0"},
    {MODE_NORMAL | MODE_VISUAL, "H", "preview pan -6"},
    {MODE_NORMAL | MODE_VISUAL, "L", "preview pan +6"},
    /* windows */
    {MODE_NORMAL, "<Tab>", "focus next"},
    {MODE_NORMAL, "<C-w>w", "focus next"},
    {MODE_NORMAL, "<C-w>h", "focus h"},
    {MODE_NORMAL, "<C-w>j", "focus j"},
    {MODE_NORMAL, "<C-w>k", "focus k"},
    {MODE_NORMAL, "<C-w>l", "focus l"},
    {MODE_NORMAL, "<C-w>v", "split v preview"},
    {MODE_NORMAL, "<C-w>s", "split h preview"},
    {MODE_NORMAL, "<C-w>c", "close"},
    {MODE_NORMAL, "<C-w>o", "only"},
    {MODE_NORMAL, "<C-w>>", "resize +1"},
    {MODE_NORMAL, "<C-w><lt>", "resize -1"},
    {MODE_NORMAL, "<M-Left>", "resize left"},
    {MODE_NORMAL, "<M-Right>", "resize right"},
    {MODE_NORMAL, "<M-Up>", "resize up"},
    {MODE_NORMAL, "<M-Down>", "resize down"},
    {MODE_NORMAL, "<Leader><Left>", "resize left"},
    {MODE_NORMAL, "<Leader><Right>", "resize right"},
    {MODE_NORMAL, "<Leader><Up>", "resize up"},
    {MODE_NORMAL, "<Leader><Down>", "resize down"},
    /* changing things (these commands are defined in lua/lulibre/prelude.lua) */
    {MODE_NORMAL | MODE_VISUAL, "e", "edit"},
    {MODE_NORMAL | MODE_VISUAL, "gc", "capture"},
    {MODE_NORMAL | MODE_VISUAL, "gT", "titlecase"},
    {MODE_NORMAL | MODE_VISUAL, "gp", "propose"},
    {MODE_NORMAL | MODE_VISUAL, "<Leader>pr", "propose-review"},
    {MODE_NORMAL, "<Leader>w", "weights"},
    {MODE_NORMAL | MODE_VISUAL, "<Leader>e", "enrich-dialog"},
    {MODE_NORMAL | MODE_VISUAL, "<Leader>c", "change"},
    {MODE_NORMAL, "<Leader>d", "datasets-dialog"},
    {MODE_NORMAL | MODE_VISUAL, "<Leader>s", "sync-dialog"},
    {MODE_NORMAL, "<Leader><Space>", "mark none"},
    {MODE_NORMAL, "gr", "review"},
    {MODE_NORMAL | MODE_VISUAL, "r", "review selection"},
    {MODE_NORMAL, "gt", "browse"},
    {MODE_NORMAL, "gd", "dupes"},
    {MODE_NORMAL, "go", "orphans"},
    {MODE_NORMAL, "gk", "good"},
    {MODE_NORMAL, "gz", "snapshots"},
    {MODE_NORMAL, "gC", "config"},
    /* the sync folder (lua/lulibre/sync.lua) */
    {MODE_NORMAL, "gS", "sync"},
    {MODE_NORMAL, "gb", "beside"},
    {MODE_NORMAL, "1", "source library"},
    {MODE_NORMAL, "2", "sync"},
    {MODE_NORMAL, "gl", "source library"},
    {MODE_NORMAL | MODE_VISUAL, "S", "sync add"},
    {MODE_NORMAL | MODE_VISUAL, "X", "sync move"},
    {MODE_NORMAL | MODE_VISUAL, "D", "sync drop"},
    {MODE_NORMAL, "u", "undo"},
    {MODE_NORMAL | MODE_VISUAL, "yb", "yank bib"},
    {MODE_NORMAL | MODE_VISUAL, "yk", "yank key"},
    {MODE_NORMAL | MODE_VISUAL, "yp", "yank path"},
    {MODE_NORMAL | MODE_VISUAL, "yy", "yank title"},
    /* misc */
    {MODE_NORMAL, "R", "reload"},
    {MODE_NORMAL, "<Leader>R", "reload-cfg"},
    {MODE_NORMAL, "?", "help"},
    {MODE_NORMAL, "`", "console"},
    {MODE_NORMAL, "q", "quit"},
    {MODE_NORMAL, "ZZ", "quit"},
  };
  for (size_t i = 0; i < ARRAY_LEN(d); i++) keymap_bind(km, d[i].modes, d[i].keys, d[i].command);
}
