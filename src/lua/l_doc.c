/* Text: what the index holds for a book, and extraction from arbitrary files.
 *
 *   lulibre.text(id [, page])    indexed text of one page, or of all indexed
 *                                pages joined by form feeds; nil if none
 *   lulibre.lines(id [, page])   the page (default 1) as lines:
 *                                { {text=, size=, bold=, italic=, super=,
 *                                   rotated=, mono=, block=, x0=, y0=, x1=, y1=,
 *                                   math=}, ... }
 *                                math: the line with its mathematics marked
 *                                up as TeX, when it has any (lulibre.notation)
 *   lulibre.files(id)            { {path=, format=, outcome=, pages=, chars=,
 *                                   quality=, error=, title=, author=, subject=,
 *                                   keywords=, creator=, producer=}, ... }
 *   lulibre.extract(path [, {pages=, tail=}])
 *                                read a file now, off the main thread (waits):
 *                                { pages=N, chars=, quality=, meta={title=...},
 *                                  page={ {text=, lines={...}}, ... } } or nil, err
 *   lulibre.render(path, page [, width])
 *                                the page as a greyscale PGM image string, for
 *                                handing to tesseract (waits); or nil, err
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <lua.h>
#include <lauxlib.h>

#include <uv.h>

#include "app.h"
#include "core/util.h"
#include "index/outcome.h"
#include "db/db.h"
#include "doc/doc.h"
#include "lua/lapi.h"
#include "lua/sched.h"

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

/* doc_metadata on a worker: the file is opened (MuPDF, a context of the
 * call's own) away from the Lua thread, and the task waits */
struct mjob {
  uv_work_t req;
  struct task *task;
  char *path, *text, *err;
};

static void m_work(uv_work_t *req) {
  struct mjob *j = req->data;
  j->text = doc_metadata(j->path, &j->err);
}

static void m_after(uv_work_t *req, int status) {
  (void)status;
  struct mjob *j = req->data;
  lua_State *L = sched_end_job(j->task);
  if (L) {
    if (j->text) {
      lua_pushstring(L, j->text);
      sched_wake(j->task, 1);
    } else {
      lua_pushnil(L);
      lua_pushstring(L, j->err ? j->err : "cannot read");
      sched_wake(j->task, 2);
    }
  }
  free(j->path);
  free(j->text);
  free(j->err);
  free(j);
}

/* lulibre.doc_metadata(path): the metadata a file carries beside its pages,
 * as text (doc_metadata); nil and why when it cannot be opened. In a task
 * it waits while a worker reads the file; called outside one (code the
 * interface runs directly) it reads the file there and then. */
static int l_doc_metadata(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  if (sched_current_id(L) && lua_isyieldable(L)) {
    struct mjob *j = xcalloc(1, sizeof *j);
    j->path = xstrdup(path);
    j->req.data = j;
    j->task = sched_begin_job(L);
    uv_queue_work(lapi_loop(L), &j->req, m_work, m_after);
    return lua_yield(L, 0);
  }
  char *err = NULL;
  char *text = doc_metadata(path, &err);
  if (!text) {
    lua_pushnil(L);
    lua_pushstring(L, err ? err : "cannot read");
    free(err);
    return 2;
  }
  lua_pushstring(L, text);
  free(text);
  return 1;
}

static int l_text(lua_State *L) {
  lua_Integer id = luaL_checkinteger(L, 1);
  int page = (int)luaL_optinteger(L, 2, 0);
  sqlite3_stmt *st = prep(L,
    "SELECT p.text FROM pages p WHERE p.file ="
    " (SELECT f.id FROM files f WHERE f.book = ?1 ORDER BY " DB_BOOK_FILE_ORDER("f.") " LIMIT 1)"
    " AND (?2 = 0 OR p.page = ?2) ORDER BY p.page");
  sqlite3_bind_int64(st, 1, id);
  sqlite3_bind_int(st, 2, page);
  luaL_Buffer b;
  luaL_buffinit(L, &b);
  int n = 0;
  while (sqlite3_step(st) == SQLITE_ROW) {
    if (n++) luaL_addchar(&b, '\f');
    const char *text = (const char *)sqlite3_column_text(st, 0);
    if (text) luaL_addlstring(&b, text, (size_t)sqlite3_column_bytes(st, 0));
  }
  sqlite3_finalize(st);
  luaL_pushresult(&b);
  if (n == 0) {
    lua_pop(L, 1);
    lua_pushnil(L);
  }
  return 1;
}

