/* setman: the settings (design 2, 3, 44, 45).
 *
 *   setman.get(name, ...)     the values in effect, in order
 *   setman.set(name, value)   a change; nil empties the API's value, and
 *                             the one below shows through
 *   setman.save()             write the saved state now (only while the
 *                             setting persistent is true)
 *
 * The store belongs to the main thread (core/settings.h). The lua_State
 * holds a copy, a table in its registry: get reads it and never waits, so
 * it works anywhere, an LPeg match-time function too. set changes the copy
 * at once and sends the change to the store; the store orders the changes
 * it receives and sends each value that changed back, so the copy ends on
 * the store's value. An emptied value reaches the copy only that way, one
 * turn of the loop later. A value sent back carries the number of the last
 * set the store had taken; the copy takes it only when no later set of the
 * same setting is still on its way, so two sets in a row do not show the
 * first again while the second travels. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <lua.h>
#include <lauxlib.h>

#include "app.h"
#include "core/log.h"
#include "core/queue.h"
#include "core/util.h"
#include "lua/lapi.h"

static const char COPY[] = "lulibre.settings";

struct setman_change {
  int def;
  unsigned long seq; /* the last set the store had taken */
  union setting_value v;
};

/* The Lua thread's: the number of the last set, and per setting the
 * number of its last set. */
static unsigned long seq, pending[S_COUNT];
/* The main thread's: the number of the last set the store took. */
static unsigned long taken;

static int is_text(const struct setting_def *d) {
  return d->type == SETTING_STR || d->type == SETTING_PATH;
}

static void push_value(lua_State *L, const struct setting_def *d, const union setting_value *v) {
  switch (d->type) {
  case SETTING_STR:
  case SETTING_PATH:
    lua_pushstring(L, v->s);
    break;
  case SETTING_INT:
    lua_pushinteger(L, v->i);
    break;
  case SETTING_NUM:
    lua_pushnumber(L, v->n);
    break;
  case SETTING_BOOL:
    lua_pushboolean(L, v->b);
    break;
  }
}

/* Writes the value into the copy. */
static void put(lua_State *L, int def, const union setting_value *v) {
  lua_getfield(L, LUA_REGISTRYINDEX, COPY);
  push_value(L, &setting_defs[def], v);
  lua_setfield(L, -2, setting_defs[def].name);
  lua_pop(L, 1);
}

static int find(const char *name) {
  for (int i = 0; i < S_COUNT; i++)
    if (!strcmp(setting_defs[i].name, name)) return i;
  return -1;
}

void l_setman_fill(lua_State *L, const struct settings *st) {
  lua_createtable(L, 0, S_COUNT);
  lua_setfield(L, LUA_REGISTRYINDEX, COPY);
  for (int i = 0; i < S_COUNT; i++) put(L, i, settings_value(st, i));
  memset(pending, 0, sizeof pending);
}

struct setman_change *setman_change_new(const struct settings *st, int def) {
  struct setman_change *c = xcalloc(1, sizeof *c);
  c->def = def;
  c->seq = taken;
  c->v = *settings_value(st, def);
  if (is_text(&setting_defs[def])) c->v.s = xstrdup(c->v.s);
  return c;
}

void l_setman_changed(struct app *app, void *arg) {
  struct setman_change *c = arg;
  if (app->L && c->seq >= pending[c->def]) {
    put(app->L, c->def, &c->v);
    if (c->def == S_MOD_TREE) lstate_paths(app->L);
  }
  if (is_text(&setting_defs[c->def])) free(c->v.s);
  free(c);
}

/* ---- on the main thread ---- */

struct to_store {
  int def;
  unsigned long seq;
  char *text; /* NULL: empty the API's value */
};

static void store_change(struct app *app, void *arg) {
  struct to_store *m = arg;
  taken = m->seq;
  const char *name = setting_defs[m->def].name;
  char *err = NULL;
  int rc = m->text ? settings_set(app->settings, name, m->text, FROM_API, &err)
                   : settings_unset(app->settings, name, FROM_API, &err);
  if (rc) {
    log_warn("setman.set: %s", err);
    free(err);
  }
  free(m->text);
  free(m);
}

static void store_save(struct app *app, void *arg) {
  char *err = NULL;
  if (settings_save_state(app->settings, app->state_path, &err)) {
    log_warn("%s", err);
    free(err);
  }
}

/* ---- the library ---- */

static int l_get(lua_State *L) {
  int n = lua_gettop(L);
  luaL_checkstack(L, n, NULL);
  lua_getfield(L, LUA_REGISTRYINDEX, COPY);
  for (int i = 1; i <= n; i++) {
    const char *name = luaL_checkstring(L, i);
    if (lua_getfield(L, n + 1, name) == LUA_TNIL) return luaL_error(L, "no setting is called %s", name);
  }
  return n;
}

static int l_set(lua_State *L) {
  const char *name = luaL_checkstring(L, 1);
  int def = find(name);
  if (def < 0) return luaL_error(L, "no setting is called %s", name);
  const struct setting_def *d = &setting_defs[def];
  if (d->flags & SETTING_CLI_ONLY) return luaL_error(L, "%s is set only on the command line", name);
  struct to_store *m = xcalloc(1, sizeof *m);
  m->def = def;
  int t = lua_type(L, 2);
  if (t != LUA_TNIL) {
    if (t != LUA_TSTRING && t != LUA_TNUMBER && t != LUA_TBOOLEAN) {
      free(m);
      return luaL_typeerror(L, 2, "string, number or boolean");
    }
    const char *text = luaL_tolstring(L, 2, NULL);
    union setting_value v;
    char *err = NULL;
    if (settings_parse(d, text, &v, &err)) {
      free(m);
      lua_pushstring(L, err);
      free(err);
      return lua_error(L);
    }
    m->text = xstrdup(text);
    put(L, def, &v);
    if (def == S_MOD_TREE) lstate_paths(L); /* the next require already searches it */
    if (is_text(d)) free(v.s);
  }
  m->seq = pending[def] = ++seq;
  queue_post(LOOP_UI, store_change, m);
  return 0;
}

static int l_save(lua_State *L) {
  queue_post(LOOP_UI, store_save, NULL);
  return 0;
}

int luaopen_setman(lua_State *L) {
  static const luaL_Reg fns[] = {{"get", l_get}, {"set", l_set}, {"save", l_save}, {NULL, NULL}};
  luaL_newlib(L, fns);
  return 1;
}

/* For C on the Lua thread: a value from the copy. */
long long lapi_setting_int(lua_State *L, enum setting_id id) {
  lua_getfield(L, LUA_REGISTRYINDEX, COPY);
  lua_getfield(L, -1, setting_defs[id].name);
  long long v = lua_isboolean(L, -1) ? lua_toboolean(L, -1) : lua_tointeger(L, -1);
  lua_pop(L, 2);
  return v;
}

char *lapi_setting_str(lua_State *L, enum setting_id id) {
  lua_getfield(L, LUA_REGISTRYINDEX, COPY);
  lua_getfield(L, -1, setting_defs[id].name);
  char *v = xstrdup(lua_isstring(L, -1) ? lua_tostring(L, -1) : "");
  lua_pop(L, 2);
  return v;
}
