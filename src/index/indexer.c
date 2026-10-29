#include "index/indexer.h"

#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>

#include "core/util.h"
#include "doc/doc.h"
#include "core/log.h"
#include "core/registry.h"
#include "index/ocr.h"
#include "index/outcome.h"

struct job {
  uv_work_t req;
  struct indexer *ix;
  sqlite3_int64 file;
  char *path, *format;
  long long size, mtime;
  struct doc_info info;
  enum file_outcome outcome; /* set on the worker */
  int ocr_pages;             /* pages OCR read, 0 when it did not */
  int ocr_lua;               /* OCR is for the reader Lua put in tesseract's place */
};

struct indexer {
  uv_loop_t *loop;
  struct db *db;
  struct index_opts o;
  struct doc_opts dopts;
  char *ocr_lang;  /* o.ocr_lang's copy */
  char *tesseract; /* NULL: no OCR reader */
  indexer_cb *progress, *done;
  void *ud;

  struct job **jobs;
  int njobs, next, inflight;
  int cancelled, finished;

  sqlite3_stmt *del_paras, *del_lines, *ins_line, *ins_para, *upd_file;
  int in_txn, since_commit;
  double last_commit;

  /* Extracted and not yet stored: another connection had the write lock.
   * They still count as in flight, so extraction waits with them. */
  struct job **held;
  int nheld, capheld;
  uv_timer_t *retry;

  struct index_stats st;
};

static void job_free(struct job *j) {
  doc_info_free(&j->info);
  free(j->path);
  free(j->format);
  free(j);
}

/* Without waiting: the indexer runs on the interface's thread, and a
 * script's transaction may hold the write lock for a while. -1 if it does. */
static int txn_begin(struct indexer *ix) {
  if (ix->in_txn) return 0;
  sqlite3_busy_timeout(ix->db->h, 0);
  int rc = sqlite3_exec(ix->db->h, "BEGIN IMMEDIATE", NULL, NULL, NULL);
  sqlite3_busy_timeout(ix->db->h, DB_BUSY_MS);
  if (rc != SQLITE_OK) return -1;
  ix->in_txn = 1;
  ix->since_commit = 0;
  ix->last_commit = now_s();
  return 0;
}

static void txn_commit(struct indexer *ix) {
  if (!ix->in_txn) return;
  sqlite3_exec(ix->db->h, "COMMIT", NULL, NULL, NULL);
  ix->in_txn = 0;
}

static void bind_text(sqlite3_stmt *st, int i, const char *s) {
  if (s) sqlite3_bind_text(st, i, s, -1, SQLITE_TRANSIENT);
  else sqlite3_bind_null(st, i);
}

static void run(sqlite3_stmt *st) {
  sqlite3_step(st);
  sqlite3_reset(st);
  sqlite3_clear_bindings(st);
}

/* The paragraph built so far, as one full-text row keyed by its first
 * line. */
static void flush_para(struct indexer *ix, sqlite3_int64 first, sbuf *para) {
  if (!first || !para->len) return;
  sqlite3_bind_int64(ix->ins_para, 1, first);
  sqlite3_bind_text(ix->ins_para, 2, para->s, (int)para->len, SQLITE_TRANSIENT);
  run(ix->ins_para);
  sb_reset(para);
}

/* Inside a transaction (txn_begin). The lines replace the file's lines, and
 * each paragraph is a row of paragraphs_fts: a paragraph starts at a line
 * flagged LINE_BLOCK, and at the first line of each page. */
