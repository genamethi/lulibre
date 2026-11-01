/* bookman: the library, as the index sees it. Filters are the same
 * language the interface and `lulibre query` use.
 *
 *   bookman.ids(filter)     { id, ... }
 *   bookman.books(filter)   { book, ... }
 *   bookman.get(id)         book or nil
 *   bookman.get(id, field)  the field's value, a string ("" when it has
 *                           none); nil when there is no such book
 *   bookman.count(filter)   number
 *   bookman.authors()       { {name=, books=}, ... } most books first
 *   bookman.tags()          { {name=, books=}, ... }
 *   bookman.files(book)     l_doc.c
 *
 * and store.reload(): pick up changes calibre has made since the last
 * look; waits.
 *
 * A book is { id, title, authors = {...}, author = "A & B", tags = {...},
 * year, pubdate, publisher, series, series_index, lang, idents = {doi=..., isbn=...},
 * formats = {...}, dir }.
 */
#include <stdlib.h>
#include <string.h>

#include <lua.h>
#include <lauxlib.h>

#include "app.h"
#include "core/queue.h"
#include "core/util.h"
#include "db/query.h"
#include "library/fields.h"
#include "library/library.h"
#include "lua/bridge.h"
#include "lua/lapi.h"
#include "lua/sched.h"
#include "tui/tui.h"

#define BOOK_COLS \
  "b.id, b.title, b.authors, b.tags, b.year, b.pubdate, b.publisher, b.series," \
  " b.languages, b.idents, b.formats, b.path, b.series_index"

static struct db *db_of(lua_State *L) {
  return lapi_db(L);
}

static void set_text(lua_State *L, sqlite3_stmt *st, int col, const char *key) {
  const char *s = (const char *)sqlite3_column_text(st, col);
  if (!s) return;
  lua_pushstring(L, s);
  lua_setfield(L, -2, key);
}

/* Push an array of the pieces of s between occurrences of sep. */
static void push_split(lua_State *L, const char *s, const char *sep) {
  lua_newtable(L);
  if (!s || !*s) return;
  size_t seplen = strlen(sep);
  int i = 0;
  for (;;) {
    const char *e = strstr(s, sep);
    lua_pushlstring(L, s, e ? (size_t)(e - s) : strlen(s));
    lua_rawseti(L, -2, ++i);
    if (!e) break;
    s = e + seplen;
  }
}

static void push_book(lua_State *L, sqlite3_stmt *st) {
  lua_createtable(L, 0, 14);
  lua_pushinteger(L, sqlite3_column_int64(st, 0));
  lua_setfield(L, -2, "id");
  set_text(L, st, 1, "title");
  set_text(L, st, 2, "author");
  push_split(L, (const char *)sqlite3_column_text(st, 2), " & ");
  lua_setfield(L, -2, "authors");
  push_split(L, (const char *)sqlite3_column_text(st, 3), ", ");
  lua_setfield(L, -2, "tags");
  if (sqlite3_column_type(st, 4) != SQLITE_NULL) {
    lua_pushinteger(L, sqlite3_column_int(st, 4));
    lua_setfield(L, -2, "year");
  }
  set_text(L, st, 5, "pubdate");
  set_text(L, st, 6, "publisher");
  set_text(L, st, 7, "series");
  set_text(L, st, 8, "lang");
  /* idents: "doi:10.1/x, isbn:978..." -> {doi = "10.1/x", isbn = "978..."} */
  lua_newtable(L);
  const char *ids = (const char *)sqlite3_column_text(st, 9);
  while (ids && *ids) {
    const char *e = strstr(ids, ", ");
    size_t len = e ? (size_t)(e - ids) : strlen(ids);
    const char *colon = memchr(ids, ':', len);
    if (colon) {
      lua_pushlstring(L, ids, (size_t)(colon - ids));
      lua_pushlstring(L, colon + 1, len - (size_t)(colon + 1 - ids));
      lua_settable(L, -3);
    }
    ids = e ? e + 2 : NULL;
  }
  lua_setfield(L, -2, "idents");
  push_split(L, (const char *)sqlite3_column_text(st, 10), ",");
  lua_setfield(L, -2, "formats");
  set_text(L, st, 11, "dir");
  if (sqlite3_column_type(st, 12) != SQLITE_NULL) {
    lua_pushnumber(L, sqlite3_column_double(st, 12));
    lua_setfield(L, -2, "series_index");
  }
}

/* Compile the filter at index 1 and prepare a SELECT of cols; raises a Lua
 * error (after cleaning up) when the filter is bad. */
static sqlite3_stmt *prepare(lua_State *L, const char *cols) {
  const char *filter = luaL_optstring(L, 1, "");
  struct db *db = db_of(L);
  struct query q;
  sqlite3_stmt *st = NULL;
  char *err = NULL;
  /* without an in: term a filter means what the list is showing */
  int scope = atomic_load(&lapi_app(L)->source) ? SCOPE_SYNC : SCOPE_LIBRARY;
  int rc = query_compile_in(filter, scope, &q, &err);
  if (!rc) {
    if (!strcmp(cols, "count(*)")) {
      free(q.order);
      q.order = xstrdup("1");
    }
    rc = query_prepare(db, &q, cols, 0, &st, &err);
    query_free(&q);
  }
  if (rc) {
    lua_pushfstring(L, "filter: %s", err);
    free(err);
    lua_error(L);
  }
  return st;
}

