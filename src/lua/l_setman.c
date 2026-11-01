/* setman: the settings (design 2, 3, 44, 45).
 *
 *   setman.get(name, ...)     the values in effect, in order; a path.*
 *                             setting left empty is the path C works out
 *                             (path.indexdb: the index file in use)
 *   setman.set(name, value)   a change; nil empties the value set, and
 *                             the saved state's or the default shows
 *                             through. What init.lua sets before it first
 *                             waits lies under the command line (design
 *                             44); a set after that replaces the command
 *                             line's value
 *   setman.save()             write the saved state now (only while the
 *                             setting persistent is true)
 *   setman.create(name, spec) a setting of the script's own (l_create)
 *   setman.info(name)         a setting's definition, value and where the
 *                             value comes from
 *   setman.ls()               every setting's name
 *   lulib.opt                 the settings as a table, as vim.opt: a name
 *                             read is get, a name assigned is set,
 *                             path.library and the like as written; any
 *                             other name is the table's own field
 *
 * Two names are the handlers C calls, not settings in the store: ocr_eng
 * is utils.ocr_eng and store.calibre is store.calibre. get and set read
 * and assign that field; the command line and the saved state know
 * nothing of them.
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
#include "db/db.h"
#include "lua/lapi.h"

static const char COPY[] = "lulibre.settings";

struct setman_change {
  int def;
  enum setting_type type;
  enum setting_origin from;
  unsigned long seq; /* the last set the store had taken */
  union setting_value v;
};

/* The Lua thread's: every setting the copy has, lulibre's first, then
 * those made in Lua (setman.create), in the store's order; per setting the
 * number of its last set, whether the command line holds it (so a set
 * while init.lua starts does not show in the copy) and where its value
 * comes from. Kept across :restart-scripts, as the store keeps them. */
struct known {
  struct setting_def d; /* a made one's strings are its own */
  unsigned long pending;
  int held;
  enum setting_origin from;
};
static struct known *K;
static int nK;
/* values given for names no setting has yet, as the store held them when
 * the copy was filled: what setman.create finds for its name at start */
static struct {
  char *name, *text;
  enum setting_origin from;
} *early;
static int nearly;
static unsigned long seq;
static int starting;
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
  push_value(L, &K[def].d, v);
  lua_setfield(L, -2, K[def].d.name);
  lua_pop(L, 1);
}

/* the handlers get and set reach: a name, the module, the field */
static const char *const aliases[][3] = {{"ocr_eng", "utils", "ocr_eng"}, {"store.calibre", "store", "calibre"}};
#define NALIASES (sizeof aliases / sizeof aliases[0])

static int alias(const char *name) {
  for (size_t i = 0; i < NALIASES; i++)
    if (!strcmp(aliases[i][0], name)) return (int)i;
  return -1;
}

/* pushes the table alias a's handler is a field of: a global (utils), or
 * else a module */
static void push_module(lua_State *L, int a) {
  if (lua_getglobal(L, aliases[a][1]) != LUA_TNIL) return;
  lua_pop(L, 1);
  lua_getglobal(L, "require");
  lua_pushstring(L, aliases[a][1]);
  lua_call(L, 1, 1);
}

static int find(const char *name) {
  for (int i = 0; i < nK; i++)
    if (!strcmp(K[i].d.name, name)) return i;
  return -1;
}

static void def_copy(struct setting_def *to, const struct setting_def *d) {
  *to = *d;
  if (!(d->flags & SETTING_MADE)) return;
  to->name = xstrdup(d->name);
  to->dflt = xstrdup(d->dflt);
  to->choices = d->choices ? xstrdup(d->choices) : NULL;
  to->help = xstrdup(d->help);
}

static void def_drop(struct setting_def *d) {
  if (!(d->flags & SETTING_MADE)) return;
  free((char *)d->name);
  free((char *)d->dflt);
  free((char *)d->choices);
  free((char *)d->help);
}

