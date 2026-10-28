/* lulibre.library: calibre's library as a resource (design 24-31;
 * library/library.h), a packaged module written in C.
 *
 *   library.apply(changes [, label])   the changes as one operation; waits
 *     until it has applied or failed: the batch (nil when nothing was to
 *     change), or nil and why. changes: { {book=, field=, value=,
 *     op = "set"|"add"|"remove", proposal=, proposed=, source=}, ... };
 *     no value: the field keeps its value, a decision on a proposal
 *   library.command(args [, label])    a structural calibredb command
 *     ({ "add_custom_column", ... }), run once nothing holds the library
 *   library.undo(batch)                puts a batch's old values back
 *   library.holder()                   "none" | "server" | "program" | "other"
 *
 * Each runs on the main thread, which owns the library; the task waits for
 * the answer and the interface does not. */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <lua.h>
#include <lauxlib.h>

#include "app.h"
#include "core/queue.h"
#include "core/registry.h"
#include "core/util.h"
#include "library/library.h"
#include "lua/lapi.h"
#include "lua/sched.h"

/* An operation on its way to the main thread and its answer on the way
 * back. Everything in it is its own. */
struct msg {
  struct task *task;
  struct change *changes;
  int n;
  char **argv;
  char *label;
  long long undo; /* a batch to put back */
  /* the answer */
  long long batch;
  int failed;
  char *err;
};

static void msg_free(struct msg *m) {
  for (int i = 0; i < m->n; i++) {
    free((char *)m->changes[i].field);
    free((char *)m->changes[i].value);
    free((char *)m->changes[i].proposed);
    free((char *)m->changes[i].source);
  }
  free(m->changes);
  if (m->argv)
    for (char **a = m->argv; *a; a++) free(*a);
  free(m->argv);
  free(m->label);
  free(m->err);
  free(m);
}

/* ---- on the Lua thread: the answer wakes the task ---- */

static void answered(struct app *app, void *arg) {
  struct msg *m = arg;
  lua_State *L = sched_end_wait(m->task);
  if (L) {
    if (m->failed) {
      lua_pushnil(L);
      lua_pushstring(L, m->err ? m->err : "failed");
      sched_wake(m->task, 2);
    } else {
      if (m->batch) lua_pushinteger(L, m->batch);
      else lua_pushnil(L);
      sched_wake(m->task, 1);
    }
  }
  msg_free(m);
}

/* ---- on the main thread ---- */

static void done(long long batch, enum op_state state, const char *err, void *ud) {
  struct msg *m = ud;
  m->batch = batch;
  m->failed = state == OP_FAILED;
  m->err = err ? xstrdup(err) : NULL;
  queue_post(LOOP_LUA, answered, m);
}

static void submit(struct app *app, void *arg) {
  struct msg *m = arg;
  char *err = NULL;
  app_open_db(app);
  int rc;
  if (m->undo) {
    rc = library_undo(app->library, m->undo, done, m, &err);
  } else {
    struct operation op = {
      .label = m->label,
      .need = m->argv ? NEED_CLOSED : NEED_ANY,
      .changes = m->changes,
      .nchanges = m->n,
      .argv = (const char *const *)m->argv,
    };
    rc = library_submit(app->library, &op, done, m, &err);
  }
  if (rc) {
    m->failed = 1;
    m->err = err;
    queue_post(LOOP_LUA, answered, m);
  }
}

static int to_main(lua_State *L, struct msg *m) {
  m->task = sched_begin_wait(L);
  queue_post(LOOP_UI, submit, m);
  return lua_yield(L, 0);
}

static char *opt_string(lua_State *L, int idx, const char *key) {
  lua_getfield(L, idx, key);
  char *s = lua_isstring(L, -1) ? xstrdup(lua_tostring(L, -1)) : NULL;
  lua_pop(L, 1);
  return s;
}

static int l_apply(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  sched_require_task(L);
  int n = (int)lua_rawlen(L, 1);
  struct msg *m = xcalloc(1, sizeof *m);
  m->changes = xcalloc((size_t)(n ? n : 1), sizeof *m->changes);
  m->label = luaL_optstring(L, 2, NULL) ? xstrdup(lua_tostring(L, 2)) : NULL;
  static const char *const ops[] = {"set", "add", "remove", NULL};
  for (int i = 1; i <= n; i++) {
    lua_rawgeti(L, 1, i);
    if (!lua_istable(L, -1)) {
      msg_free(m);
      return luaL_error(L, "change %d is not a table", i);
    }
    struct change *c = &m->changes[m->n++];
    lua_getfield(L, -1, "book");
    c->book = lua_tointeger(L, -1);
    lua_getfield(L, -2, "proposal");
    c->proposal = lua_tointeger(L, -1);
    lua_getfield(L, -3, "op");
    const char *op = lua_isstring(L, -1) ? lua_tostring(L, -1) : "set";
    int k = 0;
    while (ops[k] && strcmp(ops[k], op)) k++;
    lua_pop(L, 3);
    c->field = opt_string(L, -1, "field");
    c->value = opt_string(L, -1, "value");
    c->proposed = opt_string(L, -1, "proposed");
    c->source = opt_string(L, -1, "source");
    lua_pop(L, 1);
    if (!ops[k] || !c->book || !c->field) {
      msg_free(m);
      return luaL_error(L, "change %d wants book=, field= and op = set, add or remove", i);
    }
    c->op = (enum change_op)k;
  }
  return to_main(L, m);
}

