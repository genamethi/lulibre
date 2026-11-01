/* txt: a file's text with its attributes at each position, in Lua (design
 * 13, 14; doc/reading.h), a module written in C, preloaded.
 *
 *   local txt = require "txt"
 *   local r <close> = txt.of(book)     the text of the book's file
 *   local r <close> = txt.load(file)   of a file, by its id in the index
 *     both wait (the lines are read on a worker); nil and the reason when
 *     the file has no lines
 *   txt.metadata(file)                 a file's own metadata as text: a PDF's
 *     XMP packet and Info dictionary, an EPUB's package document; waits, as
 *     the file is opened on a worker; nil and the reason when it cannot be
 *
 *   r.text, r.file, r.pages, r.meta = {title=, author=, subject=,
 *     keywords=, creator=, producer=}
 *   #r                  the number of lines
 *   r:line(i)           the i-th line: {text=, page=, n=, start=, stop=,
 *                       size=, x0=, y0=, x1=, y1=, math=, bold=, italic=,
 *                       super=, rotated=, mono=, block=, index=}; start and
 *                       stop are positions in r.text, as string.sub takes them
 *   r:at(pos)           the line holding position pos of r.text, or nil on a
 *                       page break; a line break counts as the line before's
 *   r:largest(page)     the largest line size on the page
 *   r:height(page)      the page's height, as far as its lines reach
 *
 * A text never changes. It is released when its <close> variable goes
 * out of scope, or by the collector. */
#include <stdlib.h>
#include <string.h>

#include <lua.h>
#include <lauxlib.h>
#include <sqlite3.h>
#include <uv.h>

#include "app.h"
#include "core/util.h"
#include "db/db.h"
#include "doc/doc.h"
#include "doc/reading.h"
#include "lua/lapi.h"
#include "lua/sched.h"

static const char META[] = "txt";

struct ud {
  struct reading *r;
};

static struct reading *check(lua_State *L, int idx) {
  struct ud *u = luaL_checkudata(L, idx, META);
  if (!u->r) luaL_argerror(L, idx, "a text already closed");
  return u->r;
}

/* Lines are made into tables once, kept in the userdata's first user
 * value. */
static void push_line(lua_State *L, int idx, struct reading *r, int i) {
  lua_getiuservalue(L, idx, 1);
  if (lua_rawgeti(L, -1, i + 1) != LUA_TNIL) {
    lua_remove(L, -2);
    return;
  }
  lua_pop(L, 1);
  static const struct { const char *name; unsigned bit; } bits[] = {
    {"bold", LINE_BOLD}, {"italic", LINE_ITALIC}, {"super", LINE_SUPER},
    {"rotated", LINE_ROTATED}, {"mono", LINE_MONO}, {"block", LINE_BLOCK},
  };
  const struct reading_line *l = &r->lines[i];
  lua_createtable(L, 0, 18);
  lua_pushlstring(L, r->text + l->start, l->len);
  lua_setfield(L, -2, "text");
  lua_pushinteger(L, l->page);
  lua_setfield(L, -2, "page");
  lua_pushinteger(L, l->n);
  lua_setfield(L, -2, "n");
  lua_pushinteger(L, (lua_Integer)l->start + 1);
  lua_setfield(L, -2, "start");
  lua_pushinteger(L, (lua_Integer)(l->start + l->len));
  lua_setfield(L, -2, "stop");
  lua_pushinteger(L, i + 1);
  lua_setfield(L, -2, "index");
  lua_pushnumber(L, l->size);
  lua_setfield(L, -2, "size");
  lua_pushnumber(L, l->x0);
  lua_setfield(L, -2, "x0");
  lua_pushnumber(L, l->y0);
  lua_setfield(L, -2, "y0");
  lua_pushnumber(L, l->x1);
  lua_setfield(L, -2, "x1");
  lua_pushnumber(L, l->y1);
  lua_setfield(L, -2, "y1");
  if (l->math) {
    lua_pushstring(L, l->math);
    lua_setfield(L, -2, "math");
  }
  for (size_t k = 0; k < ARRAY_LEN(bits); k++) {
    lua_pushboolean(L, (l->flags & bits[k].bit) != 0);
    lua_setfield(L, -2, bits[k].name);
  }
  lua_pushvalue(L, -1);
  lua_rawseti(L, -3, i + 1);
  lua_remove(L, -2);
}

