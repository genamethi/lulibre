#ifndef LULIBRE_APP_H
#define LULIBRE_APP_H

#include <stdatomic.h>

#include <uv.h>

#include "core/config.h"
#include "db/db.h"

struct lua_State;
struct sched;
struct lctx;
struct tui;

struct app {
  struct config cfg;
  struct db db;
  int db_ready;
  uv_loop_t *loop;      /* the interface's loop; the only loop when headless */
  uv_loop_t *lloop;     /* the loop Lua's timers, processes and luv use (lua/bridge.h) */
  struct db *ldb;       /* the Lua thread's own connection, while it has one */
  struct lua_State *L;  /* the main Lua state; lives on the Lua thread */
  struct lctx *lmain;   /* its per-thread context (lua/lapi.h) */
  struct sched *sched;  /* Lua tasks (lua/sched.h) */
  struct tui *tui;      /* NULL when running headless */
  atomic_int source;    /* what the list shows (tui.h rows.source); Lua filters default to it */
  /* what the command line set (-L, -o name=value): applied on top of
   * init.lua, at start and again whenever init.lua is read again */
  const char *cli_library;
  const char *cli_sets[32];
  int ncli_sets;
};

/* Apply the command line's options. Returns 0, or -1 with *err set. */
int app_apply_cli(struct app *app, char **err);

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
int cmd_config(struct app *app, int argc, char **argv);

/* tui/tui.c */
int tui_run(struct app *app);
void tui_setup(void);
void tui_teardown(void);
void tui_reload(struct tui *t); /* re-read calibre now and refresh the list */

/* lua/lstate.c */
struct lua_State *lstate_new(struct app *app);
int lstate_run_init(struct app *app); /* loads ~/.config/lulibre/init.lua if present */
void lstate_close(struct app *app);

#endif