static int step_error(lua_State *L, sqlite3_stmt *st, int rc) {
  if (rc == SQLITE_DONE) return 0;
  lua_pushstring(L, sqlite3_errmsg(sqlite3_db_handle(st)));
  sqlite3_finalize(st);
  return lua_error(L);
}

static int l_ids(lua_State *L) {
  sqlite3_stmt *st = prepare(L, "b.id");
  lua_newtable(L);
  int i = 0, rc;
  while ((rc = sqlite3_step(st)) == SQLITE_ROW) {
    lua_pushinteger(L, sqlite3_column_int64(st, 0));
    lua_rawseti(L, -2, ++i);
  }
  step_error(L, st, rc);
  sqlite3_finalize(st);
  return 1;
}

static int l_books(lua_State *L) {
  sqlite3_stmt *st = prepare(L, BOOK_COLS);
  lua_newtable(L);
  int i = 0, rc;
  while ((rc = sqlite3_step(st)) == SQLITE_ROW) {
    push_book(L, st);
    lua_rawseti(L, -2, ++i);
  }
  step_error(L, st, rc);
  sqlite3_finalize(st);
  return 1;
}

static int l_count(lua_State *L) {
  sqlite3_stmt *st = prepare(L, "count(*)");
  int rc = sqlite3_step(st);
  if (rc == SQLITE_ROW) lua_pushinteger(L, sqlite3_column_int64(st, 0));
  else return step_error(L, st, rc);
  sqlite3_finalize(st);
  return 1;
}

static int l_get(lua_State *L) {
  lua_Integer id = luaL_checkinteger(L, 1);
  struct db *db = db_of(L);
  sqlite3_stmt *st;
  char *err = NULL;
  if (!lua_isnoneornil(L, 2)) {
    const char *field = luaL_checkstring(L, 2);
    char *v = field_current(db, id, field, &err);
    if (v) {
      lua_pushstring(L, v);
      free(v);
      return 1;
    }
    int no_book = !strncmp(err, "no book", 7);
    lua_pushstring(L, err);
    free(err);
    if (no_book) {
      lua_pushnil(L);
      return 1;
    }
    return lua_error(L);
  }
  if (db_prepare(db, "SELECT " BOOK_COLS " FROM books b WHERE b.id = ?", &st, &err)) {
    lua_pushstring(L, err);
    free(err);
    return lua_error(L);
  }
  sqlite3_bind_int64(st, 1, id);
  if (sqlite3_step(st) == SQLITE_ROW) push_book(L, st);
  else lua_pushnil(L);
  sqlite3_finalize(st);
  return 1;
}

static int counted(lua_State *L, const char *sql) {
  struct db *db = db_of(L);
  sqlite3_stmt *st;
  char *err = NULL;
  if (db_prepare(db, sql, &st, &err)) {
    lua_pushstring(L, err);
    free(err);
    return lua_error(L);
  }
  lua_newtable(L);
  int i = 0;
  while (sqlite3_step(st) == SQLITE_ROW) {
    lua_createtable(L, 0, 2);
    set_text(L, st, 0, "name");
    lua_pushinteger(L, sqlite3_column_int(st, 1));
    lua_setfield(L, -2, "books");
    lua_rawseti(L, -2, ++i);
  }
  sqlite3_finalize(st);
  return 1;
}

static int l_authors(lua_State *L) {
  return counted(L, "SELECT name, n_books FROM authors WHERE id > 0 ORDER BY n_books DESC, name");
}

static int l_tags(lua_State *L) {
  return counted(L, "SELECT name, n_books FROM tags WHERE id > 0 ORDER BY n_books DESC, name");
}

static int l_series(lua_State *L) {
  return counted(L, "SELECT series, COUNT(*) AS n FROM books WHERE series IS NOT NULL AND series != ''"
                    " GROUP BY series ORDER BY n DESC, series");
}

/* store.reload(): calibre's records read again by the library, on a
 * worker; the task waits for it (the list follows EV_RECORDS_CHANGED) */
struct reload_msg {
  struct task *task;
  int rc;
  char *err;
};

static void reload_answered(struct app *app, void *arg) { /* the Lua thread */
  struct reload_msg *m = arg;
  lua_State *L = sched_end_wait(m->task);
  if (L && m->rc < 0) {
    lua_pushnil(L);
    lua_pushstring(L, m->err ? m->err : "failed");
    sched_wake(m->task, 2);
  } else if (L) {
    lua_pushboolean(L, 1);
    sched_wake(m->task, 1);
  }
  free(m->err);
  free(m);
}

static void reloaded(int rc, const char *err, void *ud) { /* the background thread */
  struct reload_msg *m = ud;
  m->rc = rc;
  m->err = err ? xstrdup(err) : NULL;
  queue_post(LOOP_LUA, reload_answered, m);
}

static void reload_main(struct app *app, void *arg) {
  if (app->library) library_reload(app->library, 0, reloaded, arg);
  else reloaded(-1, "the library is closed", arg);
}

int l_db_reload(lua_State *L) {
  lapi_db(L); /* the index open, and the library with it */
  struct reload_msg *m = xcalloc(1, sizeof *m);
  m->task = sched_begin_wait(L);
  queue_post(LOOP_WORK, reload_main, m);
  return lua_yield(L, 0);
}

int luaopen_bookman(lua_State *L) {
  static const luaL_Reg fns[] = {
    {"ids", l_ids},         {"books", l_books}, {"get", l_get}, {"count", l_count},
    {"authors", l_authors}, {"tags", l_tags}, {"series", l_series},   {"files", l_doc_files}, {NULL, NULL},
  };
  luaL_newlib(L, fns);
  return 1;
}
