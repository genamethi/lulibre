#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>

#include "core/events.h"
#include "core/log.h"
#include "core/queue.h"
#include "library/library.h"
#include "lua/bridge.h"
#include "work.h"
#include "tui/tui.h"

void tui_dirty(struct tui *t) {
  t->dirty = 1;
}

void tui_show_msg(struct tui *t, int error, const char *text) {
  free(t->msg);
  t->msg = xstrdup(text ? text : "");
  t->msg_error = error;
  tui_dirty(t);
}

void tui_msg(struct tui *t, int error, const char *fmt, ...) {
  va_list ap;
  char *s;
  va_start(ap, fmt);
  if (vasprintf(&s, fmt, ap) < 0) s = NULL;
  va_end(ap);
  log_text(error ? LOG_ERROR : LOG_INFO, s ? s : "");
  tui_show_msg(t, error, s);
  free(s);
}


void tui_progress(struct tui *t, const char *text) {
  free(t->progress);
  t->progress = text && *text ? xstrdup(text) : NULL;
  tui_dirty(t);
}

void tui_reload(struct tui *t) {
  rows_reload(t);
}

/* --------------------------------------------------------- background work
 *
 * The indexer and the library are the background thread's (work.h). What
 * they have to say arrives by message; a message finds the interface
 * through app->tui, which is gone once the interface has ended. */

struct indexing {
  int phase; /* -1 started, 0 going, 1 ended */
  int has;   /* stats holds numbers */
  struct index_stats stats;
};

static void indexing_arrived(struct app *app, void *arg) {
  struct indexing *m = arg;
  struct tui *t = app->tui;
  if (t && !t->quit) {
    if (m->phase < 0) {
      t->indexing = 1;
      t->ix_done = t->ix_total = t->ix_failed = 0;
    } else if (m->phase == 0 && m->has) {
      t->ix_done = m->stats.done;
      t->ix_total = m->stats.queued;
      t->ix_failed = m->stats.failed;
    } else if (m->phase > 0) {
      t->indexing = 0;
      if (m->has && m->stats.queued)
        tui_msg(t, 0, "indexed %d files in %.1fs (%d could not be read)", m->stats.ok, m->stats.elapsed,
                m->stats.failed);
      else if (m->has)
        tui_msg(t, 0, "index is up to date");
      rows_reload(t); /* text-based filters may now match more */
    }
    tui_dirty(t);
  }
  free(m);
}

void tui_post_indexing(struct app *app, const struct index_stats *st, int phase) {
  struct indexing *m = xcalloc(1, sizeof *m);
  m->phase = phase;
  if (st) {
    m->stats = *st;
    m->stats.last_path = m->stats.last_error = NULL;
    m->has = 1;
  }
  queue_post(LOOP_UI, indexing_arrived, m);
}

static void index_failed(struct app *app, void *arg) {
  if (app->tui) tui_msg(app->tui, 1, "%s", (char *)arg);
  free(arg);
}

static void index_done(const struct index_stats *st, const char *err, void *ud) { /* the background thread */
  if (err) queue_post(LOOP_UI, index_failed, xstrdup(err));
}

void tui_start_index(struct tui *t, int force) {
  if (t->indexing) {
    tui_msg(t, 1, "indexing is already running");
    return;
  }
  char *err = NULL;
  t->indexing = 1; /* until the background thread says otherwise */
  if (work_index(t->app, 0, force, 0, NULL, index_done, NULL, &err)) {
    t->indexing = 0;
    tui_msg(t, 1, "%s", err);
    free(err);
  }
  tui_dirty(t);
}

/* Calibre changed underneath us (the content server, calibredb, another
 * lulibre): pick it up without being asked. */
static void tick_cb(uv_timer_t *h) {
  struct tui *t = h->data;
  if (t->indexing || t->quit) return; /* the indexer would change it under the mirror */
  tui_mirror(t, 0, 0);
}

struct remirror {
  int told, rc;
  char *err;
};

static void remirror_told(struct app *app, void *arg) {
  struct remirror *m = arg;
  struct tui *t = app->tui;
  if (t) {
    t->mirroring = 0;
    if (!t->quit && m->told) {
      if (m->rc < 0) tui_msg(t, 1, "%s", m->err);
      else tui_msg(t, 0, "reloaded from calibre");
    }
  }
  free(m->err);
  free(m);
}

static void remirrored(int rc, const char *err, void *ud) { /* the background thread */
  struct remirror *m = ud;
  m->rc = rc;
  m->err = err ? xstrdup(err) : NULL;
  queue_post(LOOP_UI, remirror_told, m);
}

static void remirror_work(struct app *app, void *arg) {
  if (!app->library) {
    remirrored(-1, "the library is closed", arg);
    return;
  }
  struct remirror *m = arg;
  library_reload(app->library, m->rc, remirrored, m); /* rc carries force on the way there */
}

/* calibre's records are read on a worker (library_reload); the list
 * follows EV_RECORDS_CHANGED */