static int m_line(lua_State *L) {
  struct reading *r = check(L, 1);
  lua_Integer i = luaL_checkinteger(L, 2);
  if (i < 1 || i > r->nlines) return 0;
  push_line(L, 1, r, (int)i - 1);
  return 1;
}

static int m_at(lua_State *L) {
  struct reading *r = check(L, 1);
  lua_Integer pos = luaL_checkinteger(L, 2);
  if (pos < 1) return 0;
  int i = reading_line_at(r, (size_t)pos - 1);
  if (i < 0) return 0;
  push_line(L, 1, r, i);
  return 1;
}

static int m_largest(lua_State *L) {
  struct reading *r = check(L, 1);
  lua_Integer page = luaL_checkinteger(L, 2);
  float max = 0;
  for (int i = 0; i < r->nlines; i++)
    if (r->lines[i].page == page && r->lines[i].size > max) max = r->lines[i].size;
  lua_pushnumber(L, max);
  return 1;
}

static int m_height(lua_State *L) {
  struct reading *r = check(L, 1);
  lua_Integer page = luaL_checkinteger(L, 2);
  float max = 0;
  for (int i = 0; i < r->nlines; i++)
    if (r->lines[i].page == page && r->lines[i].y1 > max) max = r->lines[i].y1;
  lua_pushnumber(L, max);
  return 1;
}

static int m_len(lua_State *L) {
  lua_pushinteger(L, check(L, 1)->nlines);
  return 1;
}

static int m_close(lua_State *L) {
  struct ud *u = luaL_checkudata(L, 1, META);
  reading_release(u->r);
  u->r = NULL;
  return 0;
}

static int m_index(lua_State *L) {
  struct reading *r = check(L, 1);
  const char *key = luaL_checkstring(L, 2);
  if (!strcmp(key, "text")) {
    lua_getiuservalue(L, 1, 2);
  } else if (!strcmp(key, "file")) {
    lua_pushinteger(L, r->file);
  } else if (!strcmp(key, "pages")) {
    lua_pushinteger(L, r->pages);
  } else if (!strcmp(key, "meta")) {
    static const char *const names[] = {"title", "author", "subject", "keywords", "creator", "producer"};
    const char *const *v = (const char *const *)&r->meta;
    lua_createtable(L, 0, 6);
    for (size_t i = 0; i < ARRAY_LEN(names); i++)
      if (v[i]) {
        lua_pushstring(L, v[i]);
        lua_setfield(L, -2, names[i]);
      }
  } else {
    luaL_getmetafield(L, 1, "methods");
    lua_getfield(L, -1, key);
  }
  return 1;
}

static void push_reading(lua_State *L, struct reading *r) {
  struct ud *u = lua_newuserdatauv(L, sizeof *u, 2);
  u->r = r;
  lua_createtable(L, r->nlines, 0); /* the lines made into tables */
  lua_setiuservalue(L, -2, 1);
  lua_pushlstring(L, r->text, r->len); /* the text, made once */
  lua_setiuservalue(L, -2, 2);
  luaL_setmetatable(L, META);
}

/* ---- loading, on a worker ---- */

struct job {
  uv_work_t req;
  struct task *task;
  char *index;
  long long book, file; /* the book's best file, when file is 0 */
  struct reading *r;
  int metadata; /* the file's own metadata, not its lines */
  char *meta;
  char *err;
};