static int l_command(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  sched_require_task(L);
  int n = (int)lua_rawlen(L, 1);
  struct msg *m = xcalloc(1, sizeof *m);
  m->argv = xcalloc((size_t)n + 1, sizeof *m->argv);
  for (int i = 1; i <= n; i++) {
    lua_rawgeti(L, 1, i);
    m->argv[i - 1] = xstrdup(luaL_tolstring(L, -1, NULL));
    lua_pop(L, 2);
  }
  m->label = luaL_optstring(L, 2, NULL) ? xstrdup(lua_tostring(L, 2)) : NULL;
  return to_main(L, m);
}

static int l_undo(lua_State *L) {
  lua_Integer batch = luaL_checkinteger(L, 1);
  sched_require_task(L);
  struct msg *m = xcalloc(1, sizeof *m);
  m->undo = batch;
  return to_main(L, m);
}

static int l_holder(lua_State *L) {
  struct app *app = lapi_app(L);
  if (!app->library) lapi_db(L); /* opens the index, and the library with it */
  static const char *const names[] = {[HOLDER_NONE] = "none", [HOLDER_SERVER] = "server", [HOLDER_PROGRAM] = "program",
                                       [HOLDER_OTHER] = "other"};
  lua_pushstring(L, app->library ? names[library_holder(app->library)] : "none");
  return 1;
}

/* ---- the calibre store, when Lua has put one in calibredb's place:
 * lulibre.stores.calibre(book, fields) as a task, its answer back to the
 * main thread (library/library.h) ---- */

struct store_answer {
  struct store_req *q;
  char *err;
};

static void store_answered(struct app *app, void *arg) { /* the main thread */
  struct store_answer *a = arg;
  a->q->answer(a->q, a->err);
  free(a->err);
  free(a);
}

static void store_fail(void *req, const char *why) {
  struct store_answer *a = xcalloc(1, sizeof *a);
  a->q = req;
  a->err = xstrdup(why);
  queue_post(LOOP_UI, store_answered, a);
}

static void store_start(struct app *app, void *arg) { /* the Lua thread */
  struct store_req *q = arg;
  lua_State *L = app->L;
  if (!L) {
    store_fail(q, "no lua_State: the scripts are restarting");
    return;
  }
  lua_getglobal(L, "require");
  lua_pushliteral(L, "lulibre.stores");
  if (lua_pcall(L, 1, 1, 0) != LUA_OK) {
    store_fail(q, lua_tostring(L, -1));
    lua_pop(L, 1);
    return;
  }
  lua_getfield(L, -1, "_run");
  lua_remove(L, -2);
  lapi_push_reply(L, q, store_fail);
  lua_pushinteger(L, q->book);
  lua_createtable(L, 0, q->n);
  for (int i = 0; i < q->n; i++) {
    lua_pushstring(L, q->values[i]);
    lua_setfield(L, -2, q->fields[i]);
  }
  sched_spawn(L, 3, "store (lulibre.stores.calibre)");
}

void lapi_store_write(struct store_req *q) {
  queue_post(LOOP_LUA, store_start, q);
}

/* answer(handle [, err]) */
static int l_store_answer(lua_State *L) {
  struct store_req *q = lapi_take_reply(L, 1);
  struct store_answer *a = xcalloc(1, sizeof *a);
  a->q = q;
  a->err = lua_isstring(L, 2) ? xstrdup(lua_tostring(L, 2)) : NULL;
  queue_post(LOOP_UI, store_answered, a);
  return 0;
}

static int l_store_filled(lua_State *L) {
  registry_set_lua(REG_STORE, lua_toboolean(L, 1));
  return 0;
}

int luaopen_lulibre_stores_core(lua_State *L) {
  static const luaL_Reg fns[] = {{"answer", l_store_answer}, {"filled", l_store_filled}, {NULL, NULL}};
  luaL_newlib(L, fns);
  return 1;
}

int luaopen_lulibre_library(lua_State *L) {
  static const luaL_Reg fns[] = {
    {"apply", l_apply}, {"command", l_command}, {"undo", l_undo}, {"holder", l_holder}, {NULL, NULL},
  };
  luaL_newlib(L, fns);
  return 1;
}
