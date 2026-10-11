/* The scoring model is fzy's: a dynamic program over (query char, candidate
 * char) that rewards consecutive matches and matches at word starts, and
 * charges a little for each skipped character. */
#include "match/fuzzy.h"

#include <string.h>

#define MAX_HAY 512
#define MAX_NEEDLE 64

#define GAP_LEADING (-0.005)
#define GAP_TRAILING (-0.005)
#define GAP_INNER (-0.01)
#define MATCH_CONSECUTIVE 1.0
#define MATCH_WORD 0.8
#define MATCH_SEP 0.9 /* after '/', the start of a path or subject component */
#define MATCH_DOT 0.6

static int is_subsequence(const char *needle, int m, const char *hay, int n) {
  int i = 0;
  for (int j = 0; j < n && i < m; j++)
    if (hay[j] == needle[i]) i++;
  return i == m;
}

static double term_score(const char *needle, int m, const char *hay, int n) {
  if (m == 0) return 0;
  if (m > MAX_NEEDLE) m = MAX_NEEDLE;
  if (n > MAX_HAY) n = MAX_HAY;
  if (!is_subsequence(needle, m, hay, n)) return FUZZY_NONE;
  if (m == n) return 1e6; /* exact */

  double bonus[MAX_HAY];
  char prev = '/';
  for (int j = 0; j < n; j++) {
    char c = hay[j];
    int alnum = (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || (unsigned char)c >= 0x80;
    bonus[j] = 0;
    if (alnum) {
      if (prev == '/') bonus[j] = MATCH_SEP;
      else if (prev == ' ' || prev == '-' || prev == '_' || prev == ',' || prev == ';')
        bonus[j] = MATCH_WORD;
      else if (prev == '.') bonus[j] = MATCH_DOT;
    }
    prev = c;
  }

  /* D: best score ending in a match at j; M: best score using hay[0..j] */
  double d0[MAX_HAY], m0[MAX_HAY], d1[MAX_HAY], m1[MAX_HAY];
  double *lastD = d0, *lastM = m0, *curD = d1, *curM = m1;
  for (int i = 0; i < m; i++) {
    double prev_score = FUZZY_NONE;
    double gap = i == m - 1 ? GAP_TRAILING : GAP_INNER;
    for (int j = 0; j < n; j++) {
      if (needle[i] == hay[j]) {
        double score = FUZZY_NONE;
        if (i == 0) {
          score = j * GAP_LEADING + bonus[j];
        } else if (j > 0) {
          double a = lastM[j - 1] + bonus[j];
          double b = lastD[j - 1] + MATCH_CONSECUTIVE;
          score = a > b ? a : b;
        }
        curD[j] = score;
        curM[j] = prev_score = score > prev_score + gap ? score : prev_score + gap;
      } else {
        curD[j] = FUZZY_NONE;
        curM[j] = prev_score = prev_score + gap;
      }
    }
    double *t = lastD; lastD = curD; curD = t;
    t = lastM; lastM = curM; curM = t;
  }
  return lastM[n - 1];
}

double fuzzy_score(const char *query, const char *candidate) {
  int n = (int)strlen(candidate);
  double total = 0;
  const char *p = query;
  while (*p) {
    while (*p == ' ') p++;
    const char *e = p;
    while (*e && *e != ' ') e++;
    if (e > p) {
      double s = term_score(p, (int)(e - p), candidate, n);
      if (s <= FUZZY_NONE / 2) return FUZZY_NONE;
      total += s;
    }
    p = e;
  }
  return total;
}
