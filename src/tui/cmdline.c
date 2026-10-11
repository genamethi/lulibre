/* A one-line text editor, shared by the ':' and '/' prompts and the picker. */
#include <stdlib.h>
#include <string.h>

#include "match/fold.h"
#include "tui/tui.h"

void le_set(struct lineedit *le, const char *s) {
  sb_reset(&le->text);
  sb_puts(&le->text, s ? s : "");
  le->cur = le->text.len;
}

void le_free(struct lineedit *le) {
  sb_free(&le->text);
  le->cur = 0;
}

static size_t prev_cp(const struct lineedit *le, size_t i) {
  if (i == 0) return 0;
  i--;
  while (i > 0 && ((unsigned char)le->text.s[i] & 0xc0) == 0x80) i--;
  return i;
}

static size_t next_cp(const struct lineedit *le, size_t i) {
  if (i >= le->text.len) return le->text.len;
  i++;
  while (i < le->text.len && ((unsigned char)le->text.s[i] & 0xc0) == 0x80) i++;
  return i;
}

static void erase(struct lineedit *le, size_t from, size_t to) {
  if (from >= to) return;
  memmove(le->text.s + from, le->text.s + to, le->text.len - to + 1);
  le->text.len -= to - from;
  le->cur = from;
}

static void insert(struct lineedit *le, const char *s, size_t n) {
  sb_putn(&le->text, s, n); /* grow, then rotate the new bytes into place */
  char *base = le->text.s;
  memmove(base + le->cur + n, base + le->cur, le->text.len - n - le->cur);
  memcpy(base + le->cur, s, n);
  le->cur += n;
}

void le_insert(struct lineedit *le, const char *s, size_t n) {
  if (!le->text.s) sb_putn(&le->text, "", 0);
  insert(le, s, n);
}

int le_key(struct lineedit *le, uint32_t key, const struct ncinput *ni) {
  if (!le->text.s) sb_putn(&le->text, "", 0);
  switch (ctx_feed(KC_LINE, NULL, key)) {
    case LA_BACKSPACE:
      erase(le, prev_cp(le, le->cur), le->cur);
      return 1;
    case LA_DELETE:
      erase(le, le->cur, next_cp(le, le->cur));
      return 1;
    case LA_LEFT:
      le->cur = prev_cp(le, le->cur);
      return 1;
    case LA_RIGHT:
      le->cur = next_cp(le, le->cur);
      return 1;
    case LA_HOME:
      le->cur = 0;
      return 1;
    case LA_END:
      le->cur = le->text.len;
      return 1;
    case LA_KILL_START:
      erase(le, 0, le->cur);
      return 1;
    case LA_KILL_END:
      erase(le, le->cur, le->text.len);
      return 1;
    case LA_KILL_WORD: {
      size_t i = le->cur;
      while (i > 0 && le->text.s[i - 1] == ' ') i--;
      while (i > 0 && le->text.s[i - 1] != ' ') i--;
      erase(le, i, le->cur);
      return 1;
    }
  }
  /* printable: a real code point with no control or alt modifier */
  if (!(key & (KEY_CTRL | KEY_ALT)) && key >= 0x20 && key <= 0x10ffff) {
    char u[8];
    insert(le, u, (size_t)utf8_encode(u, key));
    return 1;
  }
  (void)ni;
  return 0;
}
