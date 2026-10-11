/* The library, as the index sees it. Filters are the same language the
 * interface and `lulibre query` use.
 *
 *   lulibre.ids(filter)     { id, ... }
 *   lulibre.books(filter)   { book, ... }
 *   lulibre.book(id)        book or nil
 *   lulibre.count(filter)   number
 *   lulibre.authors()       { {name=, books=}, ... } most books first
 *   lulibre.tags()          { {name=, books=}, ... }
 *   lulibre.sql(sql, ...)   rows of a read-only query against the index
 *   lulibre.store(sql, ...) the same, but may also write lulibre's own tables
 *                           (proposals, journal, kv); returns rows, rows
 *                           changed, last insert id
 *   lulibre.reload()        pick up changes calibre has made since the last look
 *   lulibre.source([name])  what the list shows, "library" or "sync"; sets it
 *                           when given. A filter that does not say in: applies
 *                           to that.
 *   lulibre.stage_refresh() after changing the `staged` table: rebuild the
 *                           books (negative ids) that stand for its files
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
#include "core/util.h"
#include "db/query.h"
#include "lua/bridge.h"
#include "lua/lapi.h"
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

static int l_book(lua_State *L) {
  lua_Integer id = luaL_checkinteger(L, 1);
  struct db *db = db_of(L);
  sqlite3_stmt *st;
  char *err = NULL;
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

/* Lets a statement read anything but write only lulibre's own tables. */
static int store_authorizer(void *ud, int action, const char *a, const char *b, const char *c,
                            const char *d) {
  switch (action) {
    case SQLITE_INSERT:
    case SQLITE_UPDATE:
    case SQLITE_DELETE:
      return a && (!strcmp(a, "proposals") || !strcmp(a, "journal") || !strcmp(a, "kv") ||
                   !strcmp(a, "staged"))
               ? SQLITE_OK : SQLITE_DENY;
    case SQLITE_SELECT:
    case SQLITE_READ:
    case SQLITE_FUNCTION:
    case SQLITE_RECURSIVE:
      return SQLITE_OK;
    default:
      return SQLITE_DENY; /* schema changes, ATTACH, PRAGMA, ... */
  }
}

static int run_sql(lua_State *L, int writable) {
  const char *sql = luaL_checkstring(L, 1);
  struct db *db = db_of(L);
  sqlite3_stmt *st;
  char *err = NULL;
  if (writable) sqlite3_set_authorizer(db->h, store_authorizer, NULL);
  int prc = db_prepare(db, sql, &st, &err);
  if (writable) sqlite3_set_authorizer(db->h, NULL, NULL);
  if (prc) {
    lua_pushstring(L, writable && strstr(err, "not authorized")
                        ? "lulibre.store may only write the proposals, journal, kv and staged tables"
                        : err);
    free(err);
    return lua_error(L);
  }
  if (!writable && !sqlite3_stmt_readonly(st)) {
    sqlite3_finalize(st);
    return luaL_error(L, "lulibre.sql is read-only; changes to the library go through calibre");
  }
  int top = lua_gettop(L);
  for (int i = 2; i <= top; i++) {
    switch (lua_type(L, i)) {
      case LUA_TNUMBER:
        if (lua_isinteger(L, i)) sqlite3_bind_int64(st, i - 1, lua_tointeger(L, i));
        else sqlite3_bind_double(st, i - 1, lua_tonumber(L, i));
        break;
      case LUA_TBOOLEAN: sqlite3_bind_int(st, i - 1, lua_toboolean(L, i)); break;
      case LUA_TNIL: sqlite3_bind_null(st, i - 1); break;
      default: {
        size_t n;
        const char *s = luaL_tolstring(L, i, &n);
        sqlite3_bind_text(st, i - 1, s, (int)n, SQLITE_TRANSIENT);
        lua_pop(L, 1);
      }
    }
  }
  lua_newtable(L);
  int row = 0, rc, ncol = sqlite3_column_count(st);
  while ((rc = sqlite3_step(st)) == SQLITE_ROW) {
    lua_createtable(L, 0, ncol);
    for (int c = 0; c < ncol; c++) {
      switch (sqlite3_column_type(st, c)) {
        case SQLITE_INTEGER: lua_pushinteger(L, sqlite3_column_int64(st, c)); break;
        case SQLITE_FLOAT: lua_pushnumber(L, sqlite3_column_double(st, c)); break;
        case SQLITE_NULL: continue;
        default:
          lua_pushlstring(L, (const char *)sqlite3_column_text(st, c),
                          (size_t)sqlite3_column_bytes(st, c));
      }
      lua_setfield(L, -2, sqlite3_column_name(st, c));
    }
    lua_rawseti(L, -2, ++row);
  }
  step_error(L, st, rc);
  sqlite3_finalize(st);
  if (!writable) return 1;
  lua_pushinteger(L, sqlite3_changes(db->h));
  lua_pushinteger(L, sqlite3_last_insert_rowid(db->h));
  return 3;
}

static int l_sql(lua_State *L) {
  return run_sql(L, 0);
}

static int l_store(lua_State *L) {
  return run_sql(L, 1);
}

static int reload_ui(lua_State *L) {
  struct app *app = lapi_app(L);
  app_open_db(app);
  if (app->tui) {
    tui_reload(app->tui);
  } else {
    char *err = NULL;
    if (db_mirror(&app->db, app->cfg.library, 0, &err) < 0) {
      lua_pushstring(L, err);
      free(err);
      return lua_error(L);
    }
  }
  return 0;
}

static int l_reload(lua_State *L) {
  return ui_call(L, reload_ui);
}

static int l_stage_refresh(lua_State *L) {
  char *err = NULL;
  if (db_stage_refresh(lapi_db(L), 0, &err)) {
    lua_pushstring(L, err);
    free(err);
    return lua_error(L);
  }
  return 0;
}

static int source_ui(lua_State *L) {
  struct app *app = lapi_app(L);
  if (!lua_isnoneornil(L, 1)) {
    const char *name = luaL_checkstring(L, 1);
    int to = !strcmp(name, "sync");
    if (!to && strcmp(name, "library")) return luaL_error(L, "a source is \"library\" or \"sync\"");
    if (app->tui) rows_set_source(app->tui, to);
    else atomic_store(&app->source, to); /* headless: only the default scope of filters */
  }
  lua_pushstring(L, atomic_load(&app->source) ? "sync" : "library");
  return 1;
}

static int l_source(lua_State *L) {
  return ui_call(L, source_ui);
}

void l_db_open(lua_State *L) {
  static const luaL_Reg fns[] = {
    {"ids", l_ids},         {"books", l_books}, {"book", l_book}, {"count", l_count},
    {"authors", l_authors}, {"tags", l_tags},   {"sql", l_sql},   {"store", l_store},
    {"reload", l_reload},   {"source", l_source}, {"stage_refresh", l_stage_refresh},
    {NULL, NULL},
  };
  luaL_setfuncs(L, fns, 0);
}
