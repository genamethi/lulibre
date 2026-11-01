/* A request from C that a task of Lua's answers (core/registry.h): the
 * reader in tesseract's place, the store in calibredb's. The task gets a
 * handle; the handle gives up its request once, to the function that
 * answers it. A handle not answered when it is closed or collected (the
 * task failed, was cancelled, or the lua_State went) fails its request, so
 * C never waits for an answer that cannot come. */
#include <lua.h>
#include <lauxlib.h>

#include "lua/lapi.h"

#define MT "lulibre.reply"

struct reply {
  void *req;
  lapi_reply_fail *fail;
};

static int m_close(lua_State *L) {
  struct reply *r = luaL_checkudata(L, 1, MT);
  if (r->req) {
    void *req = r->req;
    r->req = NULL;
    r->fail(req, "the task that was to answer ended without an answer");
  }
  return 0;
}

void lapi_push_reply(lua_State *L, void *req, lapi_reply_fail *fail) {
  struct reply *r = lua_newuserdatauv(L, sizeof *r, 0);
  r->req = req;
  r->fail = fail;
  if (luaL_newmetatable(L, MT)) {
    lua_pushcfunction(L, m_close);
    lua_setfield(L, -2, "__close");
    lua_pushcfunction(L, m_close);
    lua_setfield(L, -2, "__gc");
  }
  lua_setmetatable(L, -2);
}

void *lapi_take_reply(lua_State *L, int idx) {
  struct reply *r = luaL_checkudata(L, idx, MT);
  if (!r->req) luaL_error(L, "this request has been answered");
  void *req = r->req;
  r->req = NULL;
  return req;
}
