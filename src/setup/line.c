/* Keys, and typing a line on the screen's last row. */
#include <ctype.h>
#include <dirent.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include "core/util.h"
#include "match/fold.h"
#include "setup/setup.h"
#include "tui/tui.h"

uint32_t key_of(const struct ncinput *ni) {
  if (ni->evtype == NCTYPE_RELEASE) return 0;
  uint32_t k = ni->id;
#ifdef NCINPUT_MAX_EFF_TEXT_CODEPOINTS
  /* in the kitty keyboard protocol a shifted key comes with the text it
   * types; the key is what it types (as in keymap.c) */
  uint32_t typed = ni->eff_text[0];
  if (!(ni->modifiers & (NCKEY_MOD_CTRL | NCKEY_MOD_ALT)) && !nckey_synthesized_p(k) && typed >= 0x20 &&
      typed != 0x7f && typed <= 0x10ffff && ni->eff_text[1] == 0)
    k = typed;
#endif
  if (k == '\r' || k == '\n') k = NCKEY_ENTER;
  if (k == 0x7f || k == 0x08) k = NCKEY_BACKSPACE;
  if (ni->modifiers & NCKEY_MOD_CTRL) {
    if (k < 0x80 && isalpha((int)k)) k = (uint32_t)tolower((int)k);
    k |= KEY_CTRL;
  }
  if (ni->modifiers & NCKEY_MOD_ALT) k |= KEY_ALT;
  return k;
}

/* the byte offset of the character before off */
static size_t back(const char *s, size_t off) {
  if (off == 0) return 0;
  off--;
  while (off > 0 && ((unsigned char)s[off] & 0xc0) == 0x80) off--;
  return off;
}

static size_t fwd(const char *s, size_t len, size_t off) {
  if (off >= len) return len;
  off++;
  while (off < len && ((unsigned char)s[off] & 0xc0) == 0x80) off++;
  return off;
}

/* Completes the path that is the whole line: as far as the names that fit
 * agree, and a slash after a folder that is the only one. */
static void complete(sbuf *t, size_t *cur) {
  char *full = path_expand(t->len ? t->s : "");
  char *slash = strrchr(full, '/');
  char *dir = slash ? (slash == full ? xstrdup("/") : xstrndup(full, (size_t)(slash - full))) : xstrdup(".");
  const char *base = slash ? slash + 1 : full;
  size_t blen = strlen(base);
  DIR *d = opendir(dir);
  char *common = NULL;
  int count = 0, last_dir = 0;
  if (d) {
    struct dirent *e;
    while ((e = readdir(d))) {
      if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
      if (e->d_name[0] == '.' && base[0] != '.') continue;
      if (strncmp(e->d_name, base, blen)) continue;
      count++;
      if (!common) {
        common = xstrdup(e->d_name);
      } else {
        size_t k = 0;
        while (common[k] && common[k] == e->d_name[k]) k++;
        common[k] = '\0';
      }
      char *p = xasprintf("%s/%s", dir, e->d_name);
      struct stat st;
      last_dir = stat(p, &st) == 0 && S_ISDIR(st.st_mode);
      free(p);
    }
    closedir(d);
  }
  if (common && strlen(common) > blen) sb_puts(t, common + blen);
  if (count == 1 && last_dir) sb_putc(t, '/');
  if (!t->s) sb_puts(t, "");
  *cur = t->len;
  free(common);
  free(dir);
  free(full);
}

static void draw_line(struct notcurses *nc, const char *prompt, const sbuf *t, size_t cur) {
  struct ncplane *n = notcurses_stdplane(nc);
  unsigned rows, cols;
  ncplane_dim_yx(n, &rows, &cols);
  int y = (int)rows - 1;
  dr_style(n, C_DEFAULT, C_DEFAULT, 0);
  dr_fill(n, y, 0, (int)cols);
  dr_style(n, theme.accent, C_DEFAULT, A_BOLD);
  int x = dr_text(n, y, 0, (int)cols, prompt);
  dr_style(n, C_DEFAULT, C_DEFAULT, 0);
  int room = (int)cols - x - 1;
  if (room < 1) room = 1;
  const char *s = t->s ? t->s : "";
  /* from where the line is shown, so the cursor stays in view */
  size_t start = 0;
  while (start < cur && dr_width(s + start, cur - start) > room - 1) start = fwd(s, t->len, start);
  dr_textn(n, y, x, room, s + start, t->len - start);
  notcurses_cursor_enable(nc, y, x + dr_width(s + start, cur - start));
  notcurses_render(nc);
}

char *line_edit(struct notcurses *nc, const char *prompt, const char *initial, int paths) {
  sbuf t = SBUF_INIT;
  sb_puts(&t, initial ? initial : "");
  size_t cur = t.len;
  char *out = NULL;
  for (;;) {
    draw_line(nc, prompt, &t, cur);
    struct ncinput ni;
    if (notcurses_get_blocking(nc, &ni) == (uint32_t)-1) break;
    uint32_t k = key_of(&ni);
    if (!k) continue;
    if (k == NCKEY_ENTER) {
      out = xstrdup(t.s);
      break;
    }
    if (k == NCKEY_ESC || k == (KEY_CTRL | 'c') || k == (KEY_CTRL | 'g')) break;
    if (k == NCKEY_BACKSPACE || k == (KEY_CTRL | 'h')) {
      size_t b = back(t.s, cur);
      memmove(t.s + b, t.s + cur, t.len - cur + 1);
      t.len -= cur - b;
      cur = b;
    } else if (k == NCKEY_DEL || k == (KEY_CTRL | 'd')) {
      size_t f = fwd(t.s, t.len, cur);
      memmove(t.s + cur, t.s + f, t.len - f + 1);
      t.len -= f - cur;
    } else if (k == NCKEY_LEFT || k == (KEY_CTRL | 'b')) {
      cur = back(t.s, cur);
    } else if (k == NCKEY_RIGHT || k == (KEY_CTRL | 'f')) {
      cur = fwd(t.s, t.len, cur);
    } else if (k == NCKEY_HOME || k == (KEY_CTRL | 'a')) {
      cur = 0;
    } else if (k == NCKEY_END || k == (KEY_CTRL | 'e')) {
      cur = t.len;
    } else if (k == (KEY_CTRL | 'u')) {
      memmove(t.s, t.s + cur, t.len - cur + 1);
      t.len -= cur;
      cur = 0;
    } else if (k == (KEY_CTRL | 'k')) {
      t.s[cur] = '\0';
      t.len = cur;
    } else if (k == (KEY_CTRL | 'w')) {
      size_t b = cur;
      while (b > 0 && (t.s[b - 1] == ' ' || t.s[b - 1] == '/')) b--;
      while (b > 0 && t.s[b - 1] != ' ' && t.s[b - 1] != '/') b--;
      memmove(t.s + b, t.s + cur, t.len - cur + 1);
      t.len -= cur - b;
      cur = b;
    } else if (k == NCKEY_TAB && paths) {
      cur = t.len;
      complete(&t, &cur);
    } else if (!(k & (KEY_CTRL | KEY_ALT)) && !nckey_synthesized_p(k) && k >= 0x20) {
      char enc[8];
      int len = utf8_encode(enc, k);
      sbuf rest = SBUF_INIT;
      sb_puts(&rest, t.s + cur);
      t.len = cur;
      t.s[cur] = '\0';
      sb_putn(&t, enc, (size_t)len);
      sb_puts(&t, rest.s);
      sb_free(&rest);
      cur += (size_t)len;
    }
  }
  notcurses_cursor_disable(nc);
  sb_free(&t);
  return out;
}
