/* lulibre.ocr's C side (core/registry.h, index/ocr.h): whether Lua has put
 * a reader in tesseract's place, and the way a request goes to it and its
 * answer comes back. lua/lulibre/ocr.lua is the module a user redefines
 * read in. */
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
#include "lua/sched.h"

static void answer_main(struct app *app, void *arg) { /* the indexer's loop */
  struct ocr_req *r = arg;
  r->done(r);
}

static void fail(void *req, const char *why) {
  struct ocr_req *r = req;
  free(r->err);
  r->err = xstrdup(why);
  queue_post(LOOP_UI, answer_main, r);
}

/* The Lua thread: lulibre.ocr._run(handle, path, pages, lang) as a task. */
static void start(struct app *app, void *arg) {
  struct ocr_req *r = arg;
  lua_State *L = app->L;
  if (!L) {
    fail(r, "no lua_State: the scripts are restarting");
    return;
  }
  lua_getglobal(L, "require");
  lua_pushliteral(L, "lulibre.ocr");
  if (lua_pcall(L, 1, 1, 0) != LUA_OK) {
    fail(r, lua_tostring(L, -1));
    lua_pop(L, 1);
    return;
  }
  lua_getfield(L, -1, "_run");
  lua_remove(L, -2);
  lapi_push_reply(L, r, fail);
  lua_pushstring(L, r->path);
  lua_createtable(L, r->n, 0);
  for (int i = 0; i < r->n; i++) {
    lua_pushinteger(L, r->pages[i] + 1);
    lua_rawseti(L, -2, i + 1);
  }
  lua_pushstring(L, r->lang);
  sched_spawn(L, 4, "OCR (lulibre.ocr.read)");
}

void lapi_ocr_read(struct ocr_req *r) {
  queue_post(LOOP_LUA, start, r);
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

/* answer(handle, results [, err]): results[i], page i's answer or false */
static int l_answer(lua_State *L) {
  struct ocr_req *r = lapi_take_reply(L, 1);
  if (lua_istable(L, 2))
    for (int i = 0; i < r->n; i++) {
      lua_rawgeti(L, 2, i + 1);
      if (lua_isstring(L, -1) || lua_istable(L, -1)) {
        page_of(L, lua_gettop(L), &r->out[i]);
        r->ok[i] = 1;
      }
      lua_pop(L, 1);
    }
  if (lua_isstring(L, 3)) r->err = xstrdup(lua_tostring(L, 3));
  queue_post(LOOP_UI, answer_main, r);
  return 0;
}

static int l_filled(lua_State *L) {
  registry_set_lua(REG_READER, lua_toboolean(L, 1));
  return 0;
}

int luaopen_lulibre_ocr_core(lua_State *L) {
  static const luaL_Reg fns[] = {{"answer", l_answer}, {"filled", l_filled}, {NULL, NULL}};
  luaL_newlib(L, fns);
  return 1;
}
