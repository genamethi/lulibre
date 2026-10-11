/* Matching helpers, the same ones the interface uses.
 *
 *   lulibre.fold(s)                  search key: lower case, accents stripped
 *   lulibre.fuzzy(query, candidate)  score (higher is better) or nil
 */
#include <string.h>

#include <lua.h>
#include <lauxlib.h>

#include "lua/lapi.h"
#include "match/fold.h"
#include "match/fuzzy.h"

static int l_fold(lua_State *L) {
  size_t n;
  const char *s = luaL_checklstring(L, 1, &n);
  sbuf out = SBUF_INIT;
  fold_utf8(&out, s, n);
  lua_pushlstring(L, out.s, out.len);
  sb_free(&out);
  return 1;
}

static int l_fuzzy(lua_State *L) {
  size_t qn, cn;
  const char *q = luaL_checklstring(L, 1, &qn);
  const char *c = luaL_checklstring(L, 2, &cn);
  sbuf fq = SBUF_INIT, fc = SBUF_INIT;
  fold_utf8(&fq, q, qn);
  fold_utf8(&fc, c, cn);
  double s = fuzzy_score(fq.s, fc.s);
  sb_free(&fq);
  sb_free(&fc);
  if (s <= FUZZY_NONE / 2) lua_pushnil(L);
  else lua_pushnumber(L, s);
  return 1;
}

void l_match_open(lua_State *L) {
  static const luaL_Reg fns[] = {{"fold", l_fold}, {"fuzzy", l_fuzzy}, {NULL, NULL}};
  luaL_setfuncs(L, fns, 0);
}
