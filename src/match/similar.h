#ifndef LULIBRE_SIMILAR_H
#define LULIBRE_SIMILAR_H

/* One similarity for every field kind (design 22).
 *
 * Values are folded (fold.h) and cut into tokens by kind. similar(a, b) is
 * the average, over a's tokens weighted by rarity, of each token's best
 * partner in b by edit distance: 0 to 1, and asymmetric. The two
 * directions together give the likeness: both near 1 equal; one near 1,
 * the other lower, contains; both high, near; else differs. */

#include "core/util.h"

struct db;

enum field_kind {
  KIND_TEXT,   /* title, series, publisher: words */
  KIND_PEOPLE, /* authors: persons, each made of name parts; an initial matches a name part */
  KIND_TAGS,   /* tags and their broader terms */
  KIND_DATE,   /* an interval: 1942 is the whole year */
  KIND_IDENT,  /* canonical form, then equality */
};

enum likeness { LIKE_DIFFERS, LIKE_NEAR, LIKE_CONTAINS, LIKE_EQUAL };

/* Token rarity over the library's records, built at each mirror refresh;
 * fixed once built, so any thread may read one. */
struct rarity;
struct rarity *rarity_build(struct db *db, char **err);
void rarity_free(struct rarity *w);

double similar(const struct rarity *w, enum field_kind kind, const char *a, const char *b);

/* The thresholds are settings: near for "near", same for "equal". */
enum likeness likeness(double ab, double ba, double near, double same);

/* An identifier's canonical form, appended to out: ISBN-10 as ISBN-13, a
 * DOI lower-cased without its URL prefix, an arXiv number without its
 * version. Returns 0, or -1 for a malformed identifier. */
int ident_canonical(const char *type, const char *value, sbuf *out);

#endif
