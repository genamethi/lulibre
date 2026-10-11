#include "match/fold.h"

int utf8_decode(const char *s, size_t n, unsigned *cp) {
  const unsigned char *u = (const unsigned char *)s;
  unsigned c = u[0];
  int len = c < 0x80 ? 1 : (c >> 5) == 0x6 ? 2 : (c >> 4) == 0xe ? 3 : (c >> 3) == 0x1e ? 4 : 0;
  if (len == 0 || (size_t)len > n) goto bad;
  if (len == 1) { *cp = c; return 1; }
  c &= 0xff >> (len + 1);
  for (int i = 1; i < len; i++) {
    if ((u[i] & 0xc0) != 0x80) goto bad;
    c = (c << 6) | (u[i] & 0x3f);
  }
  *cp = c;
  return len;
bad:
  *cp = 0xfffd;
  return 1;
}

int utf8_encode(char *out, unsigned cp) {
  if (cp < 0x80) { out[0] = (char)cp; return 1; }
  if (cp < 0x800) {
    out[0] = (char)(0xc0 | (cp >> 6));
    out[1] = (char)(0x80 | (cp & 0x3f));
    return 2;
  }
  if (cp < 0x10000) {
    out[0] = (char)(0xe0 | (cp >> 12));
    out[1] = (char)(0x80 | ((cp >> 6) & 0x3f));
    out[2] = (char)(0x80 | (cp & 0x3f));
    return 3;
  }
  out[0] = (char)(0xf0 | (cp >> 18));
  out[1] = (char)(0x80 | ((cp >> 12) & 0x3f));
  out[2] = (char)(0x80 | ((cp >> 6) & 0x3f));
  out[3] = (char)(0x80 | (cp & 0x3f));
  return 4;
}

/* Base letters for U+00C0..U+00FF, one entry per code point. */
static const char *const latin1[64] = {
  "a", "a", "a", "a", "a", "a", "ae", "c", "e", "e", "e", "e", "i", "i", "i", "i",
  "d", "n", "o", "o", "o", "o", "o", 0,   "o", "u", "u", "u", "u", "y", "th", "ss",
  "a", "a", "a", "a", "a", "a", "ae", "c", "e", "e", "e", "e", "i", "i", "i", "i",
  "d", "n", "o", "o", "o", "o", "o", 0,   "o", "u", "u", "u", "u", "y", "th", "y",
};

/* Latin Extended-A, U+0100..U+017F, as runs sharing a base letter. */
static const struct { unsigned short lo, hi; const char *base; } ext_a[] = {
  {0x100, 0x105, "a"}, {0x106, 0x10d, "c"}, {0x10e, 0x111, "d"}, {0x112, 0x11b, "e"},
  {0x11c, 0x123, "g"}, {0x124, 0x127, "h"}, {0x128, 0x131, "i"}, {0x132, 0x133, "ij"},
  {0x134, 0x135, "j"}, {0x136, 0x138, "k"}, {0x139, 0x142, "l"}, {0x143, 0x14b, "n"},
  {0x14c, 0x151, "o"}, {0x152, 0x153, "oe"}, {0x154, 0x159, "r"}, {0x15a, 0x161, "s"},
  {0x162, 0x167, "t"}, {0x168, 0x173, "u"}, {0x174, 0x175, "w"}, {0x176, 0x178, "y"},
  {0x179, 0x17e, "z"}, {0x17f, 0x17f, "s"},
};

static const char *latin_base(unsigned cp) {
  if (cp >= 0xc0 && cp <= 0xff) return latin1[cp - 0xc0];
  if (cp >= 0x100 && cp <= 0x17f)
    for (size_t i = 0; i < ARRAY_LEN(ext_a); i++)
      if (cp >= ext_a[i].lo && cp <= ext_a[i].hi) return ext_a[i].base;
  return NULL;
}

void fold_utf8(sbuf *out, const char *s, size_t n) {
  size_t i = 0;
  while (i < n) {
    unsigned char c = (unsigned char)s[i];
    if (c < 0x80) {
      sb_putc(out, (char)(c >= 'A' && c <= 'Z' ? c + 32 : c));
      i++;
      continue;
    }
    unsigned cp;
    int len = utf8_decode(s + i, n - i, &cp);
    const char *base = latin_base(cp);
    if (base)
      sb_puts(out, base);
    else if (cp >= 0x300 && cp <= 0x36f)
      ; /* combining mark */
    else
      sb_putn(out, s + i, (size_t)len);
    i += (size_t)len;
  }
  if (!out->s) sb_putn(out, "", 0);
}