static void store(struct indexer *ix, struct job *j) {
  struct doc_info *d = &j->info;

  sqlite3_bind_int64(ix->del_paras, 1, j->file);
  run(ix->del_paras);
  sqlite3_bind_int64(ix->del_lines, 1, j->file);
  run(ix->del_lines);

  sbuf para = SBUF_INIT;
  sqlite3_int64 first = 0;
  for (int i = 0; i < d->n; i++) {
    struct doc_page *pg = &d->pages[i];
    for (int k = 0; k < pg->nlines; k++) {
      struct doc_line *l = &pg->lines[k];
      unsigned flags = l->flags | (k == 0 ? LINE_BLOCK : 0);
      sqlite3_bind_int64(ix->ins_line, 1, j->file);
      sqlite3_bind_int(ix->ins_line, 2, pg->no);
      sqlite3_bind_int(ix->ins_line, 3, k);
      sqlite3_bind_text(ix->ins_line, 4, l->text, -1, SQLITE_TRANSIENT);
      sqlite3_bind_double(ix->ins_line, 5, l->size);
      sqlite3_bind_int(ix->ins_line, 6, (int)flags);
      sqlite3_bind_double(ix->ins_line, 7, l->x0);
      sqlite3_bind_double(ix->ins_line, 8, l->y0);
      sqlite3_bind_double(ix->ins_line, 9, l->x1);
      sqlite3_bind_double(ix->ins_line, 10, l->y1);
      bind_text(ix->ins_line, 11, l->math);
      run(ix->ins_line);
      sqlite3_int64 id = sqlite3_last_insert_rowid(ix->db->h); /* before flush_para inserts a row of its own */
      if (flags & LINE_BLOCK) {
        flush_para(ix, first, &para);
        first = id;
      }
      if (para.len) sb_putc(&para, '\n');
      sb_puts(&para, l->text);
    }
    ix->st.pages++;
  }
  flush_para(ix, first, &para);
  sb_free(&para);

  sqlite3_stmt *u = ix->upd_file;
  sqlite3_bind_int64(u, 1, j->size);
  sqlite3_bind_int64(u, 2, j->mtime);
  sqlite3_bind_int(u, 3, j->outcome);
  bind_text(u, 4, d->error);
  sqlite3_bind_int(u, 5, d->npages);
  sqlite3_bind_int(u, 6, ix->dopts.pages);
  sqlite3_bind_int64(u, 7, d->nchars);
  sqlite3_bind_double(u, 8, d->quality);
  sqlite3_bind_double(u, 9, d->garbled);
  for (int k = 0; k < DOC_META_N; k++) bind_text(u, 10 + k, d->meta[k]);
  if (j->ocr_pages) {
    sqlite3_bind_int(u, 10 + DOC_META_N, j->ocr_pages);
    sqlite3_bind_text(u, 11 + DOC_META_N, ix->ocr_lang, -1, SQLITE_TRANSIENT);
  }
  sqlite3_bind_int64(u, 12 + DOC_META_N, j->file);
  run(u);

  ix->st.chars += d->nchars;
  if (d->error) ix->st.failed++;
  else ix->st.ok++;
  if (j->ocr_pages) ix->st.ocr++;

  if (++ix->since_commit >= 200 || now_s() - ix->last_commit > 1.0) txn_commit(ix);
}

static void dispatch(struct indexer *ix);

static void retry_closed(uv_handle_t *h) {
  free(h);
}

static void finish(struct indexer *ix) {
  if (ix->finished) return;
  ix->finished = 1;
  if (ix->retry) {
    uv_close((uv_handle_t *)ix->retry, retry_closed);
    ix->retry = NULL;
  }
  txn_commit(ix);
  ix->st.elapsed = now_s() - ix->st.started;
  ix->st.last_path = ix->st.last_error = NULL;
  if (ix->done) ix->done(ix, &ix->st, ix->ud);
}

static int usable(const struct doc_info *d) {
  return doc_text_usable(d->nchars, d->garbled, d->quality);
}

/* OCR's reading o of the file's first pages (read of them), in place of
 * the file's own text when OCR's is usable or the file's is not. */
static void ocr_choose(struct job *j, struct doc_info o, int read) {
  struct doc_info *d = &j->info;
  doc_measure(&o);
  if (read && (usable(&o) || !usable(d))) {
    for (int k = 0; k < DOC_META_N; k++) o.meta[k] = d->meta[k], d->meta[k] = NULL;
    doc_info_free(d);
    *d = o;
    j->ocr_pages = read;
    j->outcome = usable(d) ? OUT_READ_OCR : OUT_OCR_NO_HELP;
  } else {
    doc_info_free(&o);
    if (!usable(d)) j->outcome = read ? OUT_OCR_NO_HELP : OUT_OCR_UNAVAILABLE;
  }
}

/* tesseract on the worker. */
static void ocr_step(struct indexer *ix, struct job *j) {
  struct doc_info *d = &j->info;
  int n = d->n < ix->o.ocr_pages ? d->n : ix->o.ocr_pages;
  struct doc_info o = {.npages = d->npages, .n = n};
  o.pages = xcalloc((size_t)(n ? n : 1), sizeof *o.pages);
  int read = 0;
  for (int i = 0; i < n; i++) {
    struct doc_page *pg = &o.pages[i];
    pg->no = d->pages[i].no;
    pg->w = d->pages[i].w;
    pg->h = d->pages[i].h;
    char *err = NULL;
    if (ocr_page(ix->tesseract, j->path, pg->no - 1, ix->ocr_lang, pg, &err) == 0) read++;
    else free(err); /* a page OCR could not read is a page without text */
  }
  ocr_choose(j, o, read);
}