static void push_line(lua_State *L, const char *text, double size, unsigned flags, double x0,
                      double y0, double x1, double y1, const char *math) {
  static const struct { const char *name; unsigned bit; } bits[] = {
    {"bold", LINE_BOLD}, {"italic", LINE_ITALIC}, {"super", LINE_SUPER},
    {"rotated", LINE_ROTATED}, {"mono", LINE_MONO}, {"block", LINE_BLOCK},
  };
  lua_createtable(L, 0, 12);
  lua_pushstring(L, text);
  lua_setfield(L, -2, "text");
  lua_pushnumber(L, size);
  lua_setfield(L, -2, "size");
  for (size_t i = 0; i < ARRAY_LEN(bits); i++) {
    lua_pushboolean(L, (flags & bits[i].bit) != 0);
    lua_setfield(L, -2, bits[i].name);
  }
  lua_pushnumber(L, x0); lua_setfield(L, -2, "x0");
  lua_pushnumber(L, y0); lua_setfield(L, -2, "y0");
  lua_pushnumber(L, x1); lua_setfield(L, -2, "x1");
  lua_pushnumber(L, y1); lua_setfield(L, -2, "y1");
  if (math) {
    lua_pushstring(L, math);
    lua_setfield(L, -2, "math");
  }
}

static int l_lines(lua_State *L) {
  lua_Integer id = luaL_checkinteger(L, 1);
  int page = (int)luaL_optinteger(L, 2, 1);
  sqlite3_stmt *st = prep(L,
    "SELECT text, size, flags, x0, y0, x1, y1, math FROM lines WHERE file ="
    " (SELECT f.id FROM files f WHERE f.book = ?1 ORDER BY " DB_BOOK_FILE_ORDER("f.") " LIMIT 1)"
    " AND page = ?2 ORDER BY n");
  sqlite3_bind_int64(st, 1, id);
  sqlite3_bind_int(st, 2, page);
  lua_newtable(L);
  int i = 0;
  while (sqlite3_step(st) == SQLITE_ROW) {
    push_line(L, (const char *)sqlite3_column_text(st, 0), sqlite3_column_double(st, 1),
              (unsigned)sqlite3_column_int(st, 2), sqlite3_column_double(st, 3),
              sqlite3_column_double(st, 4), sqlite3_column_double(st, 5),
              sqlite3_column_double(st, 6), (const char *)sqlite3_column_text(st, 7));
    lua_rawseti(L, -2, ++i);
  }
  sqlite3_finalize(st);
  return 1;
}

