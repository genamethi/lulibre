/* mesr: one similarity for every field kind (design 22;
 * match/similar.h), a packaged module written in C.
 *
 *   mesr.score(kind, a, b)     0 to 1: how much of a is found in b
 *   mesr.compare(kind, a, b [, near, same])
 *                                 "equal" | "contains" | "contained" |
 *                                 "near" | "differs", then both scores;
 *                                 "contains": a holds all of b
 *
 *   mesr.canonical(type, value)  an identifier's canonical form, or nil
 *
 * kind: "text" (title, series, publisher), "people" (authors), "tags",
 * "date" ("1942", "1942-05", "1942-05-03"), "ident" ("type:value"). Words
 * are weighed by their rarity in the library, built again after calibre's
 * records are read again. The thresholds near and same are the settings
 * similar_near and similar_same when not passed: code that takes its
 * values once (design 3) passes them. */
#include <stdatomic.h>
#include <stdlib.h>

#include <lua.h>
#include <lauxlib.h>

#include "app.h"
#include "core/log.h"
#include "db/db.h"
#include "lua/lapi.h"
#include "match/similar.h"

/* The Lua thread's: built on first use and after each mirror copy. */
static struct rarity *rarity;
static unsigned built_at;
static int built;

static const struct rarity *weights(lua_State *L) {
  unsigned now = atomic_load(&db_mirror_copies);
  if (built && built_at == now) return rarity;
  char *err = NULL;
  struct rarity *w = rarity_build(lapi_db(L), &err);
  if (!w) {
    log_warn("the rarity of words: %s", err);
    free(err);
    return rarity;
  }
  rarity_free(rarity);
  rarity = w;
  built_at = now;
  built = 1;
  return rarity;
}

static enum field_kind check_kind(lua_State *L, int idx) {
  static const char *const kinds[] = {"text", "people", "tags", "date", "ident", NULL};
  return (enum field_kind)luaL_checkoption(L, idx, NULL, kinds);
}

static int l_score(lua_State *L) {
  enum field_kind kind = check_kind(L, 1);
  lua_pushnumber(L, similar(weights(L), kind, luaL_checkstring(L, 2), luaL_checkstring(L, 3)));
  return 1;
}

static int l_compare(lua_State *L) {
  enum field_kind kind = check_kind(L, 1);
  const char *a = luaL_checkstring(L, 2), *b = luaL_checkstring(L, 3);
  const struct rarity *w = weights(L);
  double ab = similar(w, kind, a, b), ba = similar(w, kind, b, a);
  double near, same;
  if (lua_isnumber(L, 4) && lua_isnumber(L, 5)) {
    near = lua_tonumber(L, 4);
    same = lua_tonumber(L, 5);
  } else {
    lua_getglobal(L, "setman");
    lua_getfield(L, -1, "get");
    lua_pushliteral(L, "similar_near");
    lua_pushliteral(L, "similar_same");
    lua_call(L, 2, 2);
    near = lua_tonumber(L, -2);
    same = lua_tonumber(L, -1);
    lua_pop(L, 3);
  }
  enum likeness k = likeness(ab, ba, near, same);
  const char *word = k == LIKE_EQUAL ? "equal" : k == LIKE_NEAR ? "near" : k == LIKE_DIFFERS ? "differs"
                     : ba >= same ? "contains" : "contained";
  lua_pushstring(L, word);
  lua_pushnumber(L, ab);
  lua_pushnumber(L, ba);
  return 3;
}

static int l_canonical(lua_State *L) {
  sbuf out = SBUF_INIT;
  if (ident_canonical(luaL_checkstring(L, 1), luaL_checkstring(L, 2), &out)) lua_pushnil(L);
  else lua_pushstring(L, out.s ? out.s : "");
  sb_free(&out);
  return 1;
}

int luaopen_mesr(lua_State *L) {
  static const luaL_Reg fns[] = {
    {"score", l_score}, {"compare", l_compare}, {"canonical", l_canonical}, {"fuzzy", l_mesr_fuzzy}, {NULL, NULL},
  };
  luaL_newlib(L, fns);
  return 1;
}
