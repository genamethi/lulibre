#include "match/similar.h"

#include <ctype.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#include "db/db.h"
#include "match/fold.h"

/* ---- tokens ---- */

struct tokens {
  char **t;
  int n, cap;
};

static void add(struct tokens *ts, const char *s, size_t n) {
  if (!n) return;
  if (ts->n == ts->cap) {
    ts->cap = ts->cap ? ts->cap * 2 : 16;
    ts->t = xrealloc(ts->t, (size_t)ts->cap * sizeof *ts->t);
  }
  ts->t[ts->n++] = xstrndup(s, n);
}

static void tokens_free(struct tokens *ts) {
  for (int i = 0; i < ts->n; i++) free(ts->t[i]);
  free(ts->t);
  memset(ts, 0, sizeof *ts);
}

/* A letter or digit, after folding: ASCII ones, and any other script. */
static int word_char(unsigned char c) {
  return isalnum(c) || c >= 0x80;
}

/* The folded words of s. */
static void words(const char *s, struct tokens *ts) {
  sbuf f = SBUF_INIT;
  fold_utf8(&f, s, strlen(s));
  const char *p = f.s ? f.s : "";
  while (*p) {
    while (*p && !word_char((unsigned char)*p)) p++;
    const char *start = p;
    while (*p && word_char((unsigned char)*p)) p++;
    add(ts, start, (size_t)(p - start));
  }
  sb_free(&f);
}

/* Tags, comma-separated, and each tag's broader terms: "math.nt.additive"
 * is math, math.nt and math.nt.additive: calibre's levels. */
static void tags(const char *s, struct tokens *ts) {
  sbuf f = SBUF_INIT;
  fold_utf8(&f, s, strlen(s));
  char empty[1] = "", *save = NULL;
  for (char *tag = strtok_r(f.s ? f.s : empty, ",", &save); tag; tag = strtok_r(NULL, ",", &save)) {
    while (*tag == ' ') tag++;
    size_t n = strlen(tag);
    while (n && tag[n - 1] == ' ') n--;
    for (size_t i = 0; i < n; i++)
      if (tag[i] == '.') add(ts, tag, i);
    add(ts, tag, n);
  }
  sb_free(&f);
}

static void tokenize(enum field_kind kind, const char *s, struct tokens *ts) {
  if (kind == KIND_TAGS) tags(s, ts);
  else words(s, ts); /* KIND_PEOPLE: the name parts of every person */
}

/* ---- a value's words in a text ---- */

static int token_cmp(const void *a, const void *b) {
  return strcmp(*(char *const *)a, *(char *const *)b);
}

/* The text's words sorted: a word broken at a line's end is joined first. */
static void text_words(const char *text, struct tokens *ts) {
  sbuf f = SBUF_INIT;
  fold_utf8(&f, text, strlen(text));
  char *p = f.s ? f.s : (char[]){0}, *o = p;
  for (const char *r = p; *r; r++) {
    if (r[0] == '-' && r[1] == '\n' && r > p && word_char((unsigned char)r[-1]) && word_char((unsigned char)r[2])) r++;
    else *o++ = *r;
  }
  *o = 0;
  for (const char *w = p; *w;) {
    while (*w && !word_char((unsigned char)*w)) w++;
    const char *start = w;
    while (*w && word_char((unsigned char)*w)) w++;
    add(ts, start, (size_t)(w - start));
  }
  sb_free(&f);
  if (ts->n) qsort(ts->t, (size_t)ts->n, sizeof *ts->t, token_cmp);
}

void words_found(const char *value, const char *text, int (*skip)(const char *word, void *ud), void *ud,
                 int *found, int *nwords) {
  struct tokens v = {0}, t = {0};
  words(value, &v);
  text_words(text, &t);
  *found = *nwords = 0;
  for (int i = 0; i < v.n; i++) {
    if (skip && skip(v.t[i], ud)) continue;
    ++*nwords;
    if (t.n && bsearch(&v.t[i], t.t, (size_t)t.n, sizeof *t.t, token_cmp)) ++*found;
  }
  tokens_free(&v);
  tokens_free(&t);
}

/* ---- rarity: inverse document frequency, per kind ---- */

struct slot {
  char *token;
  int df;
};

struct table {
  struct slot *s;
  size_t cap, n;
  int docs;
};

struct rarity {
  struct table k[KIND_TAGS + 1];
};

static struct slot *find(struct table *t, const char *token) {
  size_t i = hash_fnv1a(token) & (t->cap - 1);
  while (t->s[i].token && strcmp(t->s[i].token, token)) i = (i + 1) & (t->cap - 1);
  return &t->s[i];
}

static void grow(struct table *t) {
  struct table old = *t;
  t->cap = old.cap ? old.cap * 2 : 1024;
  t->s = xcalloc(t->cap, sizeof *t->s);
  for (size_t i = 0; i < old.cap; i++)
    if (old.s[i].token) *find(t, old.s[i].token) = old.s[i];
  free(old.s);
}

