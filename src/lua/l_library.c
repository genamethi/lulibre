/* store: calibre's library as a resource (design 24-31; library/library.h),
 * a module written in C, preloaded.
 *
 *   store.apply(changes [, label])   the changes as one operation; waits
 *     until it has applied or failed: the batch (nil when nothing was to
 *     change), or nil and why. changes: { {book=, field=, value=,
 *     op = "set"|"add"|"remove", proposal=, proposed=, source=}, ... };
 *     no value: the field keeps its value, a decision on a proposal; a third
 *     argument, a batch to join
 *   store.command(args [, label | {label=, when=, batch=}])   a calibredb command
 *     ({ "add_custom_column", ... }); when "closed", the default, it runs once
 *     nothing holds the library, and when "any" as a change would, through the
 *     content server if it is set; batch, a batch to join. Waits: the batch and
 *     what it printed, or nil and why
 *   store.add(books [, label [, batch]])   adds books as one batch, a process
 *     per book, as many at once as changes run. books: { {path=, title=, authors=,
 *     tags=, series=, series_index=, identifiers = {type = value}, cover=, duplicates=,
 *     restores=, record=}, ... }; no path: a book with no file. Waits: a list of the
 *     new ids, false for one that failed; then why, if any did; then the batch
 *   store.remove(ids [, label [, batch]])  removes books as one batch and one
 *     process, to calibre's recycle bin. Waits: the batch, or nil and why
 *   store.set_aside(path, to [, batch [, label]])  moves a file, which undo puts back
 *   store.drop(book, held [, batch])   a staged file to the path held, its
 *     record kept for undo: the batch, or nil and why
 *   store.cancel(batch)                a queued batch out of the queue
 *   store.undo(batch)                  puts a batch's old values back
 *   store.holder()                     "none" | "server" | "program" | "other"
 *   store.reload()                     calibre's records read again (l_db.c)
 *
 * Each runs on the background thread, which owns the library (work.h);
 * the task waits for the answer and the interface does not. */
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
  int when_any;       /* a command that runs as a change does */
  long long join;     /* a batch to join */
  long long undo; /* a batch to put back */
  long long drop;     /* a staged file to take out of the folder */
  char *held;         /* to here */
  int cancel;         /* join is to come out of the queue */
  struct add_item *adds; /* books to add */
  int nadds;
  long long *added;   /* their ids */
  long long *removes; /* books to remove */
  int nremoves;
  char *aside;        /* a file to move to held */
  char *output;       /* what a command printed */
  struct op_settings set; /* from the lua_State's copy, as the call was made */
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
  free(m->held);
  for (int i = 0; i < m->nadds; i++) {
    for (char **a = m->adds[i].args; a && *a; a++) free(*a);
    free(m->adds[i].args);
    free((char *)m->adds[i].from);
    free((char *)m->adds[i].record);
  }
  free(m->adds);
  free(m->added);
  free(m->removes);
  free(m->aside);
  free(m->output);
  free(m->err);
  free((char *)m->set.server);
  free((char *)m->set.user);
  free((char *)m->set.password_file);
  free(m);
}

/* ---- on the Lua thread: the answer wakes the task ---- */

