/* SQL functions, on every connection the process opens: lulibre's own,
 * and those scripts open (lsqlite3).
 *
 *   fold(s)          s without case, accents or styled letters: the key the
 *                    filter language compares by (match/fold.h)
 *   find(s, pattern) a Lua pattern match, string.find(s, pattern) ~= nil
 */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>

#include "core/util.h"
#include "db/db.h"
#include "match/fold.h"

static void folded(sbuf *out, sqlite3_value *v) {
  const char *s = (const char *)sqlite3_value_text(v);
  fold_utf8(out, s ? s : "", s ? (size_t)sqlite3_value_bytes(v) : 0);
}

static void fn_fold(sqlite3_context *c, int argc, sqlite3_value **argv) {
  if (sqlite3_value_type(argv[0]) == SQLITE_NULL) {
    sqlite3_result_null(c);
    return;
  }
  sbuf a = SBUF_INIT;
  folded(&a, argv[0]);
  sqlite3_result_text(c, a.s, (int)a.len, free);
}

/* Stack slot 1 of the private state permanently holds string.find. */
static void fn_find(sqlite3_context *c, int argc, sqlite3_value **argv) {
  lua_State *L = sqlite3_user_data(c);
  const char *s = (const char *)sqlite3_value_text(argv[0]);
  const char *p = (const char *)sqlite3_value_text(argv[1]);
  if (!s || !p) {
    sqlite3_result_int(c, 0);
    return;
  }
  lua_pushvalue(L, 1);
  lua_pushlstring(L, s, (size_t)sqlite3_value_bytes(argv[0]));
  lua_pushlstring(L, p, (size_t)sqlite3_value_bytes(argv[1]));
  if (lua_pcall(L, 2, 1, 0) != LUA_OK) {
    char *msg = xasprintf("bad Lua pattern: %s", lua_tostring(L, -1));
    sqlite3_result_error(c, msg, -1);
    free(msg);
  } else {
    sqlite3_result_int(c, lua_toboolean(L, -1));
  }
  lua_settop(L, 1);
}

static void close_lua(void *p) {
  lua_close(p);
}

/* On each connection as it opens (db_functions_everywhere). */
static int on_open(sqlite3 *h, char **errmsg, const struct sqlite3_api_routines *api) {
  (void)api;
  int flags = SQLITE_UTF8 | SQLITE_DETERMINISTIC;
  if (sqlite3_create_function(h, "fold", 1, flags, NULL, fn_fold, NULL, NULL) != SQLITE_OK) goto fail;
  /* find's own Lua state, closed with the connection */
  lua_State *L = luaL_newstate();
  if (!L) goto fail;
  luaL_requiref(L, "string", luaopen_string, 0);
  lua_getfield(L, -1, "find");
  lua_remove(L, 1);
  if (sqlite3_create_function_v2(h, "find", 2, flags, L, fn_find, NULL, NULL, close_lua) != SQLITE_OK)
    goto fail;
  return SQLITE_OK;
fail:
  *errmsg = sqlite3_mprintf("registering lulibre's SQL functions: %s", sqlite3_errmsg(h));
  return SQLITE_ERROR;
}

void db_functions_everywhere(void) {
  sqlite3_auto_extension((void (*)(void))on_open); /* a second call is a no-op */
}