/* Counts each distinct token of one record's value once. */
static void count(struct table *t, enum field_kind kind, const char *value) {
  struct tokens ts = {0};
  tokenize(kind, value, &ts);
  t->docs++;
  for (int i = 0; i < ts.n; i++) {
    int seen = 0;
    for (int j = 0; j < i && !seen; j++) seen = !strcmp(ts.t[i], ts.t[j]);
    if (seen) continue;
    if ((t->n + 1) * 2 > t->cap) grow(t);
    struct slot *s = find(t, ts.t[i]);
    if (!s->token) {
      s->token = xstrdup(ts.t[i]);
      t->n++;
    }
    s->df++;
  }
  tokens_free(&ts);
}

struct rarity *rarity_build(struct db *db, char **err) {
  static const struct { enum field_kind kind; const char *sql; } src[] = {
    {KIND_TEXT, "SELECT title FROM books UNION ALL SELECT series FROM books UNION ALL SELECT publisher FROM books"},
    {KIND_PEOPLE, "SELECT authors FROM books"},
    {KIND_TAGS, "SELECT tags FROM books"},
  };
  struct rarity *w = xcalloc(1, sizeof *w);
  for (size_t i = 0; i < ARRAY_LEN(src); i++) {
    struct table *t = &w->k[src[i].kind];
    grow(t);
    sqlite3_stmt *st;
    if (db_prepare(db, src[i].sql, &st, err)) {
      rarity_free(w);
      return NULL;
    }
    while (sqlite3_step(st) == SQLITE_ROW) {
      const char *v = (const char *)sqlite3_column_text(st, 0);
      if (v && *v) count(t, src[i].kind, v);
    }
    sqlite3_finalize(st);
  }
  return w;
}

void rarity_free(struct rarity *w) {
  if (!w) return;
  for (int k = 0; k <= KIND_TAGS; k++) {
    for (size_t i = 0; i < w->k[k].cap; i++) free(w->k[k].s[i].token);
    free(w->k[k].s);
  }
  free(w);
}

/* A token's weight: log((N + 1) / (df + 1)) + 1, so a token no record has
 * weighs most, and with no rarity every token weighs 1. */
static double weight(const struct rarity *w, enum field_kind kind, const char *token) {
  if (!w || kind > KIND_TAGS) return 1;
  struct table *t = (struct table *)&w->k[kind];
  if (!t->cap) return 1;
  struct slot *s = find(t, token);
  int df = s->token ? s->df : 0;
  return log((t->docs + 1.0) / (df + 1.0)) + 1;
}

/* ---- likeness of two tokens ---- */

static int code_points(const char *s, unsigned *out, int max) {
  int n = 0;
  size_t len = strlen(s);
  for (size_t i = 0; i < len && n < max;) {
    i += (size_t)utf8_decode(s + i, len - i, &out[n]);
    n++;
  }
  return n;
}

/* 1 - edit distance / the longer length, over code points. */
static double token_like(const char *a, const char *b) {
  enum { MAX = 64 };
  unsigned x[MAX], y[MAX];
  int n = code_points(a, x, MAX), m = code_points(b, y, MAX);
  if (!n && !m) return 1;
  int prev[MAX + 1], cur[MAX + 1];
  for (int j = 0; j <= m; j++) prev[j] = j;
  for (int i = 1; i <= n; i++) {
    cur[0] = i;
    for (int j = 1; j <= m; j++) {
      int sub = prev[j - 1] + (x[i - 1] != y[j - 1]);
      int del = prev[j] + 1, ins = cur[j - 1] + 1;
      cur[j] = sub < del ? (sub < ins ? sub : ins) : (del < ins ? del : ins);
    }
    memcpy(prev, cur, sizeof(int) * (size_t)(m + 1));
  }
  return 1.0 - (double)prev[m] / (n > m ? n : m);
}

/* A name part against another: an initial matches a part with its letter. */
static double part_like(const char *a, const char *b) {
  if (strlen(a) == 1 || strlen(b) == 1) return a[0] == b[0] ? 1 : 0;
  return token_like(a, b);
}

/* ---- dates: intervals ---- */

/* Days from the epoch of y-m-d (proleptic Gregorian). */
static long days(int y, int m, int d) {
  y -= m <= 2;
  long era = (y >= 0 ? y : y - 399) / 400;
  long yoe = y - era * 400;
  long doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
  long doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
  return era * 146097 + doe;
}

/* "1942" is the whole year, "1942-05" the month, "1942-05-03" the day:
 * [*lo, *hi), in days. 0, or -1 when s is no date. */
static int interval(const char *s, long *lo, long *hi) {
  int y = 0, m = 0, d = 0;
  int got = sscanf(s, "%d-%d-%d", &y, &m, &d);
  if (got < 1 || y < 1) return -1;
  if (got == 1) {
    *lo = days(y, 1, 1);
    *hi = days(y + 1, 1, 1);
  } else if (got == 2) {
    *lo = days(y, m, 1);
    *hi = m == 12 ? days(y + 1, 1, 1) : days(y, m + 1, 1);
  } else {
    *lo = days(y, m, d);
    *hi = *lo + 1;
  }
  return 0;
}

