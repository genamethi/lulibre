#ifndef LULIBRE_FOLD_H
#define LULIBRE_FOLD_H

#include "core/util.h"

/* Append a search key for s: ASCII lower-cased, Latin letters stripped of
 * their diacritics ("Erdős" -> "erdos"), combining marks dropped. Other
 * scripts pass through unchanged. */
void fold_utf8(sbuf *out, const char *s, size_t n);

/* Decode one UTF-8 sequence; returns bytes consumed (>= 1). Invalid input
 * yields U+FFFD and consumes one byte. */
int utf8_decode(const char *s, size_t n, unsigned *cp);
int utf8_encode(char *out, unsigned cp);

#endif
