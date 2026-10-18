#ifndef LULIBRE_DB_H
#define LULIBRE_DB_H

#include <sqlite3.h>

struct lua_State;

/* lulibre's own index database. Calibre's metadata.db is only ever attached
 * read-only and copied from; every write to calibre goes through calibredb. */
struct db {
  sqlite3 *h;
  struct lua_State *L; /* private state backing the lmatch() SQL function */
  char *path;
};

enum file_status { FILE_PENDING = 0, FILE_OK = 1, FILE_ERROR = 2, FILE_MISSING = 3 };

/* All return 0 on success; on failure *err is a malloc'd message. */
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

/* Copy calibre's metadata into the index when metadata.db has changed (or
 * force is set). Returns 1 if a copy ran, 0 if already current, -1 on error. */
int db_mirror(struct db *db, const char *library, int force, char **err);

/* Call fn with each book of the calibre database at path (read, never
 * written), as a row with the columns of the index's books table, named.
 * fn returns nonzero to stop. */
int db_calibre_books(struct db *db, const char *path, int (*fn)(void *ud, sqlite3_stmt *st), void *ud,
                     char **err);

/* dbfuncs.c */
int db_register_functions(struct db *db, char **err);

extern const char db_schema[];

#endif
