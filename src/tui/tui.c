#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>

#include "core/log.h"
#include "library/library.h"
#include "lua/bridge.h"
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

void tui_pager(struct tui *t, const char *title, const char *text) {
  free(t->help);
  free(t->pager_title);
  t->help = xstrdup(text ? text : "");
  t->pager_title = xstrdup(title ? title : "");
  t->help_scroll = 0;
  tui_dirty(t);
}

void tui_progress(struct tui *t, const char *text) {
  free(t->progress);
  t->progress = text && *text ? xstrdup(text) : NULL;
  tui_dirty(t);
}

void tui_reload(struct tui *t) {
  rows_reload(t);
}

/* --------------------------------------------------------- background work */

static void ix_progress(struct indexer *ix, const struct index_stats *st, void *ud) {
  struct tui *t = ud;
  t->ix_done = st->done;
  t->ix_total = st->queued;
  t->ix_failed = st->failed;
  tui_dirty(t);
}

static void ix_done(struct indexer *ix, const struct index_stats *st, void *ud) {
  struct tui *t = ud;
  struct index_stats s = *st; /* st lives inside the indexer being freed */
  indexer_free(t->ix);
  t->ix = NULL;
  /* tell whoever was waiting, even when leaving: their memory is theirs to free */
  int nhook = t->nix_hook;
  t->nix_hook = 0;
  for (int i = 0; i < nhook; i++) t->ix_hook[i](&s, t->ix_hook_ud[i]);
  if (t->quit) return;
  if (s.queued)
    tui_msg(t, 0, "indexed %d files in %.1fs (%d could not be read)", s.ok, s.elapsed, s.failed);
  else
    tui_msg(t, 0, "index is up to date");
  rows_reload(t); /* text-based filters may now match more */
}

void tui_start_index(struct tui *t, int force) {
  if (t->ix) {
    tui_msg(t, 1, "indexing is already running");
    return;
  }
  struct index_opts o = {0};
  char *err = NULL;
  app_index_opts(t->app, &o);
  o.force = force;
  t->ix_done = t->ix_total = t->ix_failed = 0;
  t->ix = indexer_start(t->app->loop, &t->app->db, &o, ix_progress, ix_done, t, &err);
  if (!t->ix) {
    tui_msg(t, 1, "%s", err);
    free(err);
  }
  tui_dirty(t);
}

int tui_index(struct tui *t, const struct index_opts *o, void (*done)(const struct index_stats *st, void *ud),
              void *ud, char **err) {
  if (t->nix_hook == 8) {
    *err = xstrdup("too many scripts are waiting for the indexer");
    return -1;
  }
  if (!t->ix) {
    t->ix_done = t->ix_total = t->ix_failed = 0;
    t->ix = indexer_start(t->app->loop, &t->app->db, o, ix_progress, ix_done, t, err);
    if (!t->ix) return -1;
    tui_dirty(t);
  }
  t->ix_hook[t->nix_hook] = done;
  t->ix_hook_ud[t->nix_hook++] = ud;
  return 0;
}

/* Calibre changed underneath us (the content server, calibredb, another
 * lulibre): pick it up without being asked. */
static void tick_cb(uv_timer_t *h) {
  struct tui *t = h->data;
  if (t->ix || t->quit) return; /* the indexer would change it under the mirror */
  tui_mirror(t, 0, 0);
}

struct remirror {
  struct tui *t;
  int force, told, rc;
  char *library; /* resolved when the message was made */
  char *err;
};

static void remirror_done(void *arg) { /* interface thread */
  struct remirror *m = arg;
  struct tui *t = m->t;
  t->mirroring = 0;
  if (!t->quit) {
    if (m->rc < 0) {
      if (m->told) tui_msg(t, 1, "%s", m->err);
    } else {
      if (m->rc > 0 || m->force) rows_reload(t);
      if (m->told) tui_msg(t, 0, "reloaded from calibre");
      else if (m->rc > 0) tui_start_index(t, 0);
    }
  }
  free(m->err);
  free(m->library);
  free(m);
}

static void remirror_lua(struct app *app, void *arg) { /* Lua thread, between tasks */
  struct remirror *m = arg;
  m->rc = db_mirror(app->ldb ? app->ldb : &app->db, m->library, m->force, &m->err);
  bridge_ui(app, remirror_done, m);
}

void tui_mirror(struct tui *t, int force, int told) {
  if (t->mirroring) return;
  t->mirroring = 1;
  struct remirror *m = xcalloc(1, sizeof *m);
  m->t = t;
  m->force = force;
  m->told = told;
  m->library = realpath(app_str(t->app, S_LIBRARY), NULL); /* taken now (design 4) */
  if (!m->library) m->library = xstrdup(app_str(t->app, S_LIBRARY));
  bridge_lua(t->app, remirror_lua, m);
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
  library_resume(app->library);

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
  bridge_start(app); /* from here on Lua runs on its own thread */
  uv_run(loop, UV_RUN_DEFAULT);

  /* Give the terminal back first, then let work in flight finish. */
  t->quit = 1;
  if (t->picker) picker_close(t);
  tui_input_cancel(t);
  bridge_stop(app); /* scripts stop with the interface; their thread ends */
  log_on_entry(NULL, NULL);
  wm_free(t);
  terminal_release(t);
  log_to_stderr(1);
  if (t->ix) indexer_cancel(t->ix);
  input_unwatch(t);
  uv_close((uv_handle_t *)&t->prepare, closed);
  uv_close((uv_handle_t *)&t->tick, closed);
  uv_close((uv_handle_t *)&t->settle, closed);
  uv_close((uv_handle_t *)&t->ftimer, closed);
  uv_close((uv_handle_t *)&t->held_timer, closed);
  uv_run(loop, UV_RUN_DEFAULT);

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
  free(t->prompt_saved);
  free(t->input_label);
  free(t->progress);
  for (int i = 0; i < t->nbadges; i++) {
    free(t->badges[i].name);
    free(t->badges[i].text);
  }
  suggest_clear(t);
  free(t->pager_title);
  free(t->help);
  free(t->msg);
  db_close(&t->rdb);
  return 0;
}