static int l_files(lua_State *L) {
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

/* ---- lulibre.extract: the one function here that opens a book file ---- */

struct xjob {
  uv_work_t req;
  struct task *task;
  char *path, *format;
  struct doc_opts opts;
  struct doc_info info;
};

static void x_work(uv_work_t *req) {
  struct xjob *j = req->data;
  doc_extract(j->path, j->format, &j->opts, &j->info);
}

static void x_after(uv_work_t *req, int status) {
  static const char *const meta[DOC_META_N] = {"title", "author", "subject",
                                               "keywords", "creator", "producer"};
  struct xjob *j = req->data;
  lua_State *L = sched_end_job(j->task);
  if (L) {
    struct doc_info *d = &j->info;
    if (d->error) {
      lua_pushnil(L);
      lua_pushstring(L, d->error);
      sched_wake(j->task, 2);
    } else {
      lua_createtable(L, 0, 5);
      lua_pushinteger(L, d->npages);
      lua_setfield(L, -2, "pages");
      lua_pushinteger(L, d->nchars);
      lua_setfield(L, -2, "chars");
      lua_pushnumber(L, d->quality);
      lua_setfield(L, -2, "quality");
      lua_newtable(L);
      for (int k = 0; k < DOC_META_N; k++)
        if (d->meta[k]) {
          lua_pushstring(L, d->meta[k]);
          lua_setfield(L, -2, meta[k]);
        }
      lua_setfield(L, -2, "meta");
      lua_createtable(L, d->n, 0);
      for (int i = 0; i < d->n; i++) {
        struct doc_page *pg = &d->pages[i];
        lua_createtable(L, 0, 3);
        lua_pushstring(L, pg->text ? pg->text : "");
        lua_setfield(L, -2, "text");
        lua_pushinteger(L, pg->no);
        lua_setfield(L, -2, "no");
        lua_createtable(L, pg->nlines, 0);
        for (int k = 0; k < pg->nlines; k++) {
          struct doc_line *l = &pg->lines[k];
          push_line(L, l->text, l->size, l->flags, l->x0, l->y0, l->x1, l->y1, l->math);
          lua_rawseti(L, -2, k + 1);
        }
        lua_setfield(L, -2, "lines");
        lua_rawseti(L, -2, i + 1);
      }
      lua_setfield(L, -2, "page");
      sched_wake(j->task, 1);
    }
  }
  doc_info_free(&j->info);
  free(j->path);
  free(j->format);
  free(j);
}

static int l_extract(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  struct app *app = lapi_app(L);
  sched_require_task(L); /* raises outside a task, before anything is allocated */
  struct xjob *j = xcalloc(1, sizeof *j);
  j->opts = (struct doc_opts){(int)lapi_setting_int(L, S_PAGES), 0};
  if (lua_istable(L, 2)) {
    lua_getfield(L, 2, "pages");
    if (!lua_isnil(L, -1)) j->opts.pages = (int)lua_tointeger(L, -1);
    lua_getfield(L, 2, "tail");
    j->opts.tail = lua_toboolean(L, -1);
    lua_pop(L, 2);
  }
  j->path = xstrdup(path);
  j->format = xstrdup(path_ext(path));
  j->req.data = j;
  j->task = sched_begin_job(L);
  uv_queue_work(app->lloop, &j->req, x_work, x_after);
  return lua_yield(L, 0);
}

/* ---- lulibre.render ---- */

struct rjob {
  uv_work_t req;
  struct task *task;
  char *path;
  int page, width;
  struct doc_image img;
};

static void r_work(uv_work_t *req) {
  struct rjob *j = req->data;
  doc_render(j->path, j->page - 1, j->width, 1.0f, &j->img);
}

static void r_after(uv_work_t *req, int status) {
  struct rjob *j = req->data;
  lua_State *L = sched_end_job(j->task);
  if (L) {
    if (j->img.error || !j->img.rgba) {
      lua_pushnil(L);
      lua_pushstring(L, j->img.error ? j->img.error : "nothing rendered");
      sched_wake(j->task, 2);
    } else {
      luaL_Buffer b;
      size_t n = (size_t)j->img.w * (size_t)j->img.h;
      char head[64];
      int hl = snprintf(head, sizeof head, "P5\n%d %d\n255\n", j->img.w, j->img.h);
      char *out = luaL_buffinitsize(L, &b, n + (size_t)hl);
      memcpy(out, head, (size_t)hl);
      const unsigned char *px = j->img.rgba;
      unsigned char *g = (unsigned char *)out + hl;
      for (size_t i = 0; i < n; i++, px += 4)
        g[i] = (unsigned char)((px[0] * 3 + px[1] * 6 + px[2]) / 10);
      luaL_pushresultsize(&b, n + (size_t)hl);
      sched_wake(j->task, 1);
    }
  }
  doc_image_free(&j->img);
  free(j->path);
  free(j);
}

static int l_render(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  int page = (int)luaL_optinteger(L, 2, 1);
  int width = (int)luaL_optinteger(L, 3, 1700); /* about 200 dpi for a letter page */
  sched_require_task(L);
  struct rjob *j = xcalloc(1, sizeof *j);
  j->path = xstrdup(path);
  j->page = page;
  j->width = width;
  j->req.data = j;
  j->task = sched_begin_job(L);
  uv_queue_work(lapi_loop(L), &j->req, r_work, r_after);
  return lua_yield(L, 0);
}

/* ---- lulibre.page_put ---- */

void l_doc_open(lua_State *L) {
  static const luaL_Reg fns[] = {
    {"doc_metadata", l_doc_metadata}, {"text", l_text},     {"lines", l_lines},       {"files", l_files}, {"extract", l_extract},
    {"render", l_render}, {NULL, NULL},
  };
  luaL_setfuncs(L, fns, 0);
}
