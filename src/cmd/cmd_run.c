#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <lua.h>

#include "app.h"
#include "core/util.h"
#include "lua/lapi.h"
#include "lua/sched.h"

static const char help[] =
  "usage: lulibre run SCRIPT [args]\n\n"
  "Run a Lua script without the interface. SCRIPT is a path, or the name of a\n"
  "script in ~/.config/lulibre/scripts or the bundled ones. The script gets the\n"
  "same `lulibre` API as inside the interface, minus the parts that need a\n"
  "screen; print writes to standard output. Exit status is 1 if it fails.\n";

int cmd_run(struct app *app, int argc, char **argv) {
  if (argc < 2 || !strcmp(argv[1], "-h") || !strcmp(argv[1], "--help")) {
    fputs(help, argc < 2 ? stderr : stdout);
    return argc < 2 ? 2 : 0;
  }
  char *path = lapi_find_script(app, argv[1]), *err = NULL;
  if (!path) {
    warnf("no script '%s'", argv[1]);
    return 1;
  }
  lua_State *L = app->L;
  lua_getglobal(L, "lulibre");
  lua_pushboolean(L, 1);
  lua_setfield(L, -2, "headless");
  lua_pop(L, 1);
  if (!lapi_run_file(app, path, argc - 2, argv + 2, &err)) {
    warnf("%s", err);
    free(err);
    free(path);
    return 1;
  }
  free(path);
  /* returns once no task is running and nothing they started is pending */
  uv_run(app->loop, UV_RUN_DEFAULT);
  return sched_failed(app) ? 1 : 0;
}
