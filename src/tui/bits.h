#ifndef LULIBRE_TUI_BITS_H
#define LULIBRE_TUI_BITS_H

/* Sets of book ids as bitmaps, for search hits (rows.c) and marks (marks.c).
 * A bitmap grows as ids are added; cap is its size in bits. */
#include <string.h>

#include <sqlite3.h>

#include "core/util.h"

/* Staged files have negative ids, so ids are folded onto the non-negative
 * numbers first: 1, -1, 2, -2 ... */
static inline sqlite3_int64 bit_of(sqlite3_int64 id) {
  return id > 0 ? 2 * id : -2 * id + 1;
}

static inline void set_bit(unsigned char **bits, sqlite3_int64 *cap, sqlite3_int64 id) {
  if (id == 0) return;
  id = bit_of(id);
  if (id >= *cap) {
    sqlite3_int64 ncap = *cap ? *cap : 4096;
    while (ncap <= id) ncap *= 2;
    *bits = xrealloc(*bits, (size_t)(ncap >> 3));
    memset(*bits + (*cap >> 3), 0, (size_t)((ncap - *cap) >> 3));
    *cap = ncap;
  }
  (*bits)[id >> 3] |= (unsigned char)(1 << (id & 7));
}

static inline void clear_bit(unsigned char *bits, sqlite3_int64 cap, sqlite3_int64 id) {
  if (id == 0) return;
  id = bit_of(id);
  if (id < cap) bits[id >> 3] &= (unsigned char)~(1 << (id & 7));
}

static inline int get_bit(const unsigned char *bits, sqlite3_int64 cap, sqlite3_int64 id) {
  if (id == 0) return 0;
  id = bit_of(id);
  return id < cap && (bits[id >> 3] >> (id & 7) & 1);
}

#endif
