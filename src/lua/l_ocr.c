/* utils.ocr_eng (core/registry.h, index/ocr.h, lua/handler.c): a reader of
 * Lua's in tesseract's place, called as a task for each page the indexer
 * is to read:
 *
 *   utils.ocr_eng = function(path, page, lang) ... end
 *
 * It returns the page's text (lines; a blank line before a paragraph), or
 * a list of lines {text=, size=, x0=, y0=, x1=, y1=, block=}, or nil when
 * it could not read the page. utils.ocr_eng = nil gives the pages back to
 * tesseract. */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <lua.h>
#include <lauxlib.h>

#include "app.h"
#include "core/queue.h"
#include "core/registry.h"
#include "core/util.h"
#include "doc/doc.h"
#include "index/ocr.h"
#include "lua/lapi.h"

static void answer_main(struct app *app, void *arg) { /* the indexer's: the background thread */
  struct ocr_req *r = arg;
  r->done(r);
}

static void fail(void *req, const char *why) {
  struct ocr_req *r = req;
  free(r->err);
  r->err = xstrdup(why);
  queue_post(LOOP_WORK, answer_main, r);
}

static float num(lua_State *L, int idx, const char *key, float dflt) {
  lua_getfield(L, idx, key);
  float v = lua_isnumber(L, -1) ? (float)lua_tonumber(L, -1) : dflt;
  lua_pop(L, 1);
  return v;
}

/* A page's answer: a string (lines, a blank line before a paragraph), or
 * a list of lines {text=, size=, x0=, y0=, x1=, y1=, block=}. */
static void page_of(lua_State *L, int idx, struct doc_page *pg) {
  if (lua_type(L, idx) == LUA_TSTRING) {
    const char *s = lua_tostring(L, idx);
    int block = 1;
    while (*s) {
      const char *nl = strchr(s, '\n');
      size_t n = nl ? (size_t)(nl - s) : strlen(s);
      if (n) {
        doc_page_add_line(pg, xstrndup(s, n), 0, block ? LINE_BLOCK : 0, 0, 0, 0, 0);
        block = 0;
      } else {
        block = 1;
      }
      s += n + (nl ? 1 : 0);
    }
    return;
  }
  int n = (int)lua_rawlen(L, idx);
  for (int i = 1; i <= n; i++) {
    lua_rawgeti(L, idx, i);
    int line = lua_gettop(L);
    lua_getfield(L, line, "text");
    lua_getfield(L, line, "block");
    if (lua_isstring(L, -2))
      doc_page_add_line(pg, xstrdup(lua_tostring(L, -2)), num(L, line, "size", 0),
                        lua_toboolean(L, -1) ? LINE_BLOCK : 0, num(L, line, "x0", 0), num(L, line, "y0", 0),
                        num(L, line, "x1", 0), num(L, line, "y1", 0));
    lua_settop(L, line - 1);
  }
}

/* a call per page: (path, page, lang), pages counted from 1 */
static void calls(lua_State *L, void *req) {
  struct ocr_req *r = req;
  lua_createtable(L, r->n, 0);
  for (int i = 0; i < r->n; i++) {
    lua_createtable(L, 3, 0);
    lua_pushstring(L, r->path);
    lua_rawseti(L, -2, 1);
    lua_pushinteger(L, r->pages[i] + 1);
    lua_rawseti(L, -2, 2);
    lua_pushstring(L, r->lang);
    lua_rawseti(L, -2, 3);
    lua_rawseti(L, -2, i + 1);
  }
}

static void answer(lua_State *L, void *req, int results, const char *why) {
  struct ocr_req *r = req;
  for (int i = 0; i < r->n; i++) {
    lua_rawgeti(L, results, i + 1);
    if (lua_istable(L, -1)) {
      lua_rawgeti(L, -1, 1);
      if (lua_isstring(L, -1) || lua_istable(L, -1)) {
        page_of(L, lua_gettop(L), &r->out[i]);
        r->ok[i] = 1;
      }
      lua_pop(L, 1);
    }
    lua_pop(L, 1);
  }
  if (why) r->err = xstrdup(why);
  queue_post(LOOP_WORK, answer_main, r);
}

static const struct lapi_part part = {REG_READER, "OCR (utils.ocr_eng)", calls, answer, fail};

void lapi_ocr_read(struct ocr_req *r) {
  lapi_handle(&part, r);
}

void l_ocr_open(lua_State *L) {
  static const struct lapi_handler fields[] = {{"ocr_eng", &part}, {NULL, NULL}};
  lapi_handlers(L, -1, fields);
}
