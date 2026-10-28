/* SQL functions used by the filter language, on every connection the
 * process opens: lulibre's own, and those scripts open (lsqlite3).
 *
 *   ihas(hay, needle)      folded substring test
 *   ieq(a, b)              folded equality
 *   istarts(hay, prefix)   folded prefix test
 *   isubject(tag, subject) hierarchical: "number-theory" matches the tags
 *                          "math/number-theory" and "math/number-theory/additive"
 *   fold(s)                the search key itself
 *   lmatch(s, pattern)     Lua pattern match, i.e. string.find(s, pattern) ~= nil
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

enum { CMP_HAS, CMP_EQ, CMP_STARTS, CMP_SUBJECT };

static int subject_match(const char *tag, const char *subj) {
  size_t n = strlen(subj);
  if (n == 0) return 0;
  for (const char *p = tag; (p = strstr(p, subj)); p++) {
    int left = p == tag || p[-1] == '/';
    int right = p[n] == '\0' || p[n] == '/';
    if (left && right) return 1;
  }
  return 0;
}

static void fn_cmp(sqlite3_context *c, int argc, sqlite3_value **argv) {
  if (sqlite3_value_type(argv[0]) == SQLITE_NULL || sqlite3_value_type(argv[1]) == SQLITE_NULL) {
    sqlite3_result_int(c, 0);
    return;
  }
  sbuf a = SBUF_INIT, b = SBUF_INIT;
  folded(&a, argv[0]);
  folded(&b, argv[1]);
  int r = 0;
  switch ((int)(intptr_t)sqlite3_user_data(c)) {
    case CMP_HAS: r = strstr(a.s, b.s) != NULL; break;
    case CMP_EQ: r = strcmp(a.s, b.s) == 0; break;
    case CMP_STARTS: r = strncmp(a.s, b.s, b.len) == 0; break;
    case CMP_SUBJECT: r = subject_match(a.s, b.s); break;
  }
  sb_free(&a);
  sb_free(&b);
  sqlite3_result_int(c, r);
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
static void fn_lmatch(sqlite3_context *c, int argc, sqlite3_value **argv) {
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
  static const struct { const char *name; int kind; } cmp[] = {
    {"ihas", CMP_HAS}, {"ieq", CMP_EQ}, {"istarts", CMP_STARTS}, {"isubject", CMP_SUBJECT},
  };
  int flags = SQLITE_UTF8 | SQLITE_DETERMINISTIC;
  for (size_t i = 0; i < ARRAY_LEN(cmp); i++)
    if (sqlite3_create_function(h, cmp[i].name, 2, flags, (void *)(intptr_t)cmp[i].kind, fn_cmp, NULL, NULL) !=
        SQLITE_OK)
      goto fail;
  if (sqlite3_create_function(h, "fold", 1, flags, NULL, fn_fold, NULL, NULL) != SQLITE_OK) goto fail;
  /* lmatch's own Lua state, closed with the connection */
  lua_State *L = luaL_newstate();
  if (!L) goto fail;
  luaL_requiref(L, "string", luaopen_string, 0);
  lua_getfield(L, -1, "find");
  lua_remove(L, 1);
  if (sqlite3_create_function_v2(h, "lmatch", 2, flags, L, fn_lmatch, NULL, NULL, close_lua) != SQLITE_OK)
    goto fail;
  return SQLITE_OK;
fail:
  *errmsg = sqlite3_mprintf("registering lulibre's SQL functions: %s", sqlite3_errmsg(h));
  return SQLITE_ERROR;
}

void db_functions_everywhere(void) {
  sqlite3_auto_extension((void (*)(void))on_open); /* a second call is a no-op */
}