void tui_mirror(struct tui *t, int force, int told) {
  if (t->mirroring || !t->app->library) return;
  t->mirroring = 1;
  struct remirror *m = xcalloc(1, sizeof *m);
  m->told = told;
  m->rc = force;
  queue_post(LOOP_WORK, remirror_work, m);
}

/* The records changed: the list shows them; a change made in calibre may
 * bring files to read. */
static void records_changed(const struct event *ev, void *ud) {
  struct tui *t = ud;
  if (t->quit) return;
  rows_reload(t);
  if (!ev->nfields && !t->indexing) tui_start_index(t, 0);
}

/* -------------------------------------------------------------------- run */

void tui_setup(void) {
  static int done;
  if (done) return;
  done = 1;
  commands_builtin();
  keymap_defaults(&tui_keymap);
  ctx_defaults();
}

void tui_teardown(void) {
  commands_free();
  keymap_free(&tui_keymap);
  ctx_free();
  tui_pager_forget();
  guides_forget();
}

static void closed(uv_handle_t *h) {
  (void)h;
}

static void freed(uv_handle_t *h) {
  free(h);
}

/* Take the terminal: notcurses, raw keys, the mouse. */
static void terminal_start(struct tui *t) {
  struct notcurses_options no = {.flags = NCOPTION_SUPPRESS_BANNERS};
  t->nc = notcurses_core_init(&no, NULL);
  if (!t->nc) die("cannot initialise the terminal (TERM=%s)", getenv("TERM") ? getenv("TERM") : "");
  notcurses_linesigs_disable(t->nc); /* Ctrl-C is a key, not a signal */
  crash_install(); /* again, to run before notcurses' handlers, which give the terminal back */
  bracketed_paste(1);
  if (app_bool(t->app, S_MOUSE)) notcurses_mice_enable(t->nc, NCMICE_BUTTON_EVENT | NCMICE_DRAG_EVENT);
  t->std = notcurses_stdplane(t->nc);
  t->nc_gen++;
}

/* notcurses reads the terminal on a thread of its own and says when it has
 * keys through a descriptor of its own: that is watched */
static void input_watch(struct tui *t) {
  t->input = xcalloc(1, sizeof *t->input);
  uv_poll_init(t->app->loop, t->input, notcurses_inputready_fd(t->nc));
  t->input->data = t;
  uv_poll_start(t->input, UV_READABLE, input_read_cb);
}

static void input_unwatch(struct tui *t) {
  if (!t->input) return;
  uv_poll_stop(t->input);
  uv_close((uv_handle_t *)t->input, freed);
  t->input = NULL;
}

/* a program on $PATH, as a malloc'd path; NULL when there is none */
static char *which(const char *name) {
  const char *path = getenv("PATH");
  if (!path) path = "/usr/bin:/bin";
  while (*path) {
    const char *end = strchr(path, ':');
    size_t n = end ? (size_t)(end - path) : strlen(path);
    char *full = xasprintf("%.*s/%s", (int)n, path, name);
    if (access(full, X_OK) == 0) return full;
    free(full);
    path += n + (end ? 1 : 0);
  }
  return NULL;
}

/* A program given the terminal whole (the editor, sudo asking for a
 * password). notcurses cannot simply step aside (its input thread would take
 * the program's keys), so it is stopped and started again around it; the
 * planes it held go with it (nc_gen tells the preview so), and everything is
 * drawn afresh. argv[0] is looked for on $PATH. Returns its exit status;
 * 127 when it could not be run, -1 when it did not exit. */
int tui_in_terminal(struct tui *t, char *const argv[]) {
  input_unwatch(t);
  terminal_release(t);
  int status = -1;
  struct sigaction ign = {.sa_handler = SIG_IGN}, old_int, old_quit;
  sigaction(SIGINT, &ign, &old_int);
  sigaction(SIGQUIT, &ign, &old_quit);
  pid_t pid = fork();
  if (pid == 0) {
    signal(SIGINT, SIG_DFL);
    signal(SIGQUIT, SIG_DFL);
    execvp(argv[0], argv);
    _exit(127);
  } else if (pid > 0) {
    int st;
    while (waitpid(pid, &st, 0) < 0 && errno == EINTR) {
    }
    status = WIFEXITED(st) ? WEXITSTATUS(st) : -1;
  }
  sigaction(SIGINT, &old_int, NULL);
  sigaction(SIGQUIT, &old_quit, NULL);
  terminal_start(t);
  input_watch(t);
  notcurses_refresh(t->nc, NULL, NULL);
  tui_dirty(t);
  return status;
}

/* The editor ($VISUAL, $EDITOR, else vim or vi) on a file, in the terminal. */
int tui_edit_file(struct tui *t, const char *path) {
  const char *editor = getenv("VISUAL");
  if (!editor || !*editor) editor = getenv("EDITOR");
  char *fallback = NULL;
  if (!editor || !*editor) {
    fallback = which("vim");
    if (!fallback) fallback = which("vi");
    if (!fallback) return -1;
    editor = fallback;
  }
  /* through the shell, so that EDITOR="code --wait" works */
  char *argv[] = {"/bin/sh", "-c", "exec $0 \"$1\"", (char *)editor, (char *)path, NULL};
  int status = tui_in_terminal(t, argv);
  free(fallback);
  return status;
}

