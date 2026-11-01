/* What every part of the program shares: the worker count and the index. */
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "app.h"
#include "core/queue.h"
#include "index/indexer.h"
#include "library/library.h"
#include "core/util.h"
#include "lua/lapi.h"
#include "work.h"

/* the real ones are in build/buildno.c, written when the binary is linked;
 * these stand in where that is not linked (the unit tests) */
__attribute__((weak)) const char lulibre_build_number[] = "";
__attribute__((weak)) const char lulibre_build_commit[] = "";

/* A change in effect: the lua_State's copy follows (l_setman.c). */
static void watch(struct settings *st, int def, void *ud) {
  struct app *app = ud;
  if (app->L) queue_post(LOOP_LUA, l_setman_changed, setman_change_new(st, def));
  work_setting_changed(app, def);
  if (def == S_CRASH) crash_at(app_str(app, S_CRASH));
}

void app_settings(struct app *app, const char *confdir, const char *library, const char **sets, int nsets) {
  char *err = NULL;
  app->settings = settings_new(setting_defs, S_COUNT);
  /* the command line first: it says where the saved state is */
  if (confdir && confdir[0] && settings_set(app->settings, "path.config", confdir, FROM_CLI, &err)) die("%s", err);
  if (library && settings_set(app->settings, "path.library", library, FROM_CLI, &err)) die("%s", err);
  for (int k = 0; k < nsets; k++) {
    const char *eq = strchr(sets[k], '=');
    if (!eq) die("-o wants name=value, got '%s'", sets[k]);
    char *name = xstrndup(sets[k], (size_t)(eq - sets[k]));
    int rc = settings_set(app->settings, name, eq + 1, FROM_CLI, &err);
    free(name);
    if (rc) die("%s", err);
  }
  const char *dir = app_str(app, S_CONFIG_DIR);
  app->config_dir = dir[0] ? xstrdup(dir) : path_xdg("XDG_CONFIG_HOME", "~/.config/lulibre");
  const char *saved = app_str(app, S_STATE);
  if (saved[0]) {
    app->state_path = xstrdup(saved);
  } else {
    char *state = path_xdg("XDG_STATE_HOME", "~/.local/state/lulibre");
    app->state_path = xasprintf("%s/settings", state);
    free(state);
  }
  if (settings_load_state(app->settings, app->state_path, &err)) {
    warnf("%s", err);
    free(err);
    err = NULL;
  }
  crash_at(app_str(app, S_CRASH));
  settings_watch(app->settings, watch, app);
}

const char *app_str(const struct app *app, enum setting_id id) {
  return settings_value(app->settings, id)->s;
}

long long app_int(const struct app *app, enum setting_id id) {
  return settings_value(app->settings, id)->i;
}

int app_bool(const struct app *app, enum setting_id id) {
  return settings_value(app->settings, id)->b;
}

int app_set(struct app *app, const char *name, const char *text, char **err) {
  return settings_change(app->settings, name, text, err);
}

int app_jobs(const struct app *app) {
  int n = (int)app_int(app, S_JOBS);
  if (n <= 0) n = (int)uv_available_parallelism();
  if (n < 1) n = 1;
  if (n > 64) n = 64;
  return n;
}

void app_index_opts(const struct app *app, struct index_opts *o) {
  o->pages = (int)app_int(app, S_PAGES);
  const char *ocr = app_str(app, S_OCR);
  o->ocr = !strcmp(ocr, "auto") ? OCR_AUTO : !strcmp(ocr, "always") ? OCR_ALWAYS : OCR_NEVER;
  o->ocr_pages = (int)app_int(app, S_OCR_PAGES);
  o->ocr_lang = app_str(app, S_OCR_LANG);
  /* never the whole pool: what the interface asks of it (the list, the
   * preview, the records read again) doesn't wait behind a file being OCRed */
  const char *pool = getenv("UV_THREADPOOL_SIZE");
  int most = pool ? atoi(pool) - POOL_SPARE : app_jobs(app);
  o->inflight = app_jobs(app) < most ? app_jobs(app) : most;
  if (o->inflight < 1) o->inflight = 1;
  o->ocr_lua = lapi_ocr_read;
}

char *app_index_path(const struct app *app) {
  const char *index = app_str(app, S_INDEX), *library = app_str(app, S_LIBRARY);
  if (index[0]) return xstrdup(index);
  char *real = realpath(library, NULL);
  const char *lib = real ? real : library;
  const char *base = strrchr(lib, '/');
  base = base && base[1] ? base + 1 : "library";
  char *dir = path_xdg("XDG_DATA_HOME", "~/.local/share/lulibre");
  char *out = xasprintf("%s/%s-%08llx.db", dir, base, hash_fnv1a(lib) & 0xffffffffULL);
  free(dir);
  free(real);
  return out;
}

void app_open_db(struct app *app) {
  if (app->db_ready) return;
  char *err = NULL;
  if (!app_str(app, S_LIBRARY)[0]) {
    const char *env = getenv("LULIBRE_LIBRARY");
    if (env && env[0]) settings_set(app->settings, "path.library", env, FROM_CLI, &err);
    else if (access("metadata.db", R_OK) == 0) settings_set(app->settings, "path.library", ".", FROM_CLI, &err);
    else if (first_library(app)) first_server(app); /* nothing was set: the server too */
    else die("no library: pass -L DIR, set $LULIBRE_LIBRARY, or set opt.path.library in lua/config/options.lua (build/lulibre-setup writes it)");
  }
  const char *library = app_str(app, S_LIBRARY);
  char *real = realpath(library, NULL);
  if (!real) die("library %s: no such directory", library);

  char *path = app_index_path(app);
  db_side_set(app_str(app, S_JOURNAL_DB), app_str(app, S_CUSTOM_DB), app_str(app, S_WIT_DB));
  if (db_open(&app->db, path, &err)) die("%s", err);
  free(path);
  int mirrored = db_mirror(&app->db, real, 0, &err);
  if (mirrored > 0) library_log_outside(&app->db);
  if (mirrored < 0) {
    /* calibre's database there, but not to be read (damaged): lulibre goes
     * on with the library as it last read it */
    char *cal = xasprintf("%s/metadata.db", real);
    int there = access(cal, R_OK) == 0;
    free(cal);
    if (!there) die("%s", err);
    warnf("calibre's database could not be read (%s): lulibre goes on with the library as it last read it", err);
    free(err);
  }
  free(real);
  app->db_ready = 1;
  work_open(app);
}
