/* What every part of the program shares: the worker count and the index. */
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "app.h"
#include "core/util.h"

/* the real ones are in build/buildno.c, written when the binary is linked;
 * these stand in where that is not linked (the unit tests) */
__attribute__((weak)) const char lulibre_build_number[] = "";
__attribute__((weak)) const char lulibre_build_commit[] = "";

int app_apply_cli(struct app *app, char **err) {
  if (app->cli_library && config_set(&app->cfg, "library", app->cli_library, err)) return -1;
  for (int k = 0; k < app->ncli_sets; k++) {
    const char *eq = strchr(app->cli_sets[k], '=');
    if (!eq) {
      *err = xasprintf("-o wants name=value, got '%s'", app->cli_sets[k]);
      return -1;
    }
    char *name = xstrndup(app->cli_sets[k], (size_t)(eq - app->cli_sets[k]));
    int rc = config_set(&app->cfg, name, eq + 1, err);
    free(name);
    if (rc) return -1;
  }
  return 0;
}

int app_jobs(const struct app *app) {
  int n = app->cfg.jobs;
  if (n <= 0) n = (int)uv_available_parallelism();
  if (n < 1) n = 1;
  if (n > 64) n = 64;
  return n;
}

void app_open_db(struct app *app) {
  if (app->db_ready) return;
  struct config *c = &app->cfg;
  char *err = NULL;
  if (!c->library[0]) {
    const char *env = getenv("LULIBRE_LIBRARY");
    if (env && env[0]) config_set(c, "library", env, &err);
    else if (access("metadata.db", R_OK) == 0) config_set(c, "library", ".", &err);
    else die("no library: pass -L DIR, set $LULIBRE_LIBRARY, or set lulibre.o.library in "
             "~/.config/lulibre/init.lua");
  }
  char *real = realpath(c->library, NULL);
  if (!real) die("library %s: no such directory", c->library);
  free(c->library);
  c->library = real;

  char *path = config_index_path(c);
  if (db_open(&app->db, path, &err)) die("%s", err);
  free(path);
  if (db_mirror(&app->db, c->library, 0, &err) < 0) die("%s", err);
  app->db_ready = 1;
}
