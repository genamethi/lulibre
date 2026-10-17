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

/* Mathematics written in Unicode, as its plain letters, so that "SL2" finds
 * "SL₂(ℤ)": superscripts and subscripts, the letterlike symbols (ℤ, ℓ) and the
 * mathematical alphabets (𝔽, 𝐱). Returns the folded letter, or 0. */
static const struct { unsigned short cp; char to; } scripts[] = {
  {0x00b2, '2'}, {0x00b3, '3'}, {0x00b9, '1'}, {0x2070, '0'}, {0x2071, 'i'}, {0x207a, '+'},
  {0x207b, '-'}, {0x207c, '='}, {0x207d, '('}, {0x207e, ')'}, {0x207f, 'n'}, {0x208a, '+'},
  {0x208b, '-'}, {0x208c, '='}, {0x208d, '('}, {0x208e, ')'}, {0x2090, 'a'}, {0x2091, 'e'},
  {0x2092, 'o'}, {0x2093, 'x'}, {0x2095, 'h'}, {0x2096, 'k'}, {0x2097, 'l'}, {0x2098, 'm'},
  {0x2099, 'n'}, {0x209a, 'p'}, {0x209b, 's'}, {0x209c, 't'}, {0x1d62, 'i'}, {0x1d63, 'r'},
  {0x1d64, 'u'}, {0x1d65, 'v'}, {0x2c7c, 'j'}, {0x1d43, 'a'}, {0x1d47, 'b'}, {0x1d9c, 'c'},
  {0x1d48, 'd'}, {0x1d49, 'e'}, {0x1da0, 'f'}, {0x1d4d, 'g'}, {0x02b0, 'h'}, {0x02b2, 'j'},
  {0x1d4f, 'k'}, {0x02e1, 'l'}, {0x1d50, 'm'}, {0x1d52, 'o'}, {0x1d56, 'p'}, {0x02b3, 'r'},
  {0x02e2, 's'}, {0x1d57, 't'}, {0x1d58, 'u'}, {0x1d5b, 'v'}, {0x02b7, 'w'}, {0x02e3, 'x'},
  {0x02b8, 'y'}, {0x1dbb, 'z'}, {0x1d2c, 'a'}, {0x1d2e, 'b'}, {0x1d30, 'd'}, {0x1d31, 'e'},
  {0x1d33, 'g'}, {0x1d34, 'h'}, {0x1d35, 'i'}, {0x1d36, 'j'}, {0x1d37, 'k'}, {0x1d38, 'l'},
  {0x1d39, 'm'}, {0x1d3a, 'n'}, {0x1d3c, 'o'}, {0x1d3e, 'p'}, {0x1d3f, 'r'}, {0x1d40, 't'},
  {0x1d41, 'u'}, {0x2c7d, 'v'}, {0x1d42, 'w'}, {0x2102, 'c'}, {0x210a, 'g'}, {0x210b, 'h'},
  {0x210c, 'h'}, {0x210d, 'h'}, {0x2110, 'i'}, {0x2111, 'i'}, {0x2112, 'l'}, {0x2113, 'l'},
  {0x2115, 'n'}, {0x2119, 'p'}, {0x211a, 'q'}, {0x211b, 'r'}, {0x211c, 'r'}, {0x211d, 'r'},
  {0x2124, 'z'}, {0x2128, 'z'}, {0x212c, 'b'}, {0x212d, 'c'}, {0x212f, 'e'}, {0x2130, 'e'},
  {0x2131, 'f'}, {0x2133, 'm'}, {0x2134, 'o'}, {0x2145, 'd'}, {0x2146, 'd'}, {0x2147, 'e'},
  {0x2148, 'i'}, {0x2149, 'j'}, {0x2212, '-'},
};

static char math_letter(unsigned cp) {
  if (cp >= 0x1d400 && cp <= 0x1d6a3) {
    unsigned i = (cp - 0x1d400) % 52;
    return (char)(i < 26 ? 'a' + i : 'a' + i - 26);
  }
  if (cp >= 0x1d7ce && cp <= 0x1d7ff) return (char)('0' + (cp - 0x1d7ce) % 10);
  if (cp >= 0x2074 && cp <= 0x2079) return (char)('4' + (cp - 0x2074));
  if (cp >= 0x2080 && cp <= 0x2089) return (char)('0' + (cp - 0x2080));
  for (size_t i = 0; i < ARRAY_LEN(scripts); i++)
    if (scripts[i].cp == cp) return scripts[i].to;
  return 0;
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
    char letter = base ? 0 : math_letter(cp);
    if (letter)
      sb_putc(out, letter);
    else if (base)
      sb_puts(out, base);
    else if (cp >= 0x300 && cp <= 0x36f)
      ; /* combining mark */
    else
      sb_putn(out, s + i, (size_t)len);
    i += (size_t)len;
  }
  if (!out->s) sb_putn(out, "", 0);
}
