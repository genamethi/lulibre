#include <signal.h>
#include <curl/curl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "app.h"
#include "lua/lapi.h"
#include "config.h"
#include "version.h"
#include "core/log.h"
#include "core/queue.h"
#include "library/library.h"
#include "core/util.h"
#include "lua/bridge.h"
#include "work.h"

static const struct {
  const char *name;
  int (*fn)(struct app *, int, char **);
  const char *summary;
} commands[] = {
  {"index", cmd_index, "extract the leading pages of every file into the search index"},
  {"query", cmd_query, "list books matching a filter"},
  {"show", cmd_show, "show one book: metadata, files, indexed text"},
  {"stats", cmd_stats, "what is missing across the library"},
  {"run", cmd_run, "run a Lua script without the interface"},
  {"offline", cmd_offline, "read calibre's records and make the changes that wait (before calibre's server starts)"},
};

static void usage(FILE *f) {
  fprintf(f, "usage: lulibre [-L library] [-C confdir] [-o name=value]... [--clean] [command [args]]\n\n"
             "With no command, lulibre opens the interactive interface (? for help).\n\n");
  for (size_t i = 0; i < ARRAY_LEN(commands); i++)
    fprintf(f, "  %-8s %s\n", commands[i].name, commands[i].summary);
  fprintf(f, "\n  -L DIR          calibre library (else path.library, $LULIBRE_LIBRARY, ., or calibre's last, asked)\n"
             "  -o name=value   a setting; `lulibre -o help` lists them\n"
             "  -C DIR          configuration directory: init.lua, lua/\n"
             "                  (else $LULIBRE_CONFIG_DIR, else ~/.config/lulibre)\n"
             "  --clean         do not load init.lua\n"
             "  -V              version\n\n"
             "Run `lulibre <command> -h` for a command's own options.\n");
}

static void list_settings(const struct app *app) {
  for (int i = 0; i < S_COUNT; i++) {
    const struct setting_def *d = &setting_defs[i];
    char *val = settings_format(d, settings_value(app->settings, i));
    printf("%-15s %-34s %s%s%s%s\n", d->name, val, d->help, d->choices ? "  (" : "", d->choices ? d->choices : "",
           d->choices ? ")" : "");
    free(val);
  }
}

static int finish(struct app *app, int rc) {
  char *err = NULL;
  queue_drain(LOOP_UI); /* changes the loop ended before running */
  if (settings_save_state(app->settings, app->state_path, &err)) {
    warnf("%s", err);
    free(err);
  }
  queue_drain(LOOP_LUA); /* what was on its way to the copy, before the lua_State goes */
  lstate_close(app);
  ui_state_close();
  work_stop(app); /* the library closes */
  if (app->db_ready) db_close(&app->db);
  tui_teardown();
  settings_free(app->settings);
  curl_global_cleanup();
  free(app->config_dir);
  free(app->state_path);
  return rc;
}

int main(int argc, char **argv) {
  struct app app;
  memset(&app, 0, sizeof app);
  crash_install();
  curl_global_init(CURL_GLOBAL_DEFAULT); /* before any thread: curl.h */
  db_functions_everywhere();             /* before any connection, scripts' too */
  signal(SIGPIPE, SIG_IGN); /* a helper process that exits early is an error to report, not a death */

  /* global options come before the command */
  int i = 1, clean = 0, want_optlist = 0;
  const char *sets[64];
  int nsets = 0;
  const char *library = NULL, *confdir = getenv("LULIBRE_CONFIG_DIR");
  for (; i < argc; i++) {
    const char *a = argv[i];
    if (!strcmp(a, "-L") && i + 1 < argc) library = argv[++i];
    else if ((!strcmp(a, "-C") || !strcmp(a, "--config-dir")) && i + 1 < argc) confdir = argv[++i];
    else if (!strcmp(a, "-o") && i + 1 < argc) {
      if (!strcmp(argv[i + 1], "help")) want_optlist = 1;
      else if (nsets < (int)ARRAY_LEN(sets)) sets[nsets++] = argv[i + 1];
      i++;
    }
    else if (!strcmp(a, "--clean")) clean = 1;
    else if (!strcmp(a, "-h") || !strcmp(a, "--help")) {
      usage(stdout);
      return 0;
    }
    else if (!strcmp(a, "-V") || !strcmp(a, "--version")) {
      /* the second word is the version, alone: scripts read it */
      printf("lulibre %s (%s build%s%s, Lua %s)\n", LULIBRE_VERSION, LULIBRE_BUILD, lulibre_build_number[0] ? " " : "",
             lulibre_build_number, LULIBRE_LUA_VER);
      return 0;
    }
    else break;
  }

  /* the command line's values lie over what init.lua sets (design 44) */
  app_settings(&app, confdir, library, sets, nsets);
  app.loop = uv_default_loop();
  /* with the interface, Lua gets a loop and (once it is up) a thread of its own */
  int interface = i >= argc && !want_optlist;
  bridge_init(&app, interface);
  work_init(&app, interface);
  queue_open(&app, LOOP_UI, app.loop);
  queue_open(&app, LOOP_LUA, app.lloop);
  queue_open(&app, LOOP_WORK, app.wloop);
  tui_setup(); /* built-in commands and keys exist before init.lua adds to them */
  lstate_new(&app);
  /* known before init.lua, so that what it and the prelude do at start can
   * tell: the systemd units are made as the options say in the interface
   * only, never by a command (lulibre offline, run from one of them) */
  if (!interface) {
    lua_getglobal(app.L, "lulib");
    lua_pushboolean(app.L, 1);
    lua_setfield(app.L, -2, "headless");
    lua_pop(app.L, 1);
  }
  char *mismatch = lstate_tree_mismatch();
  if (mismatch) warnf("%s", mismatch);
  free(mismatch);
  if (!clean) lstate_run_init(&app);
  /* the changes init.lua made reach the store before C reads it */
  queue_drain(LOOP_UI);
  /* a value given for a setting nothing has made by now is said, and dropped */
  char *unmade = settings_unmade(app.settings);
  for (char *p = unmade; p && *p;) {
    size_t n = strcspn(p, "\n");
    warnf("%.*s", (int)n, p);
    p += n + (p[n] == '\n');
  }
  free(unmade);
  {
    const char *env = getenv("LULIBRE_LOG");
    const char *file = env && env[0] ? env : app_str(&app, S_LOG_FILE);
    if (file[0] && log_to_file(file)) warnf("cannot write the log file %s", file);
    log_debug("lulibre %s (%s build %s from %s, Lua %s) starting", LULIBRE_VERSION, LULIBRE_BUILD, lulibre_build_number,
              lulibre_build_commit, LULIBRE_LUA_VER);
  }
  if (want_optlist) {
    list_settings(&app);
    return finish(&app, 0);
  }

  /* libuv sizes its pool on first use, from the environment */
  if (!getenv("UV_THREADPOOL_SIZE")) {
    char n[16];
    snprintf(n, sizeof n, "%d", app_jobs(&app));
    setenv("UV_THREADPOOL_SIZE", n, 1);
  }
  if (i >= argc) { /* no command: the interactive interface */
    return finish(&app, tui_run(&app));
  }

  for (size_t k = 0; k < ARRAY_LEN(commands); k++)
    if (!strcmp(argv[i], commands[k].name))
      return finish(&app, commands[k].fn(&app, argc - i, argv + i));
  warnf("unknown command '%s'", argv[i]);
  usage(stderr);
  return finish(&app, 2);
}
