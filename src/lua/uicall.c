/* Calls into the interface as messages (design 1, 34).
 *
 * Lua does not block on the interface thread. A call that answers nothing
 * is sent: its arguments are copied into a message, and the interface runs
 * the call later, on a lua_State of its own that holds only those values.
 * A call that answers yields the task that made it, and the answer comes
 * back as a message that wakes the task. The values that cross are nil,
 * booleans, numbers, strings and tables of them; a function crosses as a
 * reference in the main lua_State's registry (an integer), which the
 * function on the other side keeps or releases. */
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

#include <lua.h>
#include <lauxlib.h>

#include "app.h"
#include "core/log.h"
#include "core/queue.h"
#include "core/util.h"
#include "lua/lapi.h"
#include "lua/sched.h"

/* ---- values as bytes ---- */

enum { V_NIL = 'n', V_TRUE = 'T', V_FALSE = 'F', V_INT = 'i', V_NUM = 'f', V_STR = 's', V_TABLE = 't', V_END = 'e', V_REF = 'r' };

static void put_raw(sbuf *b, const void *p, size_t n) {
  sb_putn(b, p, n);
}

/* refs: a light userdata is a reference into the main lua_State being
 * given back (ui_push_ref); only the interface's answers carry them */
static void put_value(lua_State *L, int idx, sbuf *b, int depth, int refs) {
  idx = lua_absindex(L, idx);
  switch (lua_type(L, idx)) {
  case LUA_TBOOLEAN:
    sb_putc(b, lua_toboolean(L, idx) ? V_TRUE : V_FALSE);
    return;
  case LUA_TNUMBER:
    if (lua_isinteger(L, idx)) {
      lua_Integer i = lua_tointeger(L, idx);
      sb_putc(b, V_INT);
      put_raw(b, &i, sizeof i);
    } else {
      lua_Number n = lua_tonumber(L, idx);
      sb_putc(b, V_NUM);
      put_raw(b, &n, sizeof n);
    }
    return;
  case LUA_TSTRING: {
    size_t len;
    const char *s = lua_tolstring(L, idx, &len);
    sb_putc(b, V_STR);
    put_raw(b, &len, sizeof len);
    put_raw(b, s, len);
    return;
  }
  case LUA_TTABLE:
    if (depth > 32) break;
    sb_putc(b, V_TABLE);
    lua_pushnil(L);
    while (lua_next(L, idx)) {
      put_value(L, -2, b, depth + 1, refs);
      put_value(L, -1, b, depth + 1, refs);
      lua_pop(L, 1);
    }
    sb_putc(b, V_END);
    return;
  case LUA_TFUNCTION: {
    lua_pushvalue(L, idx);
    lua_Integer ref = luaL_ref(L, LUA_REGISTRYINDEX);
    sb_putc(b, V_REF);
    put_raw(b, &ref, sizeof ref);
    return;
  }
  case LUA_TLIGHTUSERDATA:
    if (!refs) break;
    lua_Integer ref = (lua_Integer)(intptr_t)lua_touserdata(L, idx);
    sb_putc(b, V_REF);
    put_raw(b, &ref, sizeof ref);
    return;
  }
  sb_putc(b, V_NIL);
}

/* Pushes the value at *p onto L, and moves *p past it. With resolve (L is
 * the main lua_State's side), a reference is pushed as what it refers to;
 * else as its number. */
static void get_value(lua_State *L, const char **p, int resolve) {
  char tag = *(*p)++;
  switch (tag) {
  case V_TRUE:
  case V_FALSE:
    lua_pushboolean(L, tag == V_TRUE);
    return;
  case V_INT:
  case V_REF: {
    lua_Integer i;
    memcpy(&i, *p, sizeof i);
    *p += sizeof i;
    if (tag == V_REF && resolve) lua_rawgeti(L, LUA_REGISTRYINDEX, i);
    else lua_pushinteger(L, i);
    return;
  }
  case V_NUM: {
    lua_Number n;
    memcpy(&n, *p, sizeof n);
    *p += sizeof n;
    lua_pushnumber(L, n);
    return;
  }
  case V_STR: {
    size_t len;
    memcpy(&len, *p, sizeof len);
    *p += sizeof len;
    lua_pushlstring(L, *p, len);
    *p += len;
    return;
  }
  case V_TABLE:
    lua_newtable(L);
    while (**p != V_END) {
      get_value(L, p, resolve);
      get_value(L, p, resolve);
      if (lua_isnil(L, -2)) lua_pop(L, 2);
      else lua_rawset(L, -3);
    }
    (*p)++;
    return;
  }
  lua_pushnil(L);
}

