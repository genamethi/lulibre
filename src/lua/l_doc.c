/* Text: what the index holds for a book, and extraction from arbitrary files.
 *
 *   lulibre.text(id [, page])    indexed text of one page, or of all indexed
 *                                pages joined by form feeds; nil if none
 *   lulibre.lines(id [, page])   the page (default 1) as lines:
 *                                { {text=, size=, bold=, italic=, super=,
 *                                   rotated=, mono=, block=, x0=, y0=, x1=, y1=}, ... }
 *   lulibre.files(id)            { {path=, format=, status=, pages=, chars=,
 *                                   quality=, error=, title=, author=, subject=,
 *                                   keywords=, creator=, producer=}, ... }
 *   lulibre.extract(path [, {pages=, layout_pages=}])
 *                                read a file now, off the main thread (waits):
 *                                { pages=N, chars=, quality=, meta={title=...},
 *                                  page={ {text=, lines={...}}, ... } } or nil, err
 *   lulibre.render(path, page [, width])
 *                                the page as a greyscale PGM image string, for
 *                                handing to tesseract (waits); or nil, err
 *   lulibre.page_put(id, page, {text=, lines=, src=})
 *                                replace the indexed text of a page, as the
 *                                OCR pass does. lines: {text=, size=, x0=...}
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <lua.h>
#include <lauxlib.h>

#include "app.h"
#include "core/util.h"
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

static int l_text(lua_State *L) {
  lua_Integer id = luaL_checkinteger(L, 1);
  int page = (int)luaL_optinteger(L, 2, 0);
  sqlite3_stmt *st = prep(L,
    "SELECT p.text FROM pages p WHERE p.file ="
    " (SELECT f.id FROM files f WHERE f.book = ?1 ORDER BY f.id LIMIT 1)"
    " AND (?2 = 0 OR p.page = ?2) ORDER BY p.page");
  sqlite3_bind_int64(st, 1, id);
  sqlite3_bind_int(st, 2, page);
  luaL_Buffer b;
  luaL_buffinit(L, &b);
  int n = 0;
  while (sqlite3_step(st) == SQLITE_ROW) {
    if (n++) luaL_addchar(&b, '\f');
    luaL_addlstring(&b, (const char *)sqlite3_column_text(st, 0),
                    (size_t)sqlite3_column_bytes(st, 0));
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
                      double y0, double x1, double y1) {
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
}

static int l_lines(lua_State *L) {
  lua_Integer id = luaL_checkinteger(L, 1);
  int page = (int)luaL_optinteger(L, 2, 1);
  sqlite3_stmt *st = prep(L,
    "SELECT text, size, flags, x0, y0, x1, y1 FROM lines WHERE file ="
    " (SELECT f.id FROM files f WHERE f.book = ?1 ORDER BY f.id LIMIT 1)"
    " AND page = ?2 ORDER BY n");
  sqlite3_bind_int64(st, 1, id);
  sqlite3_bind_int(st, 2, page);
  lua_newtable(L);
  int i = 0;
  while (sqlite3_step(st) == SQLITE_ROW) {
    push_line(L, (const char *)sqlite3_column_text(st, 0), sqlite3_column_double(st, 1),
              (unsigned)sqlite3_column_int(st, 2), sqlite3_column_double(st, 3),
              sqlite3_column_double(st, 4), sqlite3_column_double(st, 5),
              sqlite3_column_double(st, 6));
    lua_rawseti(L, -2, ++i);
  }
  sqlite3_finalize(st);
  return 1;
}

static int l_files(lua_State *L) {
  static const char *const status[] = {"pending", "indexed", "error", "missing"};
  static const char *const text_cols[] = {"path", "format", "error", "title", "author",
                                          "subject", "keywords", "creator", "producer"};
  lua_Integer id = luaL_checkinteger(L, 1);
  sqlite3_stmt *st = prep(L,
    "SELECT path, format, error, emb_title, emb_author, emb_subject, emb_keywords,"
    " emb_creator, emb_producer, status, npages, nchars, quality"
    " FROM files WHERE book = ? ORDER BY id");
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
    int s = sqlite3_column_int(st, 9);
    lua_pushstring(L, status[s >= 0 && s <= 3 ? s : 0]);
    lua_setfield(L, -2, "status");
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
  lua_State *L = sched_end_wait(j->task);
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
        lua_createtable(L, 0, 2);
        lua_pushstring(L, pg->text ? pg->text : "");
        lua_setfield(L, -2, "text");
        lua_createtable(L, pg->nlines, 0);
        for (int k = 0; k < pg->nlines; k++) {
          struct doc_line *l = &pg->lines[k];
          push_line(L, l->text, l->size, l->flags, l->x0, l->y0, l->x1, l->y1);
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
  struct xjob *j = xcalloc(1, sizeof *j);
  j->opts = (struct doc_opts){app->cfg.pages, app->cfg.layout_pages};
  if (lua_istable(L, 2)) {
    lua_getfield(L, 2, "pages");
    if (!lua_isnil(L, -1)) j->opts.pages = (int)lua_tointeger(L, -1);
    lua_getfield(L, 2, "layout_pages");
    if (!lua_isnil(L, -1)) j->opts.layout_pages = (int)lua_tointeger(L, -1);
    lua_pop(L, 2);
  }
  if (!sched_current_id(L)) {
    free(j);
    sched_require_task(L); /* raises */
  }
  j->path = xstrdup(path);
  j->format = xstrdup(path_ext(path));
  j->req.data = j;
  j->task = sched_begin_wait(L);
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
  lua_State *L = sched_end_wait(j->task);
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
  j->task = sched_begin_wait(L);
  uv_queue_work(lapi_loop(L), &j->req, r_work, r_after);
  return lua_yield(L, 0);
}

