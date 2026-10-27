#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "app.h"
#include "cmd/cmd.h"
#include "core/util.h"
#include "index/indexer.h"

struct run {
  int tty, verbose;
  double last_draw;
  uv_signal_t sigint;
  struct indexer *ix;
  struct index_stats final;
  int interrupted;
};

static void draw(struct run *r, const struct index_stats *st, int force) {
  double now = now_s();
  if (!r->tty) {
    if (force || st->done % 500 == 0)
      fprintf(stderr, "%d/%d files, %d failed, %.1fs\n", st->done, st->queued, st->failed,
              st->elapsed);
    return;
  }
  if (!force && now - r->last_draw < 0.1) return;
  r->last_draw = now;
  fprintf(stderr, "\r\033[K%d/%d files  %.0f/s  %d failed", st->done, st->queued,
          st->elapsed > 0 ? st->done / st->elapsed : 0.0, st->failed);
  fflush(stderr);
}

static void on_progress(struct indexer *ix, const struct index_stats *st, void *ud) {
  struct run *r = ud;
  if (st->last_error && r->verbose) {
    if (r->tty) fputs("\r\033[K", stderr);
    fprintf(stderr, "failed: %s: %s\n", st->last_path, st->last_error);
  }
  draw(r, st, 0);
}

static void on_done(struct indexer *ix, const struct index_stats *st, void *ud) {
  struct run *r = ud;
  r->final = *st;
  if (r->tty && st->queued) fputs("\r\033[K", stderr);
  uv_signal_stop(&r->sigint);
  uv_close((uv_handle_t *)&r->sigint, NULL);
}

static void on_sigint(uv_signal_t *h, int signum) {
  struct run *r = h->data;
  if (r->interrupted) _exit(130);
  r->interrupted = 1;
  if (r->tty) fputs("\r\033[K", stderr);
  fprintf(stderr, "interrupted: finishing files in flight (what is stored so far is kept)\n");
  indexer_cancel(r->ix);
}

static const char help[] =
  "usage: lulibre index [options] [filter]\n\n"
  "Extract the first pages of every file in the library into the search index.\n"
  "Unchanged files are skipped, so this is cheap to re-run and safe to interrupt.\n\n"
  "  --pages N          pages of text per file            (option: pages)\n"
  "  --layout-pages N   pages also kept as tagged lines   (option: layout_pages)\n"
  "  --force            re-extract everything\n"
  "  --retry            retry files that failed before\n"
  "  -v                 print each failure as it happens\n"
  "  filter             only books matching this filter, e.g. fmt:djvu\n";

int cmd_index(struct app *app, int argc, char **argv) {
  struct index_opts o = {0};
  struct run r = {0};
  sbuf filter = SBUF_INIT;
  char *err = NULL;

  for (int i = 1; i < argc; i++) {
    const char *a = argv[i];
    if (!strcmp(a, "-h") || !strcmp(a, "--help")) { fputs(help, stdout); return 0; }
    else if (!strcmp(a, "--force")) o.force = 1;
    else if (!strcmp(a, "--retry")) o.retry = 1;
    else if (!strcmp(a, "-v")) r.verbose = 1;
    else if (!strcmp(a, "--pages") && i + 1 < argc) {
      if (settings_set(app->settings, "pages", argv[++i], FROM_CLI, &err)) die("%s", err);
    } else if (!strcmp(a, "--layout-pages") && i + 1 < argc) {
      if (settings_set(app->settings, "layout_pages", argv[++i], FROM_CLI, &err)) die("%s", err);
    } else {
      if (filter.len) sb_putc(&filter, ' ');
      sb_puts(&filter, a);
    }
  }

  app_open_db(app);
  o.pages = (int)app_int(app, S_PAGES);
  o.layout_pages = (int)app_int(app, S_LAYOUT_PAGES);
  if (o.layout_pages > o.pages) o.layout_pages = o.pages;
  o.inflight = app_jobs(app) + app_jobs(app) / 2;

  struct query q = {0};
  if (filter.len) {
    if (query_compile(filter.s, &q, &err)) die("filter: %s", err);
    o.only = &q;
  }

  r.tty = isatty(STDERR_FILENO);
  uv_signal_init(app->loop, &r.sigint);
  r.sigint.data = &r;
  uv_signal_start(&r.sigint, on_sigint, SIGINT);

  r.ix = indexer_start(app->loop, &app->db, &o, on_progress, on_done, &r, &err);
  if (!r.ix) die("%s", err);
  uv_run(app->loop, UV_RUN_DEFAULT);
  indexer_free(r.ix);
  query_free(&q);
  sb_free(&filter);

  const struct index_stats *st = &r.final;
  double opt = 0;
  if (st->ok > 500 && !r.interrupted) {
    double t0 = now_s();
    sqlite3_exec(app->db.h, "INSERT INTO pages_fts(pages_fts) VALUES('optimize')", NULL, NULL,
                 NULL);
    opt = now_s() - t0;
  }
  sqlite3_exec(app->db.h, "PRAGMA wal_checkpoint(TRUNCATE)", NULL, NULL, NULL);

  struct stat sb;
  double mb = stat(app->db.path, &sb) == 0 ? (double)sb.st_size / (1024.0 * 1024.0) : 0;
  printf("files      %d considered, %d already current, %d missing on disk\n", st->files,
         st->current, st->missing);
  printf("extracted  %d ok, %d failed, %ld pages, %ld characters\n", st->ok, st->failed,
         st->pages, st->chars);
  printf("time       %.2fs", st->elapsed);
  if (st->done && st->elapsed > 0) printf(" (%.0f files/s, %d threads)", st->done / st->elapsed, app_jobs(app));
  if (opt > 0) printf(", +%.2fs optimising the text index", opt);
  printf("\nindex      %s (%.1f MB)\n", app->db.path, mb);
  if (st->failed) printf("failures   list them with: lulibre query is:error\n");
  return r.interrupted ? 130 : 0;
}
