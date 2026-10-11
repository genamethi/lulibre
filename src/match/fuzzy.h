#ifndef LULIBRE_FUZZY_H
#define LULIBRE_FUZZY_H

/* fzf-style fuzzy matching. Both strings must already be folded (see
 * fold.h), so matching ignores case and accents.
 *
 * The query is split on spaces; every term must appear in the candidate as a
 * subsequence. Higher scores are better; FUZZY_NONE means no match. */
#define FUZZY_NONE (-1e30)

double fuzzy_score(const char *query, const char *candidate);

#endif