/* ---- lulibre.page_put ---- */

static double num_field(lua_State *L, int idx, const char *key) {
  lua_getfield(L, idx, key);
  double v = lua_tonumber(L, -1);
  lua_pop(L, 1);
  return v;
}

static int l_page_put(lua_State *L) {
  lua_Integer id = luaL_checkinteger(L, 1);
  int page = (int)luaL_checkinteger(L, 2);
  luaL_checktype(L, 3, LUA_TTABLE);
  sqlite3 *h = lapi_db(L)->h;
  sqlite3_stmt *st;

  sqlite3_int64 file = 0;
  if (sqlite3_prepare_v2(h, "SELECT id FROM files WHERE book = ? ORDER BY id LIMIT 1", -1, &st, NULL) == SQLITE_OK) {
    sqlite3_bind_int64(st, 1, id);
    if (sqlite3_step(st) == SQLITE_ROW) file = sqlite3_column_int64(st, 0);
    sqlite3_finalize(st);
  }
  if (!file) return luaL_error(L, "book %d has no file on record", (int)id);

  lua_getfield(L, 3, "text");
  size_t tlen;
  const char *text = luaL_optlstring(L, -1, "", &tlen);
  lua_getfield(L, 3, "src");
  const char *src = luaL_optstring(L, -1, "ocr");

  int own = sqlite3_get_autocommit(h);
  if (own) sqlite3_exec(h, "BEGIN IMMEDIATE", NULL, NULL, NULL);
  if (sqlite3_prepare_v2(h,
        "INSERT INTO pages(file, page, text, src) VALUES(?1, ?2, ?3, ?4)"
        " ON CONFLICT(file, page) DO UPDATE SET text = ?3, src = ?4", -1, &st, NULL) == SQLITE_OK) {
    sqlite3_bind_int64(st, 1, file);
    sqlite3_bind_int(st, 2, page);
    sqlite3_bind_text(st, 3, text, (int)tlen, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 4, src, -1, SQLITE_TRANSIENT);
    sqlite3_step(st);
    sqlite3_finalize(st);
  }
  lua_getfield(L, 3, "lines");
  if (lua_istable(L, -1)) {
    int lines = lua_gettop(L);
    if (sqlite3_prepare_v2(h, "DELETE FROM lines WHERE file = ? AND page = ?", -1, &st, NULL) == SQLITE_OK) {
      sqlite3_bind_int64(st, 1, file);
      sqlite3_bind_int(st, 2, page);
      sqlite3_step(st);
      sqlite3_finalize(st);
    }
    if (sqlite3_prepare_v2(h,
          "INSERT INTO lines(file, page, n, text, size, flags, x0, y0, x1, y1)"
          " VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", -1, &st, NULL) == SQLITE_OK) {
      lua_Integer n = (lua_Integer)lua_rawlen(L, lines);
      for (lua_Integer i = 1; i <= n; i++) {
        lua_rawgeti(L, lines, i);
        int l = lua_gettop(L);
        lua_getfield(L, l, "text");
        lua_getfield(L, l, "block");
        sqlite3_bind_int64(st, 1, file);
        sqlite3_bind_int(st, 2, page);
        sqlite3_bind_int64(st, 3, i - 1);
        sqlite3_bind_text(st, 4, lua_tostring(L, -2) ? lua_tostring(L, -2) : "", -1, SQLITE_TRANSIENT);
        sqlite3_bind_double(st, 5, num_field(L, l, "size"));
        sqlite3_bind_int(st, 6, lua_toboolean(L, -1) ? LINE_BLOCK : 0);
        sqlite3_bind_double(st, 7, num_field(L, l, "x0"));
        sqlite3_bind_double(st, 8, num_field(L, l, "y0"));
        sqlite3_bind_double(st, 9, num_field(L, l, "x1"));
        sqlite3_bind_double(st, 10, num_field(L, l, "y1"));
        sqlite3_step(st);
        sqlite3_reset(st);
        lua_settop(L, l - 1);
      }
      sqlite3_finalize(st);
    }
  }
  /* the file's totals follow its pages */
  sbuf all = SBUF_INIT;
  if (sqlite3_prepare_v2(h, "SELECT text FROM pages WHERE file = ? ORDER BY page", -1, &st, NULL) == SQLITE_OK) {
    sqlite3_bind_int64(st, 1, file);
    while (sqlite3_step(st) == SQLITE_ROW) {
      sb_puts(&all, (const char *)sqlite3_column_text(st, 0));
      sb_putc(&all, '\n');
    }
    sqlite3_finalize(st);
  }
  long nchars = 0;
  double quality = doc_text_quality(all.s ? all.s : "", &nchars);
  sb_free(&all);
  if (sqlite3_prepare_v2(h, "UPDATE files SET nchars = ?, quality = ?, text_src = ? WHERE id = ?", -1, &st, NULL) == SQLITE_OK) {
    sqlite3_bind_int64(st, 1, nchars);
    sqlite3_bind_double(st, 2, quality);
    sqlite3_bind_text(st, 3, src, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int64(st, 4, file);
    sqlite3_step(st);
    sqlite3_finalize(st);
  }
  if (own) sqlite3_exec(h, "COMMIT", NULL, NULL, NULL);
  return 0;
}

void l_doc_open(lua_State *L) {
  static const luaL_Reg fns[] = {
    {"text", l_text},     {"lines", l_lines},       {"files", l_files}, {"extract", l_extract},
    {"render", l_render}, {"page_put", l_page_put}, {NULL, NULL},
  };
  luaL_setfuncs(L, fns, 0);
}