/* on the main thread, with no Lua thread running: the store is read */
void l_setman_fill(lua_State *L, const struct settings *st) {
  for (int i = 0; i < nK; i++) def_drop(&K[i].d);
  for (int i = 0; i < nearly; i++) {
    free(early[i].name);
    free(early[i].text);
  }
  nK = settings_count(st);
  K = xrealloc(K, (size_t)nK * sizeof *K);
  lua_createtable(L, 0, nK);
  lua_setfield(L, LUA_REGISTRYINDEX, COPY);
  for (int i = 0; i < nK; i++) {
    def_copy(&K[i].d, settings_def(st, i));
    K[i].pending = 0;
    K[i].from = settings_origin(st, i);
    K[i].held = K[i].from == FROM_CLI;
    put(L, i, settings_value(st, i));
  }
  const char *name, *text;
  enum setting_origin from;
  for (nearly = 0; settings_held(st, nearly, &name, &text, &from);) {
    early = xrealloc(early, (size_t)(nearly + 1) * sizeof *early);
    early[nearly].name = xstrdup(name);
    early[nearly].text = xstrdup(text);
    early[nearly++].from = from;
  }
}

void l_setman_starting(int on) {
  starting = on;
}

struct setman_change *setman_change_new(const struct settings *st, int def) {
  struct setman_change *c = xcalloc(1, sizeof *c);
  const struct setting_def *d = settings_def(st, def);
  c->def = def;
  c->type = d->type;
  c->from = settings_origin(st, def);
  c->seq = taken;
  c->v = *settings_value(st, def);
  if (is_text(d)) c->v.s = xstrdup(c->v.s);
  return c;
}

void l_setman_changed(struct app *app, void *arg) {
  struct setman_change *c = arg;
  if (app->L && c->def < nK && K[c->def].d.type == c->type) {
    K[c->def].from = c->from;
    if (c->seq >= K[c->def].pending) {
      put(app->L, c->def, &c->v);
      if (c->def == S_MOD_TREE) lstate_paths(app->L);
    }
  }
  if (c->type == SETTING_STR || c->type == SETTING_PATH) free(c->v.s);
  free(c);
}

/* ---- on the main thread ---- */

struct to_store {
  int def;
  unsigned long seq;
  char *text;   /* NULL: empty the value set */
  int starting; /* set by init.lua at start: under the command line */
};

static void store_change(struct app *app, void *arg) {
  struct to_store *m = arg;
  taken = m->seq;
  const char *name = settings_def(app->settings, m->def)->name;
  char *err = NULL;
  int rc = !m->starting ? settings_change(app->settings, name, m->text, &err)
           : m->text    ? settings_set(app->settings, name, m->text, FROM_API, &err)
                        : settings_unset(app->settings, name, FROM_API, &err);
  if (rc) {
    log_warn("setman.set: %s", err);
    free(err);
  }
  free(m->text);
  free(m);
}

static void store_define(struct app *app, void *arg) {
  struct setting_def *d = arg;
  char *err = NULL;
  if (settings_define(app->settings, d, &err) < 0) {
    log_warn("setman.create: %s", err);
    free(err);
  }
  def_drop(d);
  free(d);
}

static void store_save(struct app *app, void *arg) {
  char *err = NULL;
  if (settings_save_state(app->settings, app->state_path, &err)) {
    log_warn("%s", err);
    free(err);
  }
}

/* ---- the library ---- */

/* An empty path.* setting as the path C works out; 0 for one with no
 * default (path.log: no log file). */
static int push_worked_out(lua_State *L, const char *name) {
  struct app *app = lapi_app(L);
  static const char *const side[][2] = {{"path.journaldb", "journal"}, {"path.customdb", "custom"}, {"path.witdb", "wit"}};
  char *p = NULL;
  if (!strcmp(name, "path.indexdb")) p = xstrdup(lapi_db(L)->path);
  else if (!strcmp(name, "path.config")) p = xstrdup(app->config_dir);
  else if (!strcmp(name, "path.state")) p = xstrdup(app->state_path);
  else if (!strcmp(name, "path.crash")) p = xstrdup(crash_file());
  else if (!strcmp(name, "path.netdb")) {
    char *dir = path_xdg("XDG_DATA_HOME", "~/.local/share/lulibre");
    p = xasprintf("%s/net.db", dir);
    free(dir);
  }
  for (size_t i = 0; !p && i < sizeof side / sizeof side[0]; i++)
    if (!strcmp(name, side[i][0])) p = db_side_path(lapi_db(L)->path, side[i][1]);
  if (!p) return 0;
  lua_pushstring(L, p);
  free(p);
  return 1;
}