/* On a worker: extraction judges the text, and OCR reads the pages that
 * need it; one reading is stored. */
static void work_cb(uv_work_t *req) {
  struct job *j = req->data;
  struct indexer *ix = j->ix;
  doc_extract(j->path, j->format, &ix->dopts, &j->info);
  if (j->info.error) {
    j->outcome = OUT_UNREADABLE;
    return;
  }
  /* a text file's text is the text: nothing to judge, nothing to OCR */
  if (!strcasecmp(j->format, "txt") || !strcasecmp(j->format, "md")) {
    j->outcome = OUT_READ;
    return;
  }
  int good = usable(&j->info);
  j->outcome = good ? OUT_READ : OUT_OCR_UNAVAILABLE;
  int want = ix->o.ocr == OCR_ALWAYS || (ix->o.ocr == OCR_AUTO && !good);
  if (!want || ix->o.ocr_pages <= 0) return;
  if (ix->o.ocr_lua && registry_lua(REG_READER)) j->ocr_lua = 1; /* asked from the loop: after_cb */
  else if (ix->tesseract) ocr_step(ix, j);
}

static void after_cb(uv_work_t *req, int status);

/* The Lua reader's answer, on the indexer's loop: the job goes on as if
 * its worker had read the pages. */
static void lua_read(struct ocr_req *r) {
  struct job *j = r->ud;
  struct doc_info o = {.npages = j->info.npages, .n = r->n};
  o.pages = xcalloc((size_t)(r->n ? r->n : 1), sizeof *o.pages);
  int read = 0;
  for (int i = 0; i < r->n; i++) {
    o.pages[i] = r->out[i];
    memset(&r->out[i], 0, sizeof r->out[i]);
    o.pages[i].no = r->pages[i] + 1;
    if (r->ok[i]) {
      doc_page_finish(&o.pages[i]);
      read++;
    }
  }
  if (r->err) log_warn("OCR (utils.ocr): %s", r->err);
  ocr_choose(j, o, read);
  ocr_req_free(r);
  j->ocr_lua = 0;
  after_cb(&j->req, 0);
}

static void ask_lua(struct indexer *ix, struct job *j) {
  struct doc_info *d = &j->info;
  int n = d->n < ix->o.ocr_pages ? d->n : ix->o.ocr_pages;
  struct ocr_req *r = xcalloc(1, sizeof *r);
  r->path = xstrdup(j->path);
  r->lang = xstrdup(ix->ocr_lang);
  r->n = n;
  r->pages = xcalloc((size_t)n + 1, sizeof *r->pages);
  r->w = xcalloc((size_t)n + 1, sizeof *r->w);
  r->h = xcalloc((size_t)n + 1, sizeof *r->h);
  r->out = xcalloc((size_t)n + 1, sizeof *r->out);
  r->ok = xcalloc((size_t)n + 1, sizeof *r->ok);
  for (int i = 0; i < n; i++) {
    r->pages[i] = d->pages[i].no - 1;
    r->w[i] = r->out[i].w = d->pages[i].w;
    r->h[i] = r->out[i].h = d->pages[i].h;
  }
  r->done = lua_read;
  r->ud = j;
  ix->o.ocr_lua(r);
}

static void stored(struct indexer *ix, struct job *j) {
  ix->inflight--;
  store(ix, j);
  ix->st.done++;
  ix->st.elapsed = now_s() - ix->st.started;
  ix->st.last_path = j->path;
  ix->st.last_error = j->info.error;
  if (ix->progress) ix->progress(ix, &ix->st, ix->ud);
  ix->st.last_path = ix->st.last_error = NULL; /* they are the job's, freed next */
  job_free(j);
}

static void retry_cb(uv_timer_t *h) {
  struct indexer *ix = h->data;
  int n = ix->nheld;
  if (txn_begin(ix)) {
    if (!ix->cancelled) return; /* still held: try again on the next tick */
    /* leaving: what was not stored is extracted again on the next run */
    for (int i = 0; i < n; i++) job_free(ix->held[i]);
    ix->inflight -= n;
  } else {
    for (int i = 0; i < n; i++) stored(ix, ix->held[i]);
  }
  ix->nheld = 0;
  uv_timer_stop(h);
  dispatch(ix);
}

