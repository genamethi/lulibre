#include <string.h>
#include <wchar.h>

#include "match/fold.h"
#include "tui/tui.h"

/* A restrained palette for dark terminals; everything else is the terminal's
 * own foreground and background. */
struct theme theme = {
  .dim = 0x7a8194,
  .accent = 0x7aa2f7,
  .warn = 0xe0af68,
  .error = 0xf7768e,
  .ok = 0x9ece6a,
  .cursor_bg = 0x2a3a66,
  .cursor_bg_blur = 0x242838,
  .visual_bg = 0x3b2f5a,
  .mark = 0xe0af68,
  .title = 0xc0caf5,
  .border = 0x7982a9,
  .bar_bg = 0x343a55,
  .bar_fg = 0xc0caf5,
  .on_accent = 0x1a1b26,
};

static const struct { const char *name; int *slot; } theme_slots[] = {
  {"dim", &theme.dim},             {"accent", &theme.accent},
  {"warn", &theme.warn},           {"error", &theme.error},
  {"ok", &theme.ok},               {"cursor_bg", &theme.cursor_bg},
  {"cursor_bg_blur", &theme.cursor_bg_blur}, {"visual_bg", &theme.visual_bg},
  {"mark", &theme.mark},           {"title", &theme.title},
  {"border", &theme.border},       {"bar_bg", &theme.bar_bg},
  {"bar_fg", &theme.bar_fg},       {"on_accent", &theme.on_accent},
};

int *theme_slot(const char *name) {
  for (size_t i = 0; i < sizeof theme_slots / sizeof theme_slots[0]; i++)
    if (!strcmp(theme_slots[i].name, name)) return theme_slots[i].slot;
  return NULL;
}

const char *theme_name(int i) {
  return i >= 0 && (size_t)i < sizeof theme_slots / sizeof theme_slots[0] ? theme_slots[i].name : NULL;
}

void dr_style(struct ncplane *n, int fg, int bg, unsigned attrs) {
  if (fg == C_DEFAULT) ncplane_set_fg_default(n);
  else ncplane_set_fg_rgb(n, (uint32_t)fg);
  if (bg == C_DEFAULT) ncplane_set_bg_default(n);
  else ncplane_set_bg_rgb(n, (uint32_t)bg);
  unsigned s = 0;
  if (attrs & A_BOLD) s |= NCSTYLE_BOLD;
  if (attrs & A_ITALIC) s |= NCSTYLE_ITALIC;
  if (attrs & A_UNDERLINE) s |= NCSTYLE_UNDERLINE;
  ncplane_set_styles(n, s);
}

void dr_fill(struct ncplane *n, int y, int x, int w) {
  static const char spaces[] =
    "                                                                ";
  while (w > 0) {
    int k = w < (int)sizeof spaces - 1 ? w : (int)sizeof spaces - 1;
    ncplane_putnstr_yx(n, y, x, (size_t)k, spaces);
    x += k;
    w -= k;
  }
}

void dr_frame(struct ncplane *n, struct rect r, int bg) {
  for (int y = 0; y < r.h; y++) {
    dr_style(n, C_DEFAULT, bg, 0);
    dr_fill(n, r.y + y, r.x, r.w);
  }
  if (r.w < 2 || r.h < 2) return;
  dr_style(n, theme.border, bg, 0);
  for (int c = 1; c < r.w - 1; c++) {
    ncplane_putstr_yx(n, r.y, r.x + c, "─");
    ncplane_putstr_yx(n, r.y + r.h - 1, r.x + c, "─");
  }
  for (int y = 1; y < r.h - 1; y++) {
    ncplane_putstr_yx(n, r.y + y, r.x, "│");
    ncplane_putstr_yx(n, r.y + y, r.x + r.w - 1, "│");
  }
  ncplane_putstr_yx(n, r.y, r.x, "╭");
  ncplane_putstr_yx(n, r.y, r.x + r.w - 1, "╮");
  ncplane_putstr_yx(n, r.y + r.h - 1, r.x, "╰");
  ncplane_putstr_yx(n, r.y + r.h - 1, r.x + r.w - 1, "╯");
}

