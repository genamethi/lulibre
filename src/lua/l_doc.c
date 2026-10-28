/* bookman.files(book): what the index holds of a book's files.
 *
 *   { {path=, format=, outcome=, pages=, chars=, quality=, error=, title=,
 *      author=, subject=, keywords=, creator=, producer=}, ... }
 *
 * title to producer are the file's own metadata, as the indexer read it. */
#include <stdlib.h>

#include <lua.h>
#include <lauxlib.h>

#include "app.h"
#include "core/util.h"
#include "db/db.h"
#include "index/outcome.h"
#include "lua/lapi.h"

static sqlite3_stmt *prep(lua_State *L, const char *sql) {
  struct app *app = lapi_app(L);
  sqlite3_stmt *st;
  char *err = NULL;
  app_open_db(app);
  if (db_prepare(lapi_db(L), sql, &st, &err)) {
    lua_pushstring(L, err);
    free(err);
    lua_error(L);
  }
  return st;
}

int l_doc_files(lua_State *L) {
  static const char *const text_cols[] = {"path", "format", "error", "title", "author",
                                          "subject", "keywords", "creator", "producer"};
  lua_Integer id = luaL_checkinteger(L, 1);
  sqlite3_stmt *st = prep(L,
    "SELECT path, format, error, emb_title, emb_author, emb_subject, emb_keywords,"
    " emb_creator, emb_producer, outcome, npages, nchars, quality"
    " FROM files WHERE book = ? ORDER BY " DB_BOOK_FILE_ORDER(""));
  sqlite3_bind_int64(st, 1, id);
  lua_newtable(L);
  int i = 0;
  while (sqlite3_step(st) == SQLITE_ROW) {
    lua_createtable(L, 0, 13);
    for (int c = 0; c < (int)ARRAY_LEN(text_cols); c++) {
      const char *s = (const char *)sqlite3_column_text(st, c);
      if (!s || !*s) continue;
      lua_pushstring(L, s);
      lua_setfield(L, -2, text_cols[c]);
    }
    int o = sqlite3_column_int(st, 9);
    lua_pushstring(L, outcome_words[o >= 0 && o < OUTCOMES ? o : 0]);
    lua_setfield(L, -2, "outcome");
    if (sqlite3_column_type(st, 10) != SQLITE_NULL) {
      lua_pushinteger(L, sqlite3_column_int(st, 10));
      lua_setfield(L, -2, "pages");
      lua_pushinteger(L, sqlite3_column_int64(st, 11));
      lua_setfield(L, -2, "chars");
      lua_pushnumber(L, sqlite3_column_double(st, 12));
      lua_setfield(L, -2, "quality");
    }
    lua_rawseti(L, -2, ++i);
  }
  sqlite3_finalize(st);
  return 1;
}