static void hold(struct indexer *ix, struct job *j) {
  if (ix->nheld == ix->capheld) {
    ix->capheld = ix->capheld ? ix->capheld * 2 : 8;
    ix->held = xrealloc(ix->held, (size_t)ix->capheld * sizeof *ix->held);
  }
  ix->held[ix->nheld++] = j;
  if (!ix->retry) {
    ix->retry = xmalloc(sizeof *ix->retry);
    uv_timer_init(ix->loop, ix->retry);
    ix->retry->data = ix;
  }
  if (!uv_is_active((uv_handle_t *)ix->retry)) uv_timer_start(ix->retry, retry_cb, 50, 50);
}

static void after_cb(uv_work_t *req, int status) {
  struct job *j = req->data;
  struct indexer *ix = j->ix;
  if (status == 0 && j->ocr_lua) {
    ask_lua(ix, j); /* goes on in lua_read */
    return;
  }
  if (status != 0) {
    ix->inflight--;
    job_free(j);
  } else if (ix->nheld || txn_begin(ix)) {
    hold(ix, j); /* in order, after those already waiting */
    return;
  } else {
    stored(ix, j);
  }
  dispatch(ix);
}

static void dispatch(struct indexer *ix) {
  while (!ix->cancelled && ix->inflight < ix->o.inflight && ix->next < ix->njobs) {
    struct job *j = ix->jobs[ix->next];
    ix->jobs[ix->next++] = NULL;
    j->req.data = j;
    if (uv_queue_work(ix->loop, &j->req, work_cb, after_cb) != 0) {
      job_free(j);
      continue;
    }
    ix->inflight++;
  }
  if (ix->inflight == 0 && (ix->cancelled || ix->next >= ix->njobs)) finish(ix);
}

/* Runs once from the loop when there was nothing to extract, so `done` is
 * never called from inside indexer_start. */
static void idle_closed(uv_handle_t *h) {
  free(h);
}

static void idle_finish(uv_idle_t *h) {
  struct indexer *ix = h->data;
  uv_idle_stop(h);
  uv_close((uv_handle_t *)h, idle_closed);
  dispatch(ix);
}

static int plan(struct indexer *ix, char **err) {
  sbuf sql = SBUF_INIT;
  sb_puts(&sql, "SELECT f.id, f.path, f.format, f.size, f.mtime, f.outcome, f.req_pages, f.ocr_pages FROM files f");
  if (ix->o.only)
    sb_printf(&sql, " WHERE f.book IN (SELECT b.id FROM books b WHERE %s)", ix->o.only->where);
  sb_puts(&sql, " ORDER BY f.id");
  sqlite3_stmt *st;
  int rc = db_prepare(ix->db, sql.s, &st, err);
  sb_free(&sql);
  if (rc) return rc;
  if (ix->o.only)
    for (int i = 0; i < ix->o.only->nparams; i++)
      sqlite3_bind_text(st, i + 1, ix->o.only->params[i], -1, SQLITE_TRANSIENT);

  int cap = 0, nmissing = 0, capm = 0;
  sqlite3_int64 *missing = NULL;
  while (sqlite3_step(st) == SQLITE_ROW) {
    ix->st.files++;
    sqlite3_int64 id = sqlite3_column_int64(st, 0);
    const char *path = (const char *)sqlite3_column_text(st, 1);
    struct stat sb;
    if (!path || stat(path, &sb) != 0) {
      if (nmissing == capm) {
        capm = capm ? capm * 2 : 16;
        missing = xrealloc(missing, (size_t)capm * sizeof *missing);
      }
      missing[nmissing++] = id;
      continue;
    }
    int outcome = sqlite3_column_int(st, 5);
    int same = sqlite3_column_type(st, 3) != SQLITE_NULL &&
               sqlite3_column_int64(st, 3) == (sqlite3_int64)sb.st_size &&
               sqlite3_column_int64(st, 4) == (sqlite3_int64)sb.st_mtime;
    int enough = sqlite3_column_int(st, 6) >= ix->o.pages;
    /* OCR on now, for a file that wanted it, or for every file */
    int ocr_now = ix->tesseract && ((outcome == OUT_OCR_UNAVAILABLE && ix->o.ocr != OCR_NEVER) ||
                                    (outcome == OUT_READ && ix->o.ocr == OCR_ALWAYS && !sqlite3_column_int(st, 7)));
    if (outcome == OUT_NO_TEXT) { ix->st.current++; continue; } /* marked so: nothing retries it */
    if (!ix->o.force && same) {
      if (outcome == OUT_UNREADABLE && !ix->o.retry) { ix->st.current++; continue; }
      if (outcome != OUT_PENDING && outcome != OUT_MISSING && outcome != OUT_UNREADABLE && enough && !ocr_now) {
        ix->st.current++;
        continue;
      }
    }
    struct job *j = xcalloc(1, sizeof *j);
    j->ix = ix;
    j->file = id;
    j->path = xstrdup(path);
    const char *format = (const char *)sqlite3_column_text(st, 2);
    j->format = xstrdup(format ? format : "");
    j->size = (long long)sb.st_size;
    j->mtime = (long long)sb.st_mtime;
    if (ix->njobs == cap) {
      cap = cap ? cap * 2 : 256;
      ix->jobs = xrealloc(ix->jobs, (size_t)cap * sizeof *ix->jobs);
    }
    ix->jobs[ix->njobs++] = j;
  }
  sqlite3_finalize(st);

  if (nmissing) {
    sqlite3_stmt *m;
    /* marked on a later run if the write lock is taken now */
    if (txn_begin(ix) == 0 && db_prepare(ix->db, "UPDATE files SET outcome = 6 WHERE id = ?", &m, err) == 0) {
      for (int i = 0; i < nmissing; i++) {
        sqlite3_bind_int64(m, 1, missing[i]);
        run(m);
      }
      txn_commit(ix);
      sqlite3_finalize(m);
    }
  }
  free(missing);
  ix->st.missing = nmissing;
  ix->st.queued = ix->njobs;
  return 0;
}

