#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <lua.h>

#include "app.h"
#include "core/util.h"
#include "library/library.h"
#include "lua/lapi.h"
#include "lua/sched.h"

static const char help[] =
  "usage: lulibre run FILE [args]\n\n"
  "Run a Lua file without the interface. It gets the same API as inside the\n"
  "interface, minus the parts that need a screen; print writes to standard\n"
  "output. Exit status is 1 if it fails.\n";

int cmd_run(struct app *app, int argc, char **argv) {
  if (argc < 2 || !strcmp(argv[1], "-h") || !strcmp(argv[1], "--help")) {
    fputs(help, argc < 2 ? stderr : stdout);
    return argc < 2 ? 2 : 0;
  }
  const char *path = argv[1];
  char *err = NULL;
  if (access(path, R_OK)) {
    warnf("no file '%s'", path);
    return 1;
  }
  lua_State *L = app->L;
  lua_getglobal(L, "lulib");
  lua_pushboolean(L, 1);
  lua_setfield(L, -2, "headless");
  lua_pop(L, 1);
  if (!lapi_run_file(app, path, argc - 2, argv + 2, &err)) {
    warnf("%s", err);
    free(err);
    return 1;
  }
  /* returns once no task is running and nothing they started is pending */
  if (app->db_ready) library_resume(app->library);
  uv_run(app->loop, UV_RUN_DEFAULT);
  return sched_failed(app) ? 1 : 0;
}
