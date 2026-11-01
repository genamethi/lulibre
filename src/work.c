/* The background thread (work.h). */
#include "work.h"

#include <stdlib.h>
#include <string.h>

#include <uv.h>

#include "app.h"
#include "core/log.h"
#include "core/queue.h"
#include "core/settings.h"
#include "core/util.h"
#include "db/query.h"
#include "index/indexer.h"
#include "library/library.h"
#include "tui/tui.h"

/* An index run asked for: the options it runs by, and who to tell. */
struct run_req {
  struct index_opts o;
  char *ocr_lang;
  struct query only;
  int has_only;
  work_index_done *done;
  void *ud;
};

static struct {
  struct app *app;
  int threaded, started;
  uv_loop_t loop;
  uv_thread_t thread;
  uv_async_t alive; /* keeps the loop running while it has nothing else */
  uv_timer_t stopping;
  struct db db;
  union setting_value v[S_COUNT];
  /* the index run: the request that started it, and those told at its end */
  struct indexer *ix;
  struct run_req *run;
  struct run_req **waiting;
  int nwaiting;
} W;

void work_init(struct app *app, int threaded) {
  W.app = app;
  W.threaded = threaded;
  if (threaded) {
    uv_loop_init(&W.loop);
    app->wloop = &W.loop;
  } else {
    app->wloop = app->loop;
  }
}

/* ---- the settings' copy ---- */

static int is_text(int def) {
  return setting_defs[def].type == SETTING_STR || setting_defs[def].type == SETTING_PATH;
}

static void put(int def, union setting_value v) {
  if (is_text(def)) free(W.v[def].s);
  W.v[def] = v;
}

static union setting_value copy_of(const struct settings *st, int def) {
  union setting_value v = *settings_value(st, def);
  if (is_text(def)) v.s = xstrdup(v.s);
  return v;
}

struct changed {
  int def;
  union setting_value v;
};

static void setting_arrived(struct app *app, void *arg) {
  struct changed *c = arg;
  put(c->def, c->v);
  free(c);
}

void work_setting_changed(struct app *app, int def) {
  if (!app->wdb) return; /* no copy yet: work_open takes the values then */
  if (def >= S_COUNT) return; /* one made in Lua: nothing here reads it */
  struct changed *c = xcalloc(1, sizeof *c);
  c->def = def;
  c->v = copy_of(app->settings, def);
  queue_post(LOOP_WORK, setting_arrived, c);
}

const char *work_str(enum setting_id id) {
  return W.v[id].s;
}

long long work_int(enum setting_id id) {
  return W.v[id].i;
}

int work_bool(enum setting_id id) {
  return W.v[id].b;
}

/* ---- the thread ---- */

void work_open(struct app *app) {
  for (int i = 0; i < S_COUNT; i++) put(i, copy_of(app->settings, i));
  if (W.threaded) {
    char *err = NULL;
    if (db_open_writer(&W.db, app->db.path, &err)) die("%s", err);
    app->wdb = &W.db;
  } else {
    app->wdb = &app->db;
  }
  app->library = library_open(app);
}

static void work_main(void *arg) {
  uv_run(&W.loop, UV_RUN_DEFAULT);
}

void work_start(struct app *app) {
  if (!W.threaded || W.started) return;
  W.started = 1;
  uv_async_init(&W.loop, &W.alive, NULL);
  if (uv_thread_create(&W.thread, work_main, NULL)) die("cannot start the background thread");
  log_debug("background thread started");
}

static void closed(uv_handle_t *h) {
}

/* Every half tenth of a second while stopping: once the indexer has ended
 * and the library has nothing running, it closes, and the loop ends. */
static void stopping_cb(uv_timer_t *h) {
  struct app *app = W.app;
  if (W.ix || (app->library && !library_idle(app->library))) return;
  if (app->library) library_close(app->library);
  uv_close((uv_handle_t *)&W.stopping, closed);
  uv_close((uv_handle_t *)&W.alive, closed);
}

static void stop_on_work(struct app *app, void *arg) {
  if (W.ix) indexer_cancel(W.ix);
  uv_timer_init(&W.loop, &W.stopping);
  uv_timer_start(&W.stopping, stopping_cb, 0, 50);
}

void work_stop(struct app *app) {
  if (!W.threaded) {
    if (app->library) library_close(app->library);
    app->library = NULL;
    return;
  }
  if (!W.started) {
    if (app->library) library_close(app->library);
  } else {
    queue_post(LOOP_WORK, stop_on_work, NULL);
    uv_thread_join(&W.thread);
    W.started = 0;
    log_debug("background thread ended");
  }
  app->library = NULL;
  queue_drain(LOOP_WORK); /* what came too late: it finds no library */
  uv_run(&W.loop, UV_RUN_NOWAIT); /* the handles' close callbacks */
  if (app->wdb == &W.db) db_close(&W.db);
  app->wdb = NULL;
  for (int i = 0; i < S_COUNT; i++)
    if (is_text(i)) {
      free(W.v[i].s);
      W.v[i].s = NULL;
    }
}

/* ---- index runs ---- */

static void run_free(struct run_req *r) {
  if (r->has_only) query_free(&r->only);
  free(r->ocr_lang);
  free(r);
}

static void progress(struct indexer *ix, const struct index_stats *st, void *ud) {
  tui_post_indexing(W.app, st, 0);
}

static void ended(struct indexer *ix, const struct index_stats *st, void *ud) {
  struct index_stats s = *st; /* st lives inside the indexer being freed */
  s.last_path = s.last_error = NULL;
  indexer_free(W.ix);
  W.ix = NULL;
  W.run->done(&s, NULL, W.run->ud);
  run_free(W.run);
  W.run = NULL;
  for (int i = 0; i < W.nwaiting; i++) {
    W.waiting[i]->done(&s, NULL, W.waiting[i]->ud);
    run_free(W.waiting[i]);
  }
  W.nwaiting = 0;
  tui_post_indexing(W.app, &s, 1);
}

static void run_on_work(struct app *app, void *arg) {
  struct run_req *r = arg;
  if (W.ix) {
    W.waiting = xrealloc(W.waiting, (size_t)(W.nwaiting + 1) * sizeof *W.waiting);
    W.waiting[W.nwaiting++] = r;
    return;
  }
  char *err = NULL;
  W.run = r;
  tui_post_indexing(app, NULL, -1);
  W.ix = indexer_start(app->wloop, app->wdb, &r->o, progress, ended, NULL, &err);
  if (!W.ix) {
    W.run = NULL;
    r->done(NULL, err, r->ud);
    tui_post_indexing(app, NULL, 1);
    free(err);
    run_free(r);
  }
}

int work_index(struct app *app, int pages, int force, int retry, const char *filter, work_index_done *done, void *ud,
               char **err) {
  struct run_req *r = xcalloc(1, sizeof *r);
  if (filter) {
    if (query_compile_in(filter, SCOPE_ALL, &r->only, err)) {
      free(r);
      return -1;
    }
    r->has_only = 1;
    r->o.only = &r->only;
  }
  app_index_opts(app, &r->o);
  r->ocr_lang = xstrdup(r->o.ocr_lang); /* the store's may change meanwhile */
  r->o.ocr_lang = r->ocr_lang;
  if (pages > 0) r->o.pages = pages;
  r->o.force = force;
  r->o.retry = retry;
  r->done = done;
  r->ud = ud;
  queue_post(LOOP_WORK, run_on_work, r);
  return 0;
}
