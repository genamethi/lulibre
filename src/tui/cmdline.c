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

/* What a word is, as in vim: a run of letters, digits and underscores (any
 * byte of a character beyond ASCII counts as a letter), or a run of other
 * characters that are not blanks. 0 blank, 1 word, 2 other. */
static int cls(const struct lineedit *le, size_t i) {
  unsigned char c = (unsigned char)le->text.s[i];
  if (c == ' ' || c == '\t') return 0;
  if (c >= 0x80 || c == '_' || (c >= '0' && c <= '9') || ((c | 0x20) >= 'a' && (c | 0x20) <= 'z')) return 1;
  return 2;
}

/* w: past the rest of this word, then past blanks */
static size_t word_right(const struct lineedit *le, size_t i) {
  size_t n = le->text.len;
  if (i < n) {
    int k = cls(le, i);
    if (k) while (i < n && cls(le, i) == k) i++;
  }
  while (i < n && cls(le, i) == 0) i++;
  return i;
}

/* b: back over blanks, then to the start of the word before */
static size_t word_left(const struct lineedit *le, size_t i) {
  while (i > 0 && cls(le, i - 1) == 0) i--;
  if (i > 0) {
    int k = cls(le, i - 1);
    while (i > 0 && cls(le, i - 1) == k) i--;
  }
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
    case LA_WORD_LEFT:
      le->cur = word_left(le, le->cur);
      return 1;
    case LA_WORD_RIGHT:
      le->cur = word_right(le, le->cur);
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
  if (!(key & (KEY_CTRL | KEY_ALT | KEY_SHIFT)) && key >= 0x20 && key <= 0x10ffff) {
    char u[8];
    insert(le, u, (size_t)utf8_encode(u, key));
    return 1;
  }
  (void)ni;
  return 0;
}