struct indexer *indexer_start(uv_loop_t *loop, struct db *db, const struct index_opts *o,
                              indexer_cb *progress, indexer_cb *done, void *ud, char **err) {
  struct indexer *ix = xcalloc(1, sizeof *ix);
  ix->loop = loop;
  ix->db = db;
  ix->o = *o;
  if (ix->o.inflight < 1) ix->o.inflight = 4;
  ix->dopts = (struct doc_opts){o->pages, 0};
  ix->ocr_lang = xstrdup(o->ocr_lang && o->ocr_lang[0] ? o->ocr_lang : "eng");
  ix->o.ocr_lang = ix->ocr_lang;
  if (o->ocr != OCR_NEVER) ix->tesseract = ocr_find();
  ix->progress = progress;
  ix->done = done;
  ix->ud = ud;
  ix->st.started = now_s();

  if (db_prepare(db,
                 "DELETE FROM paragraphs_fts WHERE rowid IN (SELECT id FROM lines WHERE file = ? AND flags & 32)",
                 &ix->del_paras, err) ||
      db_prepare(db, "DELETE FROM lines WHERE file = ?", &ix->del_lines, err) ||
      db_prepare(db, "INSERT INTO paragraphs_fts(rowid, text) VALUES(?, ?)", &ix->ins_para, err) ||
      db_prepare(db,
                 "INSERT INTO lines(file, page, n, text, size, flags, x0, y0, x1, y1, math)"
                 " VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                 &ix->ins_line, err) ||
      db_prepare(db,
                 "UPDATE files SET size = ?, mtime = ?, outcome = ?, error = ?, npages = ?,"
                 " req_pages = ?, nchars = ?, quality = ?, garbled = ?,"
                 " emb_title = ?, emb_author = ?, emb_subject = ?, emb_keywords = ?,"
                 " emb_creator = ?, emb_producer = ?, ocr_pages = ?, ocr_lang = ?,"
                 " indexed_at = strftime('%s', 'now') WHERE id = ?",
                 &ix->upd_file, err) ||
      plan(ix, err)) {
    indexer_free(ix);
    return NULL;
  }

  if (ix->njobs == 0) {
    uv_idle_t *idle = xmalloc(sizeof *idle);
    uv_idle_init(loop, idle);
    idle->data = ix;
    uv_idle_start(idle, idle_finish);
  } else {
    dispatch(ix);
  }
  return ix;
}

void indexer_cancel(struct indexer *ix) {
  ix->cancelled = 1;
}

void indexer_free(struct indexer *ix) {
  if (!ix) return;
  txn_commit(ix);
  for (int i = ix->next; i < ix->njobs; i++)
    if (ix->jobs[i]) job_free(ix->jobs[i]);
  free(ix->jobs);
  for (int i = 0; i < ix->nheld; i++) job_free(ix->held[i]);
  free(ix->held);
  sqlite3_finalize(ix->del_paras);
  sqlite3_finalize(ix->del_lines);
  sqlite3_finalize(ix->ins_para);
  sqlite3_finalize(ix->ins_line);
  sqlite3_finalize(ix->upd_file);
  free(ix->ocr_lang);
  free(ix->tesseract);
  free(ix);
}