static int l_get(lua_State *L) {
  int n = lua_gettop(L);
  luaL_checkstack(L, n + 2, NULL);
  lua_getfield(L, LUA_REGISTRYINDEX, COPY);
  for (int i = 1; i <= n; i++) {
    const char *name = luaL_checkstring(L, i);
    int a = alias(name);
    if (a >= 0) {
      push_module(L, a);
      lua_getfield(L, -1, aliases[a][2]);
      lua_remove(L, -2);
      continue;
    }
    if (lua_getfield(L, n + 1, name) == LUA_TNIL) return luaL_error(L, "no setting is called %s", name);
    if (!strncmp(name, "path.", 5) && !*lua_tostring(L, -1) && push_worked_out(L, name)) lua_remove(L, -2);
  }
  return n;
}

static int l_set(lua_State *L) {
  const char *name = luaL_checkstring(L, 1);
  int a = alias(name);
  if (a >= 0) {
    lua_settop(L, 2);
    push_module(L, a);
    lua_insert(L, 2);
    lua_setfield(L, 2, aliases[a][2]);
    return 0;
  }
  int def = find(name);
  if (def < 0) return luaL_error(L, "no setting is called %s", name);
  const struct setting_def *d = &K[def].d;
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
    if (!(starting && K[def].held)) {
      put(L, def, &v);
      K[def].from = FROM_API;
    }
    if (def == S_MOD_TREE) lstate_paths(L); /* the next require already searches it */
    if (is_text(d)) free(v.s);
  }
  m->starting = starting;
  m->seq = K[def].pending = ++seq;
  queue_post(LOOP_UI, store_change, m);
  return 0;
}

/* lulib.opt, and a part of it: the settings whose names begin with the
 * prefix, its upvalue. A setting's name read is setman.get, a name some
 * settings begin with (path) the part of them, kept in the table; a name
 * assigned is setman.set. Any other name is the table's own field, as in
 * any table. */
static void push_part(lua_State *L, const char *prefix);

/* f(name[, value]) from a metamethod: an error says where the assignment
 * or the read is */
static int call_at(lua_State *L, lua_CFunction f, int nargs, int nres) {
  lua_pushcfunction(L, f);
  lua_insert(L, -nargs - 1);
  if (lua_pcall(L, nargs, nres, 0) != LUA_OK) {
    luaL_where(L, 1);
    lua_insert(L, -2);
    lua_concat(L, 2);
    return lua_error(L);
  }
  return nres;
}

/* 1: name is a setting or a handler; 2: some begin with name and a dot */
static int known(const char *name) {
  if (find(name) >= 0 || alias(name) >= 0) return 1;
  size_t n = strlen(name);
  for (int i = 0; i < nK; i++)
    if (!strncmp(K[i].d.name, name, n) && K[i].d.name[n] == '.') return 2;
  for (size_t i = 0; i < NALIASES; i++)
    if (!strncmp(aliases[i][0], name, n) && aliases[i][0][n] == '.') return 2;
  return 0;
}

static int part_index(lua_State *L) {
  const char *prefix = lua_tostring(L, lua_upvalueindex(1));
  if (lua_type(L, 2) != LUA_TSTRING) return 0;
  const char *name = lua_pushfstring(L, "%s%s", prefix, lua_tostring(L, 2));
  switch (known(name)) {
  case 1:
    return call_at(L, l_get, 1, 1);
  case 2:
    lua_pushfstring(L, "%s.", name);
    push_part(L, lua_tostring(L, -1));
    lua_pushvalue(L, 2);
    lua_pushvalue(L, -2);
    lua_rawset(L, 1);
    return 1;
  }
  return 0;
}

static int part_newindex(lua_State *L) {
  const char *prefix = lua_tostring(L, lua_upvalueindex(1));
  if (lua_type(L, 2) == LUA_TSTRING) {
    const char *name = lua_pushfstring(L, "%s%s", prefix, lua_tostring(L, 2));
    if (known(name) == 1) {
      lua_pushvalue(L, 3);
      return call_at(L, l_set, 2, 0);
    }
    lua_pop(L, 1);
  }
  lua_rawset(L, 1);
  return 0;
}