void dr_bar(struct ncplane *n, struct rect r, int focused) {
  dr_style(n, focused ? theme.on_accent : theme.bar_fg, focused ? theme.accent : theme.bar_bg, A_BOLD);
  dr_fill(n, r.y, r.x, r.w);
}

static int cp_width(unsigned *cp) {
  if (*cp < 0x20 || *cp == 0x7f) *cp = ' ';
  int w = wcwidth((wchar_t)*cp);
  if (w < 0) {
    *cp = 0xfffd;
    w = 1;
  }
  return w;
}

int dr_width(const char *s, size_t len) {
  int cols = 0;
  for (size_t i = 0; i < len;) {
    unsigned cp;
    i += (size_t)utf8_decode(s + i, len - i, &cp);
    cols += cp_width(&cp);
  }
  return cols;
}

size_t dr_bytes_for_cols(const char *s, size_t len, int cols) {
  size_t i = 0;
  int used = 0;
  while (i < len) {
    unsigned cp;
    int k = utf8_decode(s + i, len - i, &cp);
    int w = cp_width(&cp);
    if (used + w > cols) break;
    used += w;
    i += (size_t)k;
  }
  return i;
}

int dr_textn(struct ncplane *n, int y, int x, int maxw, const char *s, size_t len) {
  if (maxw <= 0 || !s) return 0;
  char buf[1024];
  size_t o = 0, o_cut = 0;
  int cols = 0, cols_cut = 0, truncated = 0;
  for (size_t i = 0; i < len;) {
    unsigned cp;
    int l = utf8_decode(s + i, len - i, &cp);
    int w = cp_width(&cp);
    if (cols + w > maxw || o + 8 >= sizeof buf) {
      truncated = 1;
      break;
    }
    o += (size_t)utf8_encode(buf + o, cp);
    cols += w;
    if (cols <= maxw - 1) { /* room left for an ellipsis after this point */
      o_cut = o;
      cols_cut = cols;
    }
    i += (size_t)l;
  }
  if (truncated) {
    o = o_cut;
    cols = cols_cut;
    o += (size_t)utf8_encode(buf + o, 0x2026);
    cols++;
  }
  buf[o] = '\0';
  if (o) ncplane_putstr_yx(n, y, x, buf);
  return cols;
}

int dr_text(struct ncplane *n, int y, int x, int maxw, const char *s) {
  return s ? dr_textn(n, y, x, maxw, s, strlen(s)) : 0;
}

size_t dr_wrap(const char *s, size_t len, int maxw) {
  if (maxw < 1) maxw = 1;
  int cols = 0;
  size_t i = 0, last_space = 0;
  while (i < len) {
    unsigned cp;
    int l = utf8_decode(s + i, len - i, &cp);
    int w = cp_width(&cp);
    if (cols + w > maxw) {
      if (last_space) return last_space;
      return i ? i : (size_t)l;
    }
    if (cp == ' ') last_space = i + 1;
    cols += w;
    i += (size_t)l;
  }
  return len;
}

int dr_lines(const char *s, int maxw, size_t *off, size_t *len, int max) {
  int n = 0;
  size_t end = strlen(s), i = 0;
  while (end > 0 && s[end - 1] == '\n') end--;
  for (;;) {
    const char *nl = memchr(s + i, '\n', end - i);
    size_t para = nl ? (size_t)(nl - s) : end;
    do {
      size_t k = dr_wrap(s + i, para - i, maxw), shown = k;
      /* a line broken at a space doesn't show the space */
      if (i + k < para)
        while (shown > 0 && s[i + shown - 1] == ' ') shown--;
      if (n < max) {
        off[n] = i;
        len[n] = shown;
      }
      n++;
      i += k;
      while (i < para && s[i] == ' ') i++; /* a wrapped line starts at a word */
    } while (i < para);
    if (!nl) return n;
    i = para + 1;
  }
}
