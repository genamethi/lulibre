/* curl: requests through libcurl (core/curl.h) on the Lua thread's loop, a
 * module written in C, preloaded.
 *
 *   local curl = require "curl"
 *   local r, err = curl.request(url [, { method=, headers = { [name] = value },
 *                                        body=, timeout = ms }])
 *
 * waits, inside a task, for the answer: `{ status=, headers=, body=, url= }`
 * whatever the status (headers by lower-case name, repeated ones joined by
 * ", "; url, where it came from after redirects), or nil and why it did not
 * come. A cancelled task's request is cancelled with it. */
#include <ctype.h>
#include <stdlib.h>
#include <string.h>

#include <lua.h>
#include <lauxlib.h>

#include "app.h"
#include "core/curl.h"
#include "core/util.h"
#include "lua/lapi.h"
#include "lua/sched.h"

#define CURL_MT "curl.requests"

struct waiter {
  struct task *task;
  struct curl_uv_xfer *x;
};

/* "Name: value" lines into a table by lower-case name */
static void push_headers(lua_State *L, const char *s, size_t len) {
  lua_newtable(L);
  const char *end = s + len;
  while (s < end) {
    const char *eol = memchr(s, '\n', (size_t)(end - s));
    if (!eol) eol = end;
    const char *colon = memchr(s, ':', (size_t)(eol - s));
    if (colon && strncmp(s, "HTTP/", 5)) {
      luaL_Buffer name;
      luaL_buffinit(L, &name);
      for (const char *p = s; p < colon; p++) luaL_addchar(&name, (char)tolower((unsigned char)*p));
      luaL_pushresult(&name);
      const char *v = colon + 1, *ve = eol;
      while (v < ve && (*v == ' ' || *v == '\t')) v++;
      while (ve > v && (ve[-1] == '\r' || ve[-1] == ' ' || ve[-1] == '\t')) ve--;
      lua_pushvalue(L, -1);
      if (lua_rawget(L, -3) == LUA_TSTRING) {
        lua_pushliteral(L, ", ");
        lua_pushlstring(L, v, (size_t)(ve - v));
        lua_concat(L, 3);
      } else {
        lua_pop(L, 1);
        lua_pushlstring(L, v, (size_t)(ve - v));
      }
      lua_rawset(L, -3);
    }
    s = eol + 1;
  }
}

static void answered(const struct curl_uv_resp *r, const char *err, void *ud) {
  struct waiter *w = ud;
  lua_State *L = sched_end_wait(w->task);
  if (L) {
    if (r) {
      lua_createtable(L, 0, 4);
      lua_pushinteger(L, r->status);
      lua_setfield(L, -2, "status");
      push_headers(L, r->headers, r->headers_len);
      lua_setfield(L, -2, "headers");
      lua_pushlstring(L, r->body, r->body_len);
      lua_setfield(L, -2, "body");
      lua_pushstring(L, r->url);
      lua_setfield(L, -2, "url");
      sched_wake(w->task, 1);
    } else {
      lua_pushnil(L);
      lua_pushstring(L, err);
      sched_wake(w->task, 2);
    }
  }
  free(w);
}

static void cancel_cb(void *ud) {
  struct waiter *w = ud;
  curl_uv_cancel(w->x);
}

static int l_request(lua_State *L) {
  struct curl_uv *c = *(struct curl_uv **)luaL_checkudata(L, lua_upvalueindex(1), CURL_MT);
  struct curl_uv_req req = {.url = luaL_checkstring(L, 1)};
  if (!lua_isnoneornil(L, 2)) luaL_checktype(L, 2, LUA_TTABLE);
  sched_require_task(L);
  int nh = 0;
  char **headers = NULL;
  if (lua_istable(L, 2)) {
    lua_getfield(L, 2, "method");
    req.method = luaL_optstring(L, -1, NULL);
    lua_getfield(L, 2, "body");
    req.body = luaL_optlstring(L, -1, NULL, &req.body_len);
    lua_getfield(L, 2, "timeout");
    req.timeout_ms = (long)luaL_optinteger(L, -1, 0);
    if (lua_getfield(L, 2, "headers") == LUA_TTABLE) {
      lua_pushnil(L);
      while (lua_next(L, -2)) {
        if (lua_type(L, -2) == LUA_TSTRING && lua_isstring(L, -1)) {
          headers = xrealloc(headers, (size_t)(nh + 1) * sizeof *headers);
          headers[nh++] = xasprintf("%s: %s", lua_tostring(L, -2), lua_tostring(L, -1));
        }
        lua_pop(L, 1);
      }
    }
  }
  req.headers = (const char *const *)headers;
  req.nheaders = nh;
  struct waiter *w = xcalloc(1, sizeof *w);
  w->task = sched_begin_wait(L);
  w->x = curl_uv_start(c, &req, answered, w); /* copies what it keeps */
  for (int i = 0; i < nh; i++) free(headers[i]);
  free(headers);
  sched_on_cancel(w->task, cancel_cb, w);
  return lua_yield(L, 0);
}

static int requests_gc(lua_State *L) {
  struct curl_uv **c = luaL_checkudata(L, 1, CURL_MT);
  curl_uv_close(*c);
  *c = NULL;
  return 0;
}

int luaopen_curl(lua_State *L) {
  struct curl_uv **c = lua_newuserdatauv(L, sizeof *c, 0);
  *c = curl_uv_open(lapi_app(L)->lloop);
  if (luaL_newmetatable(L, CURL_MT)) {
    lua_pushcfunction(L, requests_gc);
    lua_setfield(L, -2, "__gc");
  }
  lua_setmetatable(L, -2);
  lua_newtable(L);
  lua_pushvalue(L, -2);
  lua_pushcclosure(L, l_request, 1);
  lua_setfield(L, -2, "request");
  return 1;
}
