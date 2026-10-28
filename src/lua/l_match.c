/* Matching helpers, the same ones the interface uses.
 *
 *   lulibre.fuzzy(query, candidate)  score (higher is better) or nil
 *
 * and expr.core, for expr (lua/expr.lua):
 *
 *   fold(s)          search key: lower case, accents stripped
 *   lower(s) upper(s) case, for more than ASCII: Latin with accents,
 *                    Greek, Cyrillic (Lua's string.lower knows only A to Z)
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

/* One letter's other case: simple one-to-one mappings for the Latin,
 * Greek and Cyrillic letters book titles are written in. */
static unsigned to_lower(unsigned c) {
  if (c < 0x80) return c >= 'A' && c <= 'Z' ? c + 32 : c;
  if (c >= 0xc0 && c <= 0xde && c != 0xd7) return c + 32;
  if (c == 0x178) return 0xff;
  if (c >= 0x100 && c <= 0x17f) {
    if (c == 0x130) return 'i';
    if ((c >= 0x139 && c <= 0x148) || (c >= 0x179 && c <= 0x17e)) return c & 1 ? c + 1 : c;
    if (c == 0x138 || c == 0x149 || c == 0x17f || c == 0x131) return c;
    return c & 1 ? c : c + 1;
  }
  if (c == 0x386) return 0x3ac;
  if (c >= 0x388 && c <= 0x38a) return c + 37;
  if (c == 0x38c) return 0x3cc;
  if (c == 0x38e || c == 0x38f) return c + 63;
  if (c >= 0x391 && c <= 0x3a9 && c != 0x3a2) return c + 32;
  if (c >= 0x400 && c <= 0x40f) return c + 80;
  if (c >= 0x410 && c <= 0x42f) return c + 32;
  return c;
}

static unsigned to_upper(unsigned c) {
  if (c < 0x80) return c >= 'a' && c <= 'z' ? c - 32 : c;
  if (c >= 0xe0 && c <= 0xfe && c != 0xf7) return c - 32;
  if (c == 0xff) return 0x178;
  if (c >= 0x100 && c <= 0x17f) {
    if (c == 0x131) return 'I';
    if ((c >= 0x139 && c <= 0x148) || (c >= 0x179 && c <= 0x17e)) return c & 1 ? c : c - 1;
    if (c == 0x138 || c == 0x149 || c == 0x17f || c == 0x130 || c == 0x178) return c;
    return c & 1 ? c - 1 : c;
  }
  if (c == 0x3ac) return 0x386;
  if (c >= 0x3ad && c <= 0x3af) return c - 37;
  if (c == 0x3cc) return 0x38c;
  if (c == 0x3cd || c == 0x3ce) return c - 63;
  if (c == 0x3c2) return 0x3a3; /* final sigma */
  if (c >= 0x3b1 && c <= 0x3c9) return c - 32;
  if (c >= 0x450 && c <= 0x45f) return c - 80;
  if (c >= 0x430 && c <= 0x44f) return c - 32;
  return c;
}

static int recase(lua_State *L, unsigned (*map)(unsigned)) {
  size_t n;
  const char *s = luaL_checklstring(L, 1, &n);
  sbuf out = SBUF_INIT;
  for (size_t i = 0; i < n;) {
    unsigned cp;
    int len = utf8_decode(s + i, n - i, &cp);
    unsigned to = map(cp);
    if (to == cp) {
      sb_putn(&out, s + i, (size_t)len); /* as it was, bytes that are not UTF-8 included */
    } else {
      char u[8];
      sb_putn(&out, u, (size_t)utf8_encode(u, to));
    }
    i += (size_t)len;
  }
  lua_pushlstring(L, out.s ? out.s : "", out.len);
  sb_free(&out);
  return 1;
}

static int l_lower(lua_State *L) {
  return recase(L, to_lower);
}

static int l_upper(lua_State *L) {
  return recase(L, to_upper);
}

void l_match_open(lua_State *L) {
  static const luaL_Reg fns[] = {{"fuzzy", l_fuzzy}, {NULL, NULL}};
  luaL_setfuncs(L, fns, 0);
}

int luaopen_expr_core(lua_State *L) {
  static const luaL_Reg fns[] = {{"fold", l_fold}, {"lower", l_lower}, {"upper", l_upper}, {NULL, NULL}};
  luaL_newlib(L, fns);
  return 1;
}