static void answered(struct app *app, void *arg) {
  struct msg *m = arg;
  lua_State *L = sched_end_wait(m->task);
  if (L && m->adds) {
    /* the ids, whether or not all of them went */
    lua_createtable(L, m->nadds, 0);
    for (int i = 0; i < m->nadds; i++) {
      if (m->added[i]) lua_pushinteger(L, m->added[i]);
      else lua_pushboolean(L, 0);
      lua_rawseti(L, -2, i + 1);
    }
    if (m->failed) lua_pushstring(L, m->err ? m->err : "failed");
    else lua_pushnil(L);
    lua_pushinteger(L, m->batch);
    sched_wake(m->task, 3);
  } else if (L) {
    if (m->failed) {
      lua_pushnil(L);
      lua_pushstring(L, m->err ? m->err : "failed");
      sched_wake(m->task, 2);
    } else {
      if (m->batch) lua_pushinteger(L, m->batch);
      else lua_pushnil(L);
      if (m->output) {
        lua_pushstring(L, m->output);
        sched_wake(m->task, 2);
      } else {
        sched_wake(m->task, 1);
      }
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

static void submit(struct app *app, void *arg) { /* the background thread */
  struct msg *m = arg;
  char *err = NULL;
  int rc;
  if (!app->library) {
    rc = -1;
    err = xstrdup("the library is closed");
  } else if (m->undo) {
    rc = library_undo(app->library, m->undo, &m->set, done, m, &err);
  } else if (m->cancel) {
    rc = library_cancel(app->library, m->join, &err);
    if (!rc) done(m->join, OP_APPLIED, NULL, m);
  } else if (m->adds) {
    rc = library_add(app->library, m->adds, m->nadds, m->label, m->join, &m->set, m->added, done, m);
  } else if (m->removes) {
    rc = library_remove(app->library, m->removes, m->nremoves, m->label, m->join, &m->set, done, m, &err);
  } else if (m->aside) {
    long long batch = library_set_aside(app->library, m->aside, m->held, m->join, m->label, &err);
    rc = batch ? 0 : -1;
    if (!rc) done(batch, OP_APPLIED, NULL, m);
  } else if (m->drop) {
    long long batch = library_drop(app->library, m->drop, m->held, m->join, &err);
    rc = batch ? 0 : -1;
    if (!rc) done(batch, OP_APPLIED, NULL, m);
  } else {
    struct operation op = {
      .set = &m->set,
      .label = m->label,
      .need = m->argv && !m->when_any ? NEED_CLOSED : NEED_ANY,
      .changes = m->changes,
      .nchanges = m->n,
      .argv = (const char *const *)m->argv,
      .batch = m->join,
      .output = m->argv ? &m->output : NULL,
    };
    rc = library_submit(app->library, &op, done, m, &err);
  }
  if (rc) {
    m->failed = 1;
    m->err = err;
    queue_post(LOOP_LUA, answered, m);
  }
}

static int to_library(lua_State *L, struct msg *m) {
  lapi_db(L); /* the index open, and the library with it */
  m->set = (struct op_settings){lapi_setting_str(L, S_SERVER), lapi_setting_str(L, S_USER),
                                lapi_setting_str(L, S_PASSWORD_FILE), (int)lapi_setting_int(L, S_EMBED),
                                (int)lapi_setting_int(L, S_WRITE_JOBS)};
  m->task = sched_begin_wait(L);
  queue_post(LOOP_WORK, submit, m);
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
  m->join = luaL_optinteger(L, 3, 0);
  return to_library(L, m);
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
  if (lua_istable(L, 2)) {
    m->label = opt_string(L, 2, "label");
    lua_getfield(L, 2, "when");
    m->when_any = lua_isstring(L, -1) && !strcmp(lua_tostring(L, -1), "any");
    lua_getfield(L, 2, "batch");
    m->join = lua_tointeger(L, -1);
    lua_pop(L, 2);
  } else {
    m->label = luaL_optstring(L, 2, NULL) ? xstrdup(lua_tostring(L, 2)) : NULL;
  }
  return to_library(L, m);
}

/* a field of a book to add, as an option of calibredb add */
static void add_option(lua_State *L, int idx, const char *field, const char *flag, char ***args, int *n) {
  lua_getfield(L, idx, field);
  if (lua_isstring(L, -1) && *lua_tostring(L, -1)) {
    *args = xrealloc(*args, (size_t)(*n + 3) * sizeof **args);
    (*args)[(*n)++] = xstrdup(flag);
    (*args)[(*n)++] = xstrdup(lua_tostring(L, -1));
    (*args)[*n] = NULL;
  }
  lua_pop(L, 1);
}

static int l_add(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  sched_require_task(L);
  int n = (int)lua_rawlen(L, 1);
  struct msg *m = xcalloc(1, sizeof *m);
  m->adds = xcalloc((size_t)(n ? n : 1), sizeof *m->adds);
  m->added = xcalloc((size_t)(n ? n : 1), sizeof *m->added);
  m->nadds = n;
  m->label = luaL_optstring(L, 2, NULL) ? xstrdup(lua_tostring(L, 2)) : NULL;
  m->join = luaL_optinteger(L, 3, 0);
  for (int i = 1; i <= n; i++) {
    lua_rawgeti(L, 1, i);
    int item = lua_gettop(L);
    if (!lua_istable(L, item)) {
      msg_free(m);
      return luaL_error(L, "book %d is not a table", i);
    }
    struct add_item *a = &m->adds[i - 1];
    int na = 0;
    a->args = xcalloc(2, sizeof *a->args);
    lua_getfield(L, item, "duplicates");
    int duplicates = lua_isnil(L, -1) || lua_toboolean(L, -1); /* lulibre compares the bytes itself */
    lua_pop(L, 1);
    if (duplicates) a->args[na++] = xstrdup("--duplicates");
    add_option(L, item, "title", "--title", &a->args, &na);
    add_option(L, item, "authors", "--authors", &a->args, &na);
    add_option(L, item, "tags", "--tags", &a->args, &na);
    add_option(L, item, "series", "--series", &a->args, &na);
    add_option(L, item, "series_index", "--series-index", &a->args, &na);
    add_option(L, item, "cover", "--cover", &a->args, &na);
    add_option(L, item, "languages", "--languages", &a->args, &na);
    lua_getfield(L, item, "identifiers");
    if (lua_istable(L, -1)) {
      lua_pushnil(L);
      while (lua_next(L, -2)) {
        a->args = xrealloc(a->args, (size_t)(na + 3) * sizeof *a->args);
        a->args[na++] = xstrdup("--identifier");
        lua_pushvalue(L, -2);
        a->args[na++] = xasprintf("%s:%s", lua_tostring(L, -1), lua_tostring(L, -2));
        lua_pop(L, 2);
      }
    }
    lua_pop(L, 1);
    lua_getfield(L, item, "path");
    a->args = xrealloc(a->args, (size_t)(na + 3) * sizeof *a->args);
    if (lua_isstring(L, -1)) {
      a->from = xstrdup(lua_tostring(L, -1));
      a->args[na++] = xstrdup(lua_tostring(L, -1));
    } else {
      a->args[na++] = xstrdup("--empty");
    }
    a->args[na] = NULL;
    lua_pop(L, 1);
    lua_getfield(L, item, "record");
    a->record = lua_isstring(L, -1) ? xstrdup(lua_tostring(L, -1)) : NULL;
    lua_getfield(L, item, "restores");
    a->restores = lua_tointeger(L, -1);
    lua_pop(L, 3);
  }
  return to_library(L, m);
}

static int l_remove(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  sched_require_task(L);
  int n = (int)lua_rawlen(L, 1);
  struct msg *m = xcalloc(1, sizeof *m);
  m->removes = xcalloc((size_t)(n ? n : 1), sizeof *m->removes);
  m->nremoves = n;
  for (int i = 1; i <= n; i++) {
    lua_rawgeti(L, 1, i);
    m->removes[i - 1] = lua_tointeger(L, -1);
    lua_pop(L, 1);
  }
  m->label = luaL_optstring(L, 2, NULL) ? xstrdup(lua_tostring(L, 2)) : NULL;
  m->join = luaL_optinteger(L, 3, 0);
  return to_library(L, m);
}

static int l_set_aside(lua_State *L) {
  const char *path = luaL_checkstring(L, 1), *to = luaL_checkstring(L, 2);
  lua_Integer batch = luaL_optinteger(L, 3, 0);
  const char *label = luaL_optstring(L, 4, NULL);
  sched_require_task(L);
  struct msg *m = xcalloc(1, sizeof *m);
  m->aside = xstrdup(path);
  m->held = xstrdup(to);
  m->join = batch;
  m->label = label ? xstrdup(label) : NULL;
  return to_library(L, m);
}

static int l_cancel(lua_State *L) {
  lua_Integer batch = luaL_checkinteger(L, 1);
  sched_require_task(L);
  struct msg *m = xcalloc(1, sizeof *m);
  m->join = batch;
  m->cancel = 1;
  return to_library(L, m);
}

static int l_drop(lua_State *L) {
  lua_Integer book = luaL_checkinteger(L, 1);
  const char *held = luaL_checkstring(L, 2);
  lua_Integer batch = luaL_optinteger(L, 3, 0);
  sched_require_task(L);
  struct msg *m = xcalloc(1, sizeof *m);
  m->drop = book;
  m->held = xstrdup(held);
  m->join = batch;
  return to_library(L, m);
}

static int l_undo(lua_State *L) {
  lua_Integer batch = luaL_checkinteger(L, 1);
  sched_require_task(L);
  struct msg *m = xcalloc(1, sizeof *m);
  m->undo = batch;
  return to_library(L, m);
}

static int l_holder(lua_State *L) {
  struct app *app = lapi_app(L);
  if (!app->library) lapi_db(L); /* opens the index, and the library with it */
  static const char *const names[] = {[HOLDER_NONE] = "none", [HOLDER_SERVER] = "server", [HOLDER_PROGRAM] = "program",
                                       [HOLDER_OTHER] = "other"};
  lua_pushstring(L, app->library ? names[library_holder(app->library)] : "none");
  return 1;
}

/* ---- store.calibre: a function of Lua's in calibredb's place
 * (lua/handler.c), called as a task for each book of a write:
 *
 *   store.calibre = function(book, fields) ... return true end
 *
 * fields { title = "...", authors = "A & B", tags = "a, b", ... }; it
 * returns true, or nil and why it failed; its answer goes back to the
 * main thread (library/library.h) ---- */

struct store_answer {
  struct store_req *q;
  char *err;
};

static void store_answered(struct app *app, void *arg) { /* the background thread */
  struct store_answer *a = arg;
  a->q->answer(a->q, a->err);
  free(a->err);
  free(a);
}

static void store_reply(void *req, const char *why) {
  struct store_answer *a = xcalloc(1, sizeof *a);
  a->q = req;
  a->err = why ? xstrdup(why) : NULL;
  queue_post(LOOP_WORK, store_answered, a);
}

/* one call: (book, fields) */
static void store_calls(lua_State *L, void *req) {
  struct store_req *q = req;
  lua_createtable(L, 1, 0);
  lua_createtable(L, 2, 0);
  lua_pushinteger(L, q->book);
  lua_rawseti(L, -2, 1);
  lua_createtable(L, 0, q->n);
  for (int i = 0; i < q->n; i++) {
    lua_pushstring(L, q->values[i]);
    lua_setfield(L, -2, q->fields[i]);
  }
  lua_rawseti(L, -2, 2);
  lua_rawseti(L, -2, 1);
}

static void store_answer(lua_State *L, void *req, int results, const char *why) {
  const char *err = why;
  lua_rawgeti(L, results, 1);
  if (!why) {
    lua_rawgeti(L, -1, 1);
    lua_rawgeti(L, -2, 2);
    if (!lua_toboolean(L, -2)) err = lua_isstring(L, -1) ? lua_tostring(L, -1) : "the store said no";
  }
  store_reply(req, err); /* NULL: written */
  lua_settop(L, results);
}

static const struct lapi_part store_part = {REG_STORE, "store (store.calibre)", store_calls, store_answer, store_reply};

void lapi_store_write(struct store_req *q) {
  lapi_handle(&store_part, q);
}

int luaopen_store(lua_State *L) {
  static const luaL_Reg fns[] = {
    {"apply", l_apply}, {"command", l_command}, {"add", l_add}, {"remove", l_remove}, {"drop", l_drop}, {"set_aside", l_set_aside}, {"cancel", l_cancel}, {"undo", l_undo}, {"holder", l_holder}, {"reload", l_db_reload},
    {NULL, NULL},
  };
  luaL_newlib(L, fns);
  static const struct lapi_handler handlers[] = {{"calibre", &store_part}, {NULL, NULL}};
  lapi_handlers(L, -1, handlers);
  return 1;
}
