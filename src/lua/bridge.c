#include "core/log.h"
#include "lua/bridge.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#include <lauxlib.h>
#include <uv.h>

#include "app.h"
#include "core/queue.h"
#include "core/util.h"
#include "lua/lapi.h"
#include "lua/sched.h"
#include "tui/tui.h"

/* One per process, and never freed: the Lua loop's handles are released
 * with the process. */
static struct bridge {
  struct app *app;
  int threaded;       /* Lua has its own loop */
  atomic_int running; /* ...and its own thread is running it */
  uv_loop_t lloop;
  uv_thread_t ui_thread, lua_thread;
  uv_async_t to_ui;
  uv_async_t alive; /* keeps the Lua loop running while it has nothing else */
  atomic_int redraw, exited;
  uv_timer_t winddown;
  double stop_at;
  int handles;                   /* the handles that outlive a restart are made */
  void (*then)(struct app *app); /* a restart's next step, once the Lua thread is gone */
  int said_jobs;
  struct db ldb;
} B;

void bridge_init(struct app *app, int threaded) {
  B.app = app;
  B.threaded = threaded;
  if (threaded) {
    uv_loop_init(&B.lloop);
    app->lloop = &B.lloop;
  } else {
    app->lloop = app->loop;
  }
}

/* True when the caller may touch the interface directly. */
static int bridge_on_ui(const struct app *app) {
  if (!atomic_load(&B.running)) return 1;
  uv_thread_t self = uv_thread_self();
  return uv_thread_equal(&self, &B.ui_thread);
}

/* ---- Lua -> interface: a redraw; every call goes by the queue
 * (core/queue.h, lua/uicall.c) ---- */

static void restart_done(void);

static void to_ui_cb(uv_async_t *h) {
  if (atomic_exchange(&B.redraw, 0) && B.app->tui) tui_dirty(B.app->tui);
  if (B.then && atomic_load(&B.exited)) restart_done();
}

void bridge_redraw(struct app *app) {
  if (bridge_on_ui(app)) {
    if (app->tui) tui_dirty(app->tui);
    return;
  }
  atomic_store(&B.redraw, 1);
  uv_async_send(&B.to_ui);
}

/* ---- the Lua thread ---- */

static void lua_main(void *arg) {
  uv_run(&B.lloop, UV_RUN_DEFAULT);
  atomic_store(&B.exited, 1);
  uv_async_send(&B.to_ui);
}

void bridge_start(struct app *app) {
  if (!B.threaded || atomic_load(&B.running)) return;
  char *err = NULL;
  if (db_open_writer(&B.ldb, app->db.path, &err)) die("%s", err);
  app->ldb = &B.ldb;
  if (!B.handles) { /* once: a restart keeps them */
    B.handles = 1;
    uv_async_init(app->loop, &B.to_ui, to_ui_cb);
    uv_async_init(&B.lloop, &B.alive, NULL);
  }
  B.ui_thread = uv_thread_self();
  atomic_store(&B.exited, 0);
  atomic_store(&B.running, 1);
  if (uv_thread_create(&B.lua_thread, lua_main, NULL)) die("cannot start the Lua thread");
  log_debug("Lua thread started");
}

/* Tasks were told to stop; leave once they have, or after a moment. Never
 * while a worker job is running: it may be writing (a copy of a database put
 * back), and only its end lets the cancelled task close what it holds. */
static void winddown_cb(uv_timer_t *h) {
  int jobs = sched_jobs(B.app);
  if (jobs > 0) {
    if (now_s() > B.stop_at && !B.said_jobs) {
      B.said_jobs = 1;
      log_info("waiting for %d job%s to finish before leaving", jobs, jobs == 1 ? "" : "s");
    }
    return;
  }
  if (sched_live(B.app) == 0 || now_s() > B.stop_at) {
    uv_timer_stop(&B.winddown);
    uv_close((uv_handle_t *)&B.winddown, NULL);
    uv_stop(&B.lloop);
  }
}

static void stop_on_lua(struct app *app, void *arg) {
  sched_cancel_all(app);
  B.stop_at = now_s() + 1.5;
  uv_timer_init(&B.lloop, &B.winddown);
  uv_timer_start(&B.winddown, winddown_cb, 0, 10);
}

static void closed(uv_handle_t *h) {
}

/* After the Lua thread has gone: what is left for it runs here, on the
 * old lua_State, which is the caller's to close. */
static void after_thread(struct app *app) {
  uv_thread_join(&B.lua_thread);
  log_debug("Lua thread ended");
  atomic_store(&B.running, 0);
  queue_drain(LOOP_LUA);
  db_close(&B.ldb);
  app->ldb = NULL;
}

static void restart_done(void) {
  void (*then)(struct app *) = B.then;
  B.then = NULL;
  after_thread(B.app);
  then(B.app);
}

void bridge_restart(struct app *app, void (*then)(struct app *app)) {
  if (!atomic_load(&B.running) || B.then) return;
  B.then = then;
  B.said_jobs = 0;
  queue_post(LOOP_LUA, stop_on_lua, NULL);
}

void bridge_stop(struct app *app) {
  if (!atomic_load(&B.running)) return;
  queue_post(LOOP_LUA, stop_on_lua, NULL);
  /* Tasks being cancelled may still call in (to close a panel, to report);
   * keep answering until the thread is gone. */
  while (!atomic_load(&B.exited)) uv_run(app->loop, UV_RUN_ONCE);
  B.then = NULL;
  /* messages that arrived too late for the Lua thread run here: each owns
   * what it carries and is what frees it */
  after_thread(app);
  to_ui_cb(&B.to_ui);
  uv_close((uv_handle_t *)&B.to_ui, closed);
}
