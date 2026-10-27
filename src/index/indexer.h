#ifndef LULIBRE_INDEXER_H
#define LULIBRE_INDEXER_H

#include <uv.h>

#include "db/db.h"
#include "db/query.h"

/* Extract the leading pages of every file into the index.
 *
 * Extraction runs on libuv's thread pool; results are written to sqlite on
 * the loop thread, which therefore stays free to draw and take input. A run
 * is incremental (unchanged files are skipped) and can be cancelled at any
 * point without losing what has been stored. */

struct index_opts {
  int pages;
  int force;                 /* re-extract even when size and mtime are unchanged */
  int retry;                 /* retry files that failed last time */
  int inflight;              /* jobs handed to the pool at once */
  const struct query *only;  /* optional: restrict to books matching a filter */
};

struct index_stats {
  int files;    /* files considered */
  int queued;   /* of those, needing extraction */
  int done;     /* extraction finished (ok + failed) */
  int ok, failed, missing, current;
  long pages, chars;
  double started, elapsed;
  const char *last_path;  /* valid only inside the progress callback */
  const char *last_error;
};

struct indexer;
typedef void indexer_cb(struct indexer *ix, const struct index_stats *st, void *ud);

/* Returns NULL with *err set on failure. `done` fires once, on the loop
 * thread, after the last write; call indexer_free from it or after it. */
struct indexer *indexer_start(uv_loop_t *loop, struct db *db, const struct index_opts *o,
                              indexer_cb *progress, indexer_cb *done, void *ud, char **err);
void indexer_cancel(struct indexer *ix);
void indexer_free(struct indexer *ix);

#endif
