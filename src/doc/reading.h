#ifndef LULIBRE_READING_H
#define LULIBRE_READING_H

/* A file's reading (design 13, 14, 15; data representation).
 *
 * Built from the file's stored lines on a worker, then never changed: any
 * thread may hold one, and a view of a reading cannot change under a
 * closure. OCR or indexing again builds a new reading. A count of holders
 * frees the reading with the last one; in Lua the holder is a <close>
 * variable, with __gc for a reading kept past its scope.
 *
 * The text is what grammars match: the lines joined, "\n" between lines,
 * "\n\n" before the first line of a paragraph, "\f" between pages. A match's
 * positions are positions in the text; reading_line_at turns a position
 * into its line, whose size, flags and box the predicates test. */

#include <stdatomic.h>
#include <stddef.h>

struct db;

struct reading_line {
  long long rowid; /* the lines table's row */
  int page;
  int n;           /* place on the page */
  size_t start;    /* in the text */
  size_t len;
  float size;
  unsigned flags; /* LINE_* (doc.h) */
  float x0, y0, x1, y1;
  const char *math; /* the line's mathematics in Unicode, or NULL */
};

/* The file's own metadata, as read. */
struct reading_meta {
  const char *title, *author, *subject, *keywords, *creator, *producer;
};

struct reading {
  long long file;
  const char *text;
  size_t len;
  const struct reading_line *lines;
  int nlines;
  int pages;
  struct reading_meta meta;
  _Atomic int holders;
};

/* On a worker, with a connection of the worker's own. Returns NULL with
 * *err set on failure; the caller holds the reading. */
struct reading *reading_load(struct db *db, long long file, char **err);
void reading_hold(struct reading *r);
void reading_release(struct reading *r);

/* The index of the line holding text position pos (0-based); the line
 * breaks after a line count as the line's. -1 on a page break, or past the
 * end. */
int reading_line_at(const struct reading *r, size_t pos);

#endif