static void push_part(lua_State *L, const char *prefix) {
  lua_newtable(L);
  lua_createtable(L, 0, 2);
  lua_pushstring(L, prefix);
  lua_pushcclosure(L, part_index, 1);
  lua_setfield(L, -2, "__index");
  lua_pushstring(L, prefix);
  lua_pushcclosure(L, part_newindex, 1);
  lua_setfield(L, -2, "__newindex");
  lua_setmetatable(L, -2);
}

void l_setman_push_opt(lua_State *L) {
  push_part(L, "");
}

/* ---- settings made in Lua ---- */

static const char *const type_names[] = {[SETTING_STR] = "string", [SETTING_INT] = "integer",
                                         [SETTING_BOOL] = "boolean", [SETTING_NUM] = "number",
                                         [SETTING_PATH] = "path"};
static const char *const origin_names[] = {[FROM_DEFAULT] = "default", [FROM_STATE] = "saved", [FROM_API] = "set",
                                           [FROM_CLI] = "command line"};

/* setman.create(name, {type=, default=, choices=, help=}): a setting of the
 * script's own, which setman, lulib.opt, :set, -o and the saved state know
 * as they know lulibre's. type: string (by default, or as the default
 * is), path, integer, number, boolean. Made again under its name, its
 * definition is replaced and its value stays when it is still one. */
static int l_create(lua_State *L) {
  const char *name = luaL_checkstring(L, 1);
  luaL_argcheck(L, *name && !strpbrk(name, " =\t\n"), 1, "a setting's name is one word, without =");
  luaL_checktype(L, 2, LUA_TTABLE);
  int i = find(name);
  if (alias(name) >= 0 || (i >= 0 && !(K[i].d.flags & SETTING_MADE)))
    return luaL_error(L, "%s is one of lulibre's own settings", name);
  struct setting_def d = {name, SETTING_STR, SETTING_MADE, "", NULL, ""};
  lua_getfield(L, 2, "default");
  lua_getfield(L, 2, "type");
  if (lua_isstring(L, -1)) {
    int t = -1;
    for (int k = 0; k < (int)ARRAY_LEN(type_names); k++)
      if (!strcmp(type_names[k], lua_tostring(L, -1))) t = k;
    if (t < 0) return luaL_error(L, "type: string, path, integer, number or boolean");
    d.type = t;
  } else if (lua_isboolean(L, 3)) {
    d.type = SETTING_BOOL;
  } else if (lua_isinteger(L, 3)) {
    d.type = SETTING_INT;
  } else if (lua_type(L, 3) == LUA_TNUMBER) {
    d.type = SETTING_NUM;
  }
  if (!lua_isnil(L, 3)) d.dflt = luaL_tolstring(L, 3, NULL); /* stays on the stack */
  else d.dflt = d.type == SETTING_BOOL ? "false" : d.type == SETTING_INT || d.type == SETTING_NUM ? "0" : "";
  lua_getfield(L, 2, "help");
  if (!lua_isnil(L, -1)) d.help = luaL_checkstring(L, -1);
  lua_getfield(L, 2, "choices");
  sbuf choices = SBUF_INIT;
  if (lua_istable(L, -1)) {
    for (lua_Integer k = 1; k <= (lua_Integer)lua_rawlen(L, -1); k++) {
      lua_rawgeti(L, -1, k);
      sb_printf(&choices, "%s%s", k > 1 ? "|" : "", luaL_tolstring(L, -1, NULL));
      lua_pop(L, 2);
    }
    d.choices = choices.s ? choices.s : "";
  } else if (!lua_isnil(L, -1)) {
    sb_free(&choices);
    return luaL_error(L, "choices: a list of the values it takes");
  }
  union setting_value v;
  char *err = NULL;
  if (settings_parse(&d, d.dflt, &v, &err)) {
    sb_free(&choices);
    lua_pushfstring(L, "the default of %s", err);
    free(err);
    return lua_error(L);
  }
  if (is_text(&d)) free(v.s);
  /* the copy: as it was when it is still a value, else what the command
   * line (or the saved state) gave for it before it was made, else the
   * default; a value that is none of it is the store's to refuse */
  const char *now = d.dflt;
  enum setting_origin from = FROM_DEFAULT;
  if (i < 0) { /* the command line's, else the saved state's while it counts */
    int persist = find("persistent");
    lua_getfield(L, LUA_REGISTRYINDEX, COPY);
    lua_getfield(L, -1, "persistent");
    int saved = persist >= 0 && lua_toboolean(L, -1);
    lua_pop(L, 2);
    for (int k = 0; k < nearly; k++) {
      if (strcmp(early[k].name, name) || from == FROM_CLI) continue;
      if (early[k].from == FROM_CLI || (early[k].from == FROM_STATE && saved)) now = early[k].text, from = early[k].from;
    }
  } else {
    lua_getfield(L, LUA_REGISTRYINDEX, COPY);
    lua_getfield(L, -1, name);
    const char *was = luaL_tolstring(L, -1, NULL);
    if (!settings_parse(&d, was, &v, &err)) {
      if (is_text(&d)) free(v.s);
      now = was;
      from = K[i].from;
    }
    free(err);
    err = NULL;
  }
  if (i < 0) {
    K = xrealloc(K, (size_t)(nK + 1) * sizeof *K);
    i = nK++;
  } else {
    def_drop(&K[i].d);
  }
  def_copy(&K[i].d, &d);
  if (settings_parse(&d, now, &v, &err)) { /* given before, and no value of it: the store says so */
    free(err);
    err = NULL;
    settings_parse(&d, d.dflt, &v, &err);
    from = FROM_DEFAULT;
  }
  K[i].pending = 0;
  K[i].from = from;
  K[i].held = from == FROM_CLI;
  put(L, i, &v);
  if (is_text(&d)) free(v.s);
  struct setting_def *m = xcalloc(1, sizeof *m);
  def_copy(m, &d);
  sb_free(&choices);
  queue_post(LOOP_UI, store_define, m);
  return 0;
}