int tui_run(struct app *app) {
  if (!isatty(STDIN_FILENO) || !isatty(STDOUT_FILENO)) {
    warnf("the interactive interface needs a terminal; see `lulibre -h` for commands");
    return 2;
  }
  app_open_db(app);
  library_resume(app->library); /* before the background thread starts, which owns it then */

  struct tui tui, *t = &tui;
  memset(t, 0, sizeof *t);
  t->app = app;
  char *err = NULL;
  if (db_open_reader(&t->rdb, app->db.path, &err)) die("%s", err);

  terminal_start(t);

  t->mode = MODE_NORMAL;
  tui_setup();
  t->km = &tui_keymap;
  app->tui = t;
  rows_init(t);
  wm_init(t);
  events_listen(LOOP_UI, EV_RECORDS_CHANGED, records_changed, t);

  uv_loop_t *loop = app->loop;
  input_watch(t);
  uv_prepare_init(loop, &t->prepare);
  uv_timer_init(loop, &t->tick);
  uv_timer_init(loop, &t->settle);
  uv_timer_init(loop, &t->ftimer);
  uv_timer_init(loop, &t->held_timer);
  t->held_timer.data = t;
  t->prepare.data = t->tick.data = t->settle.data = t->ftimer.data = t;
  uv_prepare_start(&t->prepare, render_prepare_cb);
  uv_timer_start(&t->tick, tick_cb, 2000, 2000);

  rows_set_filter(t, "");
  history_load(t);
  /* first run, or books added since the last one: index in the background */
  sqlite3_stmt *st;
  if (sqlite3_prepare_v2(app->db.h, "SELECT count(*) FROM files WHERE outcome = 0", -1, &st, NULL) ==
      SQLITE_OK) {
    int pending = sqlite3_step(st) == SQLITE_ROW ? sqlite3_column_int(st, 0) : 0;
    sqlite3_finalize(st);
    const char *policy = app_str(app, S_AUTO_INDEX);
    if (pending && !strcmp(policy, "auto")) tui_start_index(t, 0);
    else if (pending && !strcmp(policy, "ask"))
      tui_msg(t, 0, "%d file%s not indexed yet; :index reads them", pending, pending == 1 ? " is" : "s are");
  }
  char *mismatch = lstate_tree_mismatch();
  if (mismatch) tui_msg(t, 1, "%s", mismatch);
  free(mismatch);
  tui_dirty(t);
  log_to_stderr(0); /* the terminal is ours; the console shows the log */
  log_on_entry(log_arrived, app);
  log_debug("interface up: %d books listed from %s", t->rows.n, app_str(app, S_LIBRARY));
  work_start(app);   /* from here on the library and the indexer are the background thread's */
  bridge_start(app); /* and Lua runs on its own thread */
  uv_run(loop, UV_RUN_DEFAULT);

  /* Give the terminal back first, then let work in flight finish. */
  t->quit = 1;
  if (t->picker) picker_close(t);
  tui_input_cancel(t);
  bridge_stop(app); /* scripts stop with the interface; their thread ends */
  lstate_close(app); /* what waited on Lua's answers is told it will not come */
  work_stop(app);    /* what is running ends; changes still queued stay in the journal */
  log_on_entry(NULL, NULL);
  wm_free(t);
  terminal_release(t);
  log_to_stderr(1);
  input_unwatch(t);
  uv_close((uv_handle_t *)&t->prepare, closed);
  uv_close((uv_handle_t *)&t->tick, closed);
  uv_close((uv_handle_t *)&t->settle, closed);
  uv_close((uv_handle_t *)&t->ftimer, closed);
  uv_close((uv_handle_t *)&t->held_timer, closed);
  uv_run(loop, UV_RUN_DEFAULT);

  events_unlisten_all(LOOP_UI, records_changed);
  rows_free(t);
  sb_free(&t->paste);
  clip_free();
  app->tui = NULL;
  le_free(&t->line);
  for (int k = 0; k < 3; k++) {
    for (int i = 0; i < t->hist[k].n; i++) free(t->hist[k].v[i]);
    free(t->hist[k].v);
  }
  free(t->hist_prefix);
  free(t->comp_ctx);
  free(t->comp_got_ctx);
  for (int i = 0; i < t->ncomp_got; i++) {
    free(t->comp_got[i]);
    free(t->comp_got_detail[i]);
  }
  free(t->comp_got);
  free(t->comp_got_detail);
  free(t->prompt_saved);
  free(t->input_label);
  free(t->progress);
  for (int i = 0; i < t->nbadges; i++) {
    free(t->badges[i].name);
    free(t->badges[i].text);
  }
  suggest_clear(t);
  free(t->msg);
  db_close(&t->rdb);
  return 0;
}