/* The share of a's interval that b's covers. */
static double date_like(const char *a, const char *b) {
  long alo, ahi, blo, bhi;
  if (interval(a, &alo, &ahi) || interval(b, &blo, &bhi)) return 0;
  long lo = alo > blo ? alo : blo, hi = ahi < bhi ? ahi : bhi;
  return hi > lo ? (double)(hi - lo) / (double)(ahi - alo) : 0;
}

/* ---- identifiers ---- */

static int isbn13_check(const char *d12) {
  int sum = 0;
  for (int i = 0; i < 12; i++) sum += (d12[i] - '0') * (i % 2 ? 3 : 1);
  return (10 - sum % 10) % 10;
}

int ident_canonical(const char *type, const char *value, sbuf *out) {
  char digits[16];
  int n = 0;
  if (!strcasecmp(type, "isbn")) {
    for (const char *p = value; *p && n < 14; p++)
      if (isdigit((unsigned char)*p) || ((*p == 'x' || *p == 'X') && n == 9)) digits[n++] = (char)toupper(*p);
    digits[n] = '\0';
    if (n == 10) {
      char d[14] = "978";
      memcpy(d + 3, digits, 9);
      d[12] = (char)('0' + isbn13_check(d));
      d[13] = '\0';
      sb_puts(out, d);
      return 0;
    }
    if (n == 13) {
      sb_puts(out, digits);
      return 0;
    }
    return -1;
  }
  sbuf v = SBUF_INIT;
  for (const char *p = value; *p; p++) sb_putc(&v, (char)tolower((unsigned char)*p));
  const char *s = v.s ? v.s : "";
  while (*s == ' ') s++;
  if (!strcasecmp(type, "doi")) {
    static const char *const prefixes[] = {"https://doi.org/", "http://doi.org/", "https://dx.doi.org/",
                                           "http://dx.doi.org/", "doi:"};
    for (size_t i = 0; i < ARRAY_LEN(prefixes); i++)
      if (!strncmp(s, prefixes[i], strlen(prefixes[i]))) s += strlen(prefixes[i]);
    int ok = !strncmp(s, "10.", 3);
    if (ok) sb_puts(out, s);
    sb_free(&v);
    return ok ? 0 : -1;
  }
  if (!strcasecmp(type, "arxiv")) {
    if (!strncmp(s, "arxiv:", 6)) s += 6;
    size_t len = strlen(s);
    const char *ver = strrchr(s, 'v');
    if (ver && ver > s && isdigit((unsigned char)ver[-1]) && ver[1] && strspn(ver + 1, "0123456789") == strlen(ver + 1))
      len = (size_t)(ver - s);
    sb_putn(out, s, len);
    sb_free(&v);
    return len ? 0 : -1;
  }
  sb_puts(out, s);
  sb_free(&v);
  return *s ? 0 : -1;
}

/* "type:value" against "type:value": canonical forms equal. */
static double ident_like(const char *a, const char *b) {
  const char *ca = strchr(a, ':'), *cb = strchr(b, ':');
  if (!ca || !cb || ca - a != cb - b || strncasecmp(a, b, (size_t)(ca - a))) return 0;
  char *type = xstrndup(a, (size_t)(ca - a));
  sbuf x = SBUF_INIT, y = SBUF_INIT;
  int ok = ident_canonical(type, ca + 1, &x) == 0 && ident_canonical(type, cb + 1, &y) == 0 && !strcmp(x.s, y.s);
  free(type);
  sb_free(&x);
  sb_free(&y);
  return ok;
}

/* ---- the measure ---- */

double similar(const struct rarity *w, enum field_kind kind, const char *a, const char *b) {
  if (!a || !b) return 0;
  if (kind == KIND_DATE) return date_like(a, b);
  if (kind == KIND_IDENT) return ident_like(a, b);
  struct tokens ta = {0}, tb = {0};
  tokenize(kind, a, &ta);
  tokenize(kind, b, &tb);
  double sum = 0, total = 0;
  for (int i = 0; i < ta.n; i++) {
    double best = 0;
    for (int j = 0; j < tb.n && best < 1; j++) {
      double s = kind == KIND_PEOPLE ? part_like(ta.t[i], tb.t[j]) : token_like(ta.t[i], tb.t[j]);
      if (s > best) best = s;
    }
    double wt = weight(w, kind, ta.t[i]);
    sum += wt * best;
    total += wt;
  }
  tokens_free(&ta);
  tokens_free(&tb);
  return total > 0 ? sum / total : 0;
}

enum likeness likeness(double ab, double ba, double near, double same) {
  if (ab >= same && ba >= same) return LIKE_EQUAL;
  if (ab >= same || ba >= same) return LIKE_CONTAINS;
  if (ab >= near && ba >= near) return LIKE_NEAR;
  return LIKE_DIFFERS;
}