/* setman.ls(): every setting's name, lulibre's first */
static int l_ls(lua_State *L) {
  lua_createtable(L, nK, 0);
  for (int i = 0; i < nK; i++) {
    lua_pushstring(L, K[i].d.name);
    lua_rawseti(L, -2, i + 1);
  }
  return 1;
}

/* setman.info(name): {name=, type=, default=, choices=, help=, value=,
 * from=, made=, fixed=}; from: default, saved, set (init.lua, a script,
 * :set) or command line; made: made in Lua; fixed: set on the command line
 * only. nil and why for no such setting. */
static int l_info(lua_State *L) {
  const char *name = luaL_checkstring(L, 1);
  int i = find(name);
  if (i < 0) {
    lua_pushnil(L);
    lua_pushfstring(L, "no setting is called %s", name);
    return 2;
  }
  const struct setting_def *d = &K[i].d;
  lua_createtable(L, 0, 8);
  lua_pushstring(L, d->name);
  lua_setfield(L, -2, "name");
  lua_pushstring(L, type_names[d->type]);
  lua_setfield(L, -2, "type");
  union setting_value v;
  char *err = NULL;
  if (!settings_parse(d, d->dflt, &v, &err)) {
    push_value(L, d, &v);
    lua_setfield(L, -2, "default");
    if (is_text(d)) free(v.s);
  }
  free(err);
  if (d->choices) {
    lua_newtable(L);
    int k = 0;
    for (const char *c = d->choices; *c;) {
      size_t n = strcspn(c, "|");
      lua_pushlstring(L, c, n);
      lua_rawseti(L, -2, ++k);
      c += n + (c[n] == '|');
    }
    lua_setfield(L, -2, "choices");
  }
  lua_pushstring(L, d->help ? d->help : "");
  lua_setfield(L, -2, "help");
  lua_getfield(L, LUA_REGISTRYINDEX, COPY);
  lua_getfield(L, -1, name);
  lua_setfield(L, -3, "value");
  lua_pop(L, 1);
  lua_pushstring(L, origin_names[K[i].from]);
  lua_setfield(L, -2, "from");
  lua_pushboolean(L, (d->flags & SETTING_MADE) != 0);
  lua_setfield(L, -2, "made");
  lua_pushboolean(L, (d->flags & SETTING_CLI_ONLY) != 0);
  lua_setfield(L, -2, "fixed");
  return 1;
}

static int l_save(lua_State *L) {
  queue_post(LOOP_UI, store_save, NULL);
  return 0;
}

int luaopen_setman(lua_State *L) {
  static const luaL_Reg fns[] = {{"get", l_get},   {"set", l_set}, {"save", l_save}, {"create", l_create},
                                 {"info", l_info}, {"ls", l_ls},   {NULL, NULL}};
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
