#ifndef LULIBRE_QUERY_H
#define LULIBRE_QUERY_H

#include "db/db.h"

/* The filter language shared by the command line, the TUI and Lua.
 *
 *   term term ...        all must hold;  "or" between terms starts an alternative
 *   -term                negation
 *   word  "a phrase"     substring of title, authors or tags
 *   field:value          substring of that field (case and accents ignored)
 *   field:=value         exact        field:^value   prefix
 *   field:~pattern       Lua pattern (case-sensitive, as in string.find)
 *   field:none           field is empty
 *
 * Fields: title author tag subject publisher series lang path fmt id year
 *         ident doi isbn arxiv url emb text has no is sort
 *   subject:   hierarchical tag match; subject:number-theory also matches
 *              math/number-theory/additive
 *   author:unknown       calibre's placeholder authors
 *   id: year:  numbers: 12  10-20  >1990  <=2001  1,5,9-12
 *   text:      full-text search of the indexed pages (text:= takes raw FTS5)
 *   emb:       metadata embedded in the files themselves
 *   has: no:   author tags ids doi isbn arxiv url publisher date series
 *              comments lang text file
 *   is:        listauthor filetitle indexed unindexed error missing needsocr
 *              multiformat marked ocr proposed
 *   sort:      [-]id title author year series added modified
 *   in:        library (the default), sync (files staged from the sync
 *              folder, which have negative ids), all
 */
enum { SCOPE_LIBRARY = 1, SCOPE_SYNC, SCOPE_ALL };

struct query {
  int scope; /* set by an in: term */
  char *where;
  char *order;
  char **params;
  int nparams, cap;
};

int query_compile(const char *filter, struct query *q, char **err);
/* The same, with the scope a filter has when it does not say in:. */
int query_compile_in(const char *filter, int scope, struct query *q, char **err);
void query_free(struct query *q);

/* SELECT <cols> FROM books b WHERE <filter> ORDER BY <order> [LIMIT limit];
 * parameters are bound. limit <= 0 means none. */
int query_prepare(struct db *db, const struct query *q, const char *cols, int limit,
                  sqlite3_stmt **st, char **err);

#endif
