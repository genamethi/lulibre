#ifndef LULIBRE_DB_H
#define LULIBRE_DB_H

#include <sqlite3.h>

struct lua_State;

/* lulibre's own index database. Calibre's metadata.db is only ever attached
 * read-only and copied from; every write to calibre goes through calibredb. */
struct db {
  sqlite3 *h;
  char *path;
};

/* All return 0 on success; on failure *err is a malloc'd message. */
/* A book's file, the one its text is read from: the file read best (one
 * indexed, a PDF first), else the first on record. lulibre.text, lines,
 * page_put and files (its order), the preview, and verify's evidence all
 * go by it, so whatever is read from a book is read from one file. p is
 * the files table's alias with its dot ("f.") or "". */
/* How long a statement waits for another connection's write lock. */
#define DB_BUSY_MS 5000

#define DB_BOOK_FILE_ORDER(p) "(" p "outcome IN (1, 2)) DESC, (" p "format = 'PDF') DESC, " p "id"

int db_open(struct db *db, const char *path, char **err);
/* A second, read-only connection for queries run off the loop thread. */
int db_open_reader(struct db *db, const char *path, char **err);
/* A further read-write connection to an index db_open has already set up,
 * for a thread of its own. */
int db_open_writer(struct db *db, const char *path, char **err);
void db_close(struct db *db);
/* A path as an SQLite URI with ?mode= (ro, rw, rwc), the characters a URI
 * gives meaning to escaped. Free it. */
char *db_uri(const char *path, const char *mode);
/* Rebuild the rows that show staged files (the `staged` table) as books
 * with negative ids. In its own transaction unless in_txn. */
int db_stage_refresh(struct db *db, int in_txn, char **err);
int db_exec(struct db *db, const char *sql, char **err);
int db_prepare(struct db *db, const char *sql, sqlite3_stmt **st, char **err);

char *db_meta_get(struct db *db, const char *key); /* malloc'd or NULL */
int db_meta_set(struct db *db, const char *key, const char *val);

/* Copy calibre's metadata into the index: the books calibre changed since
 * the last copy, when metadata.db has changed (force 0) or at once (1);
 * every book (2). Returns 1 if a copy ran, 0 if already current, -1 on
 * error. */
int db_mirror(struct db *db, const char *library, int force, char **err);
/* After a copy on the same connection: the books added, removed or
 * modified by it (malloc'd, *n of them; NULL when none). */
long long *db_mirror_changed(struct db *db, int *n);
/* Copies made so far, by any connection: what was built from the records
 * (the rarity of their words, match/similar.h) is built again after one. */
extern _Atomic unsigned db_mirror_copies;

/* Call fn with each book of the calibre database at path (read, never
 * written), as a row with the columns of the index's books table, named.
 * fn returns nonzero to stop. */
int db_calibre_books(struct db *db, const char *path, int (*fn)(void *ud, sqlite3_stmt *st), void *ud,
                     char **err);

/* dbfuncs.c */
/* lulibre's SQL functions on every connection opened from now on, by
 * anything in the process; db_open* call it. */
void db_functions_everywhere(void);

extern const char db_schema[];

#endif