static void work(uv_work_t *req) {
  struct job *j = req->data;
  struct db db = {0};
  if (sqlite3_open_v2(j->index, &db.h, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) {
    j->err = xasprintf("cannot open the index: %s", db.h ? sqlite3_errmsg(db.h) : "?");
    sqlite3_close(db.h);
    return;
  }
  sqlite3_busy_timeout(db.h, DB_BUSY_MS);
  if (j->metadata) {
    char *path = NULL;
    sqlite3_stmt *st;
    if (sqlite3_prepare_v2(db.h, "SELECT path FROM files WHERE id = ?", -1, &st, NULL) == SQLITE_OK) {
      sqlite3_bind_int64(st, 1, j->file);
      if (sqlite3_step(st) == SQLITE_ROW) path = xstrdup((const char *)sqlite3_column_text(st, 0));
      sqlite3_finalize(st);
    }
    sqlite3_close(db.h);
    if (path) j->meta = doc_metadata(path, &j->err);
    else j->err = xasprintf("no file %lld", j->file);
    free(path);
    return;
  }
  if (!j->file) {
    sqlite3_stmt *st;
    if (sqlite3_prepare_v2(db.h,
                           "SELECT f.id FROM files f WHERE f.book = ? AND EXISTS(SELECT 1 FROM lines l WHERE l.file = f.id)"
                           " ORDER BY " DB_BOOK_FILE_ORDER("f.") " LIMIT 1",
                           -1, &st, NULL) == SQLITE_OK) {
      sqlite3_bind_int64(st, 1, j->book);
      if (sqlite3_step(st) == SQLITE_ROW) j->file = sqlite3_column_int64(st, 0);
      sqlite3_finalize(st);
    }
  }
  if (!j->file) j->err = xasprintf("book %lld has no file with lines", j->book);
  else j->r = reading_load(&db, j->file, &j->err);
  sqlite3_close(db.h);
}

static void after(uv_work_t *req, int status) {
  struct job *j = req->data;
  lua_State *L = sched_end_job(j->task);
  if (L && j->meta) {
    lua_pushstring(L, j->meta);
    sched_wake(j->task, 1);
  } else if (L && j->r) {
    push_reading(L, j->r);
    j->r = NULL;
    sched_wake(j->task, 1);
  } else if (L) {
    lua_pushnil(L);
    lua_pushstring(L, j->err ? j->err : "cancelled");
    sched_wake(j->task, 2);
  }
  reading_release(j->r);
  free(j->meta);
  free(j->err);
  free(j->index);
  free(j);
}

static int start(lua_State *L, long long book, long long file, int metadata) {
  struct app *app = lapi_app(L);
  sched_require_task(L);
  struct db *db = lapi_db(L);
  struct job *j = xcalloc(1, sizeof *j);
  j->index = xstrdup(db->path);
  j->book = book;
  j->file = file;
  j->metadata = metadata;
  j->req.data = j;
  j->task = sched_begin_job(L);
  uv_queue_work(app->lloop, &j->req, work, after);
  return lua_yield(L, 0);
}

static int l_of(lua_State *L) {
  return start(L, luaL_checkinteger(L, 1), 0, 0);
}

static int l_load(lua_State *L) {
  return start(L, 0, luaL_checkinteger(L, 1), 0);
}

static int l_metadata(lua_State *L) {
  return start(L, 0, luaL_checkinteger(L, 1), 1);
}

int luaopen_txt(lua_State *L) {
  static const luaL_Reg methods[] = {
    {"line", m_line}, {"at", m_at}, {"largest", m_largest}, {"height", m_height}, {NULL, NULL},
  };
  static const luaL_Reg meta[] = {
    {"__index", m_index}, {"__len", m_len}, {"__close", m_close}, {"__gc", m_close}, {NULL, NULL},
  };
  if (luaL_newmetatable(L, META)) {
    luaL_setfuncs(L, meta, 0);
    luaL_newlib(L, methods);
    lua_setfield(L, -2, "methods");
  }
  lua_pop(L, 1);
  static const luaL_Reg fns[] = {{"of", l_of}, {"load", l_load}, {"metadata", l_metadata}, {NULL, NULL}};
  luaL_newlib(L, fns);
  return 1;
}
