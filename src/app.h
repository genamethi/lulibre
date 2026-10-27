#ifndef LULIBRE_APP_H
#define LULIBRE_APP_H

#include <stdatomic.h>

#include <uv.h>

#include "core/setdefs.h"
#include "db/db.h"

struct lua_State;
struct sched;
struct lctx;
struct tui;
struct library;

struct app {
  struct settings *settings; /* the store; read and changed on the main thread only */
  char *config_dir;          /* where init.lua is: fixed at start */
  char *state_path;          /* the saved settings: fixed at start */
  struct db db;
  int db_ready;
  struct library *library; /* calibre's library as a resource (library/library.h); with the index */
  uv_loop_t *loop;      /* the interface's loop; the only loop when headless */
  uv_loop_t *lloop;     /* the loop Lua's timers, processes and luv use (lua/bridge.h) */
  struct db *ldb;       /* the Lua thread's own connection, while it has one */
  struct lua_State *L;  /* the main Lua state; lives on the Lua thread */
  struct lctx *lmain;   /* its per-thread context (lua/lapi.h) */
  struct sched *sched;  /* Lua tasks (lua/sched.h) */
  struct tui *tui;      /* NULL when running headless */
  atomic_int source;    /* what the list shows (tui.h rows.source); Lua filters default to it */
};

/* This build's number among the builds of its version ("007"), and the
 * commit it was made from ("3b3ddb3", with + when the tree had changes);
 * both "" in a binary that was not linked by the Makefile's rule. */
extern const char lulibre_build_number[], lulibre_build_commit[];

/* The settings: the store with its defaults and the saved state, then the
 * command line's (-C, -L, -o name=value) laid over it. Dies with a message
 * on a bad value. */
void app_settings(struct app *app, const char *confdir, const char *library, const char **sets, int nsets);
/* A value in effect, on the main thread. */
const char *app_str(const struct app *app, enum setting_id id);
long long app_int(const struct app *app, enum setting_id id);
int app_bool(const struct app *app, enum setting_id id);
/* A change from the main thread (:set): the Lua API's layer. */
int app_set(struct app *app, const char *name, const char *text, char **err);
/* An indexer run's options from the settings in effect (index/indexer.h),
 * on the main thread; the indexer copies what it keeps. */
struct index_opts;
void app_index_opts(const struct app *app, struct index_opts *o);
/* The index file in effect, for the library in effect; malloc'd. */
char *app_index_path(const struct app *app);

/* Resolve the library, open the index and refresh the calibre mirror.
 * Dies with a message on failure: every command needs this to proceed. */
void app_open_db(struct app *app);
int app_jobs(const struct app *app); /* worker thread count in effect */

/* subcommands: argv[0] is the command name */
int cmd_index(struct app *app, int argc, char **argv);
int cmd_query(struct app *app, int argc, char **argv);
int cmd_show(struct app *app, int argc, char **argv);
int cmd_stats(struct app *app, int argc, char **argv);

int cmd_run(struct app *app, int argc, char **argv);

/* tui/tui.c */
int tui_run(struct app *app);
void tui_setup(void);
void tui_teardown(void);
void tui_reload(struct tui *t); /* refresh the list: calibre's database was read again */

/* lua/lstate.c */
struct lua_State *lstate_new(struct app *app);
int lstate_run_init(struct app *app); /* loads ~/.config/lulibre/init.lua if present */
void lstate_close(struct app *app);
/* When the binary runs from a source tree that has since become another
 * version: a sentence saying so (the caller frees it), else NULL. */
char *lstate_tree_mismatch(void);
const char *lstate_runtime_modules(void);
const char *lstate_datadir(void);

#endif
