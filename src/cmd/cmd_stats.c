#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "app.h"
#include "core/util.h"
#include "db/query.h"

/* Each row is an ordinary filter, so every number here can be turned into a
 * list with `lulibre query <filter>`. */
static const struct { const char *label, *filter; } rows[] = {
  {"books", ""},
  {"unknown author", "author:unknown"},
  {"author is a list", "is:listauthor"},
  {"title looks like a filename", "is:filetitle"},
  {"no tags", "tag:none"},
  {"no identifiers", "no:ids"},
  {"no date", "no:date"},
  {"no publisher", "no:publisher"},
  {"indexed", "is:indexed"},
  {"not indexed yet", "is:unindexed"},
  {"extraction failed", "is:error"},
  {"no usable text layer (OCR candidates)", "is:needsocr"},
  {"file missing on disk", "is:missing"},
};

int cmd_stats(struct app *app, int argc, char **argv) {
  if (argc > 1 && (!strcmp(argv[1], "-h") || !strcmp(argv[1], "--help"))) {
    puts("usage: lulibre stats\n\nCount what is missing across the library. Each line shows "
         "the filter behind it.");
    return 0;
  }
  app_open_db(app);
  for (size_t i = 0; i < ARRAY_LEN(rows); i++) {
    struct query q;
    sqlite3_stmt *st;
    char *err = NULL;
    if (query_compile(rows[i].filter, &q, &err)) die("%s", err);
    free(q.order);
    q.order = xstrdup("1");
    if (query_prepare(&app->db, &q, "count(*)", 0, &st, &err)) die("%s", err);
    long n = sqlite3_step(st) == SQLITE_ROW ? (long)sqlite3_column_int64(st, 0) : -1;
    sqlite3_finalize(st);
    query_free(&q);
    printf("%6ld  %-38s %s\n", n, rows[i].label, rows[i].filter);
  }
  return 0;
}