/* The values from index first to the top of L, as bytes. */
static char *pack(lua_State *L, int first, int *n, size_t *len, int refs) {
  sbuf b = SBUF_INIT;
  int top = lua_gettop(L);
  for (int i = first; i <= top; i++) put_value(L, i, &b, 0, refs);
  *n = top >= first ? top - first + 1 : 0;
  *len = b.len;
  return sb_take(&b);
}

static void unpack(lua_State *L, const char *bytes, int n, int resolve) {
  luaL_checkstack(L, n, NULL);
  const char *p = bytes;
  for (int i = 0; i < n; i++) get_value(L, &p, resolve);
}

void ui_push_ref(lua_State *L, int ref) {
  lua_pushlightuserdata(L, (void *)(intptr_t)ref);
}

/* ---- the interface's own lua_State: values only ---- */

static lua_State *UL;
static struct lctx ui_ctx;

static lua_State *ui_state(struct app *app) {
  if (!UL) {
    UL = luaL_newstate();
    ui_ctx.app = app;
    *(struct lctx **)lua_getextraspace(UL) = &ui_ctx;
  }
  return UL;
}

struct call {
  lua_CFunction fn;
  const char *name;
  char *args;
  int nargs;
  struct task *task; /* an ask: the task waiting */
  /* the answer */
  int ok;
  char *results;
  int nresults;
};

static void answered(struct app *app, void *arg) { /* the Lua thread */
  struct call *c = arg;
  lua_State *L = sched_end_wait(c->task);
  if (L) {
    lua_pushboolean(L, c->ok);
    unpack(L, c->results, c->nresults, 1);
    sched_wake(c->task, c->nresults + 1);
  }
  free(c->results);
  free(c);
}

static void run(struct app *app, void *arg) { /* the interface thread */
  struct call *c = arg;
  lua_State *U = ui_state(app);
  lua_settop(U, 0);
  lua_pushcfunction(U, c->fn);
  unpack(U, c->args, c->nargs, 0);
  free(c->args);
  c->ok = lua_pcall(U, c->nargs, LUA_MULTRET, 0) == LUA_OK;
  if (!c->task) {
    if (!c->ok) {
      char *msg = xasprintf("uiman.%s: %s", c->name, lua_tostring(U, -1));
      lapi_report(app, 1, msg);
      free(msg);
    }
    lua_settop(U, 0);
    free(c);
    return;
  }
  size_t len;
  c->results = pack(U, 1, &c->nresults, &len, 1);
  lua_settop(U, 0);
  queue_post(LOOP_LUA, answered, c);
}

int ui_send(lua_State *L, lua_CFunction fn, const char *name) {
  struct call *c = xcalloc(1, sizeof *c);
  size_t len;
  c->fn = fn;
  c->name = name;
  c->args = pack(L, 1, &c->nargs, &len, 0);
  queue_post(LOOP_UI, run, c);
  return 0;
}

static int ask_k(lua_State *L, int status, lua_KContext base) {
  int first = (int)base + 1;
  if (!lua_toboolean(L, first)) return lua_error(L); /* the message is on top */
  return lua_gettop(L) - first;
}

int ui_ask(lua_State *L, lua_CFunction fn, const char *name) {
  sched_require_task(L);
  struct call *c = xcalloc(1, sizeof *c);
  size_t len;
  c->fn = fn;
  c->name = name;
  c->args = pack(L, 1, &c->nargs, &len, 0);
  int base = lua_gettop(L);
  c->task = sched_begin_wait(L);
  queue_post(LOOP_UI, run, c);
  return lua_yieldk(L, 0, (lua_KContext)base, ask_k);
}

void ui_state_close(void) {
  if (UL) lua_close(UL);
  UL = NULL;
}
