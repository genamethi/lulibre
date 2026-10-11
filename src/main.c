#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "app.h"
#include "config.h"
#include "version.h"
#include "core/log.h"
#include "core/util.h"
#include "lua/bridge.h"

/* Commands that are bundled scripts: `lulibre bib ...` is `lulibre run bib ...`. */
static int cmd_script(struct app *app, int argc, char **argv);

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
  {"config", cmd_config, "print the configuration as a Lua file; --write saves a first one"},
  {"sync", cmd_script, "the sync folder: list it, or `sync add` / `sync move` into the library"},
  {"dupes", cmd_script, "books whose files are identical"},
  {"orphans", cmd_script, "records with no file, files with no record, broken links"},
  {"bib", cmd_script, "write BibTeX for the books matching a filter"},
  {"ocr", cmd_script, "read text from page images with tesseract"},
};

static void usage(FILE *f) {
  fprintf(f, "usage: lulibre [-L library] [-C confdir] [-o name=value]... [--clean] [command [args]]\n\n"
             "With no command, lulibre opens the interactive interface (? for help).\n\n");
  for (size_t i = 0; i < ARRAY_LEN(commands); i++)
    fprintf(f, "  %-7s %s\n", commands[i].name, commands[i].summary);
  fprintf(f, "\n  -L DIR          calibre library (else $LULIBRE_LIBRARY, init.lua, or .)\n"
             "  -o name=value   set an option; `lulibre -o help` lists them\n"
             "  -C DIR          configuration directory: init.lua, scripts/, lua/\n"
             "                  (else $LULIBRE_CONFIG_DIR, else ~/.config/lulibre)\n"
             "  --clean         do not load init.lua\n"
             "  -V              version\n\n"
             "Run `lulibre <command> -h` for a command's own options.\n");
}

static void list_options(const struct config *c) {
  size_t n;
  const struct opt_def *o = config_opts(&n);
  for (size_t i = 0; i < n; i++) {
    char num[32];
    const char *val = num;
    if (o[i].type == OPT_INT) snprintf(num, sizeof num, "%d", config_int(c, &o[i]));
    else val = config_str(c, &o[i]);
    printf("%-15s %-34s %s%s%s%s\n", o[i].name, val, o[i].help, o[i].choices ? "  (" : "",
           o[i].choices ? o[i].choices : "", o[i].choices ? ")" : "");
  }
}

static int cmd_script(struct app *app, int argc, char **argv) {
  char **args = xcalloc((size_t)argc + 2, sizeof *args);
  args[0] = "run";
  for (int i = 0; i < argc; i++) args[i + 1] = argv[i];
  int rc = cmd_run(app, argc + 1, args);
  free(args);
  return rc;
}

static int finish(struct app *app, int rc) {
  lstate_close(app);
  if (app->db_ready) db_close(&app->db);
  tui_teardown();
  config_free(&app->cfg);
  return rc;
}

int main(int argc, char **argv) {
  struct app app;
  memset(&app, 0, sizeof app);
  signal(SIGPIPE, SIG_IGN); /* a helper process that exits early is an error to report, not a death */
  config_init(&app.cfg);

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
      config_free(&app.cfg);
      return 0;
    }
    else if (!strcmp(a, "-V") || !strcmp(a, "--version")) {
      /* the second word is the version, alone: scripts read it */
      printf("lulibre %s (%s build, Lua %s)\n", LULIBRE_VERSION, LULIBRE_BUILD, LULIBRE_LUA_VER);
      config_free(&app.cfg);
      return 0;
    }
    else break;
  }

  /* init.lua first, then the command line on top of it */
  char *err = NULL;
  if (confdir && confdir[0] && config_set(&app.cfg, "config_dir", confdir, &err)) die("%s", err);
  app.loop = uv_default_loop();
  /* with the interface, Lua gets a loop and (once it is up) a thread of its own */
  bridge_init(&app, i >= argc && !want_optlist);
  tui_setup(); /* built-in commands and keys exist before init.lua adds to them */
  lstate_new(&app);
  if (!clean) lstate_run_init(&app);
  if (library && config_set(&app.cfg, "library", library, &err)) die("%s", err);
  for (int k = 0; k < nsets; k++) {
    const char *eq = strchr(sets[k], '=');
    if (!eq) die("-o wants name=value, got '%s'", sets[k]);
    char *name = xstrndup(sets[k], (size_t)(eq - sets[k]));
    if (config_set(&app.cfg, name, eq + 1, &err)) die("%s", err);
    free(name);
  }
  {
    const char *env = getenv("LULIBRE_LOG");
    const char *file = env && env[0] ? env : app.cfg.log_file;
    if (file[0] && log_to_file(file)) warnf("cannot write the log file %s", file);
    log_debug("lulibre %s (%s build, Lua %s) starting", LULIBRE_VERSION, LULIBRE_BUILD, LULIBRE_LUA_VER);
  }
  if (want_optlist) {
    list_options(&app.cfg);
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
