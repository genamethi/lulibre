#include "library/library.h"

#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include <dirent.h>
#include <limits.h>
#include <uv.h>

#include "app.h"
#include "core/events.h"
#include "core/log.h"
#include "core/registry.h"
#include "core/util.h"
#include "library/fields.h"
#include "work.h"

/* How often the holder is looked at, in ms. */
enum { PROBE_MS = 2000 };

/* One book's changes in a batch: the fields and their new values, and the
 * journal rows they are. */
struct book_job {
  long long book;
  char **fields, **values;
  long long *rows;
  int n;
};

struct batch {
  long long id;
  enum op_need need;
  char **argv; /* a structural command, or NULL */
  long long argv_row;
  struct book_job *books;
  int nbooks, next, running, done_books;
  int applied;
  char *first_err;
  /* taken from the settings when the batch was made (design 4) */
  char *server, *user, *password_file, *library_dir;
  int embed, jobs;
  long long undoes;
  int embedding;
  library_done *done;
  void *ud;
  struct library *lib;
  struct batch *next_batch;
};

/* One who asked for calibre's records to be read again. */
struct reload_wait {
  library_reloaded *fn;
  void *ud;
  int force;
  struct reload_wait *next;
};

struct library {
  struct app *app;
  uv_timer_t probe;
  _Atomic int holder; /* enum library_holder: changed on the main thread, read from any */
  int ours; /* calibredb runs of ours straight on the folder: they take calibre's lock too */
  unsigned long lock_ino; /* the lock's socket, as last seen */
  int lock_pid;           /* the process that holds it, or 0 */
  struct batch *head, *tail;
  int said_waiting;
  struct reload_wait *waiting; /* for the next reading of the records */
  int reloading, closing, probe_closed;
};

/* ---- the holder ---- */

/* The process of ours that holds the socket with inode ino, or 0. */
static int socket_owner(unsigned long ino) {
  char want[64], path[300], link[128];
  snprintf(want, sizeof want, "socket:[%lu]", ino);
  DIR *proc = opendir("/proc");
  if (!proc) return 0;
  int found = 0;
  for (struct dirent *e; !found && (e = readdir(proc));) {
    if (e->d_name[0] < '1' || e->d_name[0] > '9') continue;
    snprintf(path, sizeof path, "/proc/%s/fd", e->d_name);
    DIR *fds = opendir(path); /* another user's: not readable, passed over */
    if (!fds) continue;
    for (struct dirent *d; (d = readdir(fds));) {
      char fd[600];
      snprintf(fd, sizeof fd, "%s/%s", path, d->d_name);
      ssize_t n = readlink(fd, link, sizeof link - 1);
      if (n <= 0) continue;
      link[n] = '\0';
      if (!strcmp(link, want)) {
        found = atoi(e->d_name);
        break;
      }
    }
    closedir(fds);
  }
  closedir(proc);
  return found;
}

/* Whether process pid has the library in folder dir open: its metadata.db
 * among the process's files, or the folder among its arguments (calibre's
 * server opens a library at its first request). 1 yes, 0 it has others
 * open, -1 nothing tells. */
static int holds(int pid, const char *dir) {
  char path[64], fd[340], link[PATH_MAX];
  char *db = xasprintf("%s/metadata.db", dir);
  int known = 0, yes = 0;
  snprintf(path, sizeof path, "/proc/%d/fd", pid);
  DIR *fds = opendir(path);
  for (struct dirent *d; fds && !yes && (d = readdir(fds));) {
    snprintf(fd, sizeof fd, "%s/%s", path, d->d_name);
    ssize_t n = readlink(fd, link, sizeof link - 1);
    if (n <= 0) continue;
    link[n] = '\0';
    size_t len = (size_t)n;
    if (len < 12 || strcmp(link + len - 12, "/metadata.db")) continue;
    known = 1;
    yes = !strcmp(link, db);
  }
  if (fds) closedir(fds);
  snprintf(path, sizeof path, "/proc/%d/cmdline", pid);
  FILE *f = yes ? NULL : fopen(path, "r");
  if (f) {
    char arg[PATH_MAX];
    int c, n = 0;
    while (!yes && (c = fgetc(f)) != EOF) {
      if (c && n < (int)sizeof arg - 1) {
        arg[n++] = (char)c;
        continue;
      }
      arg[n] = '\0';
      n = 0;
      char *real = arg[0] == '/' ? realpath(arg, NULL) : NULL;
      if (!real) continue;
      char *cal = xasprintf("%s/metadata.db", real);
      if (access(cal, F_OK) == 0) {
        known = 1;
        yes = !strcmp(real, dir);
      }
      free(cal);
      free(real);
    }
    fclose(f);
  }
  free(db);
  return yes ? 1 : known ? 0 : -1;
}

/* calibre's lock is an abstract unix socket per user, not per library:
 * calibre-singleinstance-<uid>-db, held by any calibre program that has a
 * library open (the program, calibre-server, calibredb opening one
 * directly), and ...-GUI by the program. Reading the list of sockets takes
 * nothing; binding the name to test it would take the lock. Since it is
 * one lock for every library, a server with another library open holds
 * this one too, and is no route to it: then changes wait. */
static enum library_holder observe(struct library *lib) {
  FILE *f = fopen("/proc/net/unix", "r");
  if (!f) return HOLDER_NONE;
  char db[96], gui[96], line[512];
  snprintf(db, sizeof db, "@calibre-singleinstance-%u-db", (unsigned)getuid());
  snprintf(gui, sizeof gui, "@calibre-singleinstance-%u-GUI", (unsigned)getuid());
  int has_gui = 0;
  unsigned long db_ino = 0;
  while (fgets(line, sizeof line, f)) {
    char *name = strrchr(line, ' ');
    if (!name) continue;
    name++;
    name[strcspn(name, "\n")] = '\0';
    if (!strcmp(name, db)) sscanf(line, "%*s %*s %*s %*s %*s %*s %lu", &db_ino);
    if (!strcmp(name, gui)) has_gui = 1;
  }
  fclose(f);
  if (has_gui) return HOLDER_PROGRAM;
  if (!db_ino) return HOLDER_NONE;
  if (db_ino != lib->lock_ino) {
    lib->lock_ino = db_ino;
    lib->lock_pid = socket_owner(db_ino);
  }
  if (!lib->lock_pid) return HOLDER_SERVER;
  char *dir = realpath(work_str(S_LIBRARY), NULL);
  int h = dir ? holds(lib->lock_pid, dir) : -1;
  free(dir);
  /* nothing tells: the server, and the library's name in the address
   * keeps a change from another library (server_url) */
  return h == 0 ? HOLDER_OTHER : HOLDER_SERVER;
}

static void pump(struct library *lib);

static void set_holder(struct library *lib, enum library_holder h) {
  if ((int)h == lib->holder) return;
  lib->holder = h;
  static const char *const says[] = {[HOLDER_NONE] = "none", [HOLDER_SERVER] = "calibre's server",
                                     [HOLDER_PROGRAM] = "calibre's program",
                                     [HOLDER_OTHER] = "a calibre program with another library open"};
  (void)says; /* the debug log may be compiled out */
  log_debug("the library's holder: %s", says[h]);
  if (events_wanted(EV_HOLDER)) {
    struct event *ev = xcalloc(1, sizeof *ev);
    ev->kind = EV_HOLDER;
    ev->holder = h;
    events_post(ev);
  }
  pump(lib);
}

static void probe_cb(uv_timer_t *t) {
  struct library *lib = t->data;
  if (!lib->ours) set_holder(lib, observe(lib));
}

enum library_holder library_holder(const struct library *lib) {
  return lib->holder;
}

/* ---- the journal ---- */

static void row_state(struct library *lib, long long row, enum op_state state, const char *err) {
  sqlite3_stmt *st;
  char *e = NULL;
  if (db_prepare(lib->app->wdb, "UPDATE history.journal SET state = ?, error = ? WHERE id = ?", &st, &e)) {
    log_warn("the journal: %s", e);
    free(e);
    return;
  }
  sqlite3_bind_int(st, 1, state);
  if (err) sqlite3_bind_text(st, 2, err, -1, SQLITE_TRANSIENT);
  sqlite3_bind_int64(st, 3, row);
  sqlite3_step(st);
  sqlite3_finalize(st);
}

static long long next_batch(struct db *db) {
  sqlite3_stmt *st;
  char *err = NULL;
  long long n = 1;
  if (db_prepare(db, "SELECT coalesce(max(batch), 0) + 1 FROM history.journal", &st, &err) == 0) {
    if (sqlite3_step(st) == SQLITE_ROW) n = sqlite3_column_int64(st, 0);
    sqlite3_finalize(st);
  } else {
    free(err);
  }
  return n;
}

static long long journal_add(struct db *db, long long batch, const char *label, enum op_need need,
                             const char *store, enum op_state state, long long book, const char *field,
                             const char *old, const char *new, const char *argv, const struct change *c,
                             long long undoes) {
  sqlite3_stmt *st;
  char *err = NULL;
  if (db_prepare(db,
                 "INSERT INTO history.journal(batch, label, need, store, state, ts, book, field, old, new, argv,"
                 " proposal, proposed, source, undoes) VALUES(?, ?, ?, ?, ?, strftime('%s', 'now'), ?, ?, ?, ?, ?,"
                 " ?, ?, ?, ?)",
                 &st, &err)) {
    log_warn("the journal: %s", err);
    free(err);
    return 0;
  }
  sqlite3_bind_int64(st, 1, batch);
  if (label) sqlite3_bind_text(st, 2, label, -1, SQLITE_TRANSIENT);
  sqlite3_bind_int(st, 3, need);
  sqlite3_bind_text(st, 4, store, -1, SQLITE_STATIC);
  sqlite3_bind_int(st, 5, state);
  if (field) {
    sqlite3_bind_int64(st, 6, book);
    sqlite3_bind_text(st, 7, field, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 8, old, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 9, new, -1, SQLITE_TRANSIENT);
  }
  if (argv) sqlite3_bind_text(st, 10, argv, -1, SQLITE_TRANSIENT);
  if (c && c->proposal) sqlite3_bind_int64(st, 11, c->proposal);
  if (c && c->proposed) sqlite3_bind_text(st, 12, c->proposed, -1, SQLITE_TRANSIENT);
  if (c && c->source) sqlite3_bind_text(st, 13, c->source, -1, SQLITE_TRANSIENT);
  if (undoes) sqlite3_bind_int64(st, 14, undoes);
  long long id = sqlite3_step(st) == SQLITE_DONE ? sqlite3_last_insert_rowid(db->h) : 0;
  sqlite3_finalize(st);
  return id;
}

/* ---- stores: lulibre's own fields and the sync folder's files apply at
 * once; calibre's go to calibredb ---- */

static int own_put(struct db *db, long long book, const char *field, const char *value, char **err) {
  sqlite3_stmt *st;
  if (db_prepare(db, "DELETE FROM custom.data WHERE book = ? AND field = ?", &st, err)) return -1;
  sqlite3_bind_int64(st, 1, book);
  sqlite3_bind_text(st, 2, field, -1, SQLITE_STATIC);
  sqlite3_step(st);
  sqlite3_finalize(st);
  if (!*value) return 0;
  if (db_prepare(db, "INSERT INTO custom.data(book, field, ord, value, ts) VALUES(?, ?, ?, ?, strftime('%s', 'now'))",
                 &st, err))
    return -1;
  int ord = 0;
  for (const char *p = value;; ord++) {
    const char *comma = strstr(p, ", ");
    size_t n = comma ? (size_t)(comma - p) : strlen(p);
    sqlite3_bind_int64(st, 1, book);
    sqlite3_bind_text(st, 2, field, -1, SQLITE_STATIC);
    sqlite3_bind_int(st, 3, ord);
    sqlite3_bind_text(st, 4, p, (int)n, SQLITE_TRANSIENT);
    sqlite3_step(st);
    sqlite3_reset(st);
    if (!comma) break;
    p = comma + 2;
  }
  sqlite3_finalize(st);
  return 0;
}

/* A staged file (a book with an id below 0): its row in `staged`. */
static int staged_put(struct db *db, long long book, const char *field, const char *value, char **err) {
  static const struct { const char *field, *col; } cols[] = {
    {"title", "title"},         {"authors", "authors"},     {"tags", "tags"},
    {"series", "series"},       {"series_index", "series_index"}, {"publisher", "publisher"},
    {"pubdate", "pubdate"},     {"identifiers", "idents"},  {"languages", "languages"},
  };
  const char *col = NULL;
  for (size_t i = 0; i < ARRAY_LEN(cols); i++)
    if (!strcmp(cols[i].field, field)) col = cols[i].col;
  if (!col) {
    *err = xasprintf("a staged file has no %s", field);
    return -1;
  }
  char *sql = xasprintf("UPDATE staged SET %s = ? WHERE id = ?", col);
  sqlite3_stmt *st;
  int rc = db_prepare(db, sql, &st, err);
  free(sql);
  if (rc) return -1;
  sqlite3_bind_text(st, 1, value, -1, SQLITE_STATIC);
  sqlite3_bind_int64(st, 2, -book);
  sqlite3_step(st);
  sqlite3_finalize(st);
  return 0;
}

/* ---- calibredb ---- */

char *library_failure(int status, const char *out, const char *server) {
  if (strstr(out, "Another calibre program"))
    return xstrdup("a calibre program has the library open, so it cannot be changed straight in its folder");
  if (strstr(out, "Connection refused") || strstr(out, "Errno 111"))
    return xasprintf("the content server at %s does not answer", server && *server ? server : "(server)");
  /* the last line carries the reason */
  const char *end = out + strlen(out);
  while (end > out && (end[-1] == '\n' || end[-1] == ' ')) end--;
  const char *start = end;
  while (start > out && start[-1] != '\n') start--;
  char *last = xstrndup(start, (size_t)(end - start));
  if (strstr(last, "403") || strcasestr(last, "forbidden")) {
    free(last);
    return xstrdup("the content server refused the change: this account may be read-only");
  }
  if (strstr(last, "401") || strcasestr(last, "unauthori")) {
    free(last);
    return xstrdup("the content server rejected the user name or password");
  }
  if (*last) return last;
  free(last);
  return xasprintf("calibredb exited with status %d", status);
}

struct run {
  uv_process_t proc;
  uv_pipe_t out, err;
  sbuf text; /* what it printed, both streams */
  struct library *lib;
  struct batch *b;
  int book; /* the batch's book job, or RUN_EMBED, RUN_COMMAND */
  int direct;
  int64_t status;
  int closed; /* of the three handles */
  char *lua_err; /* the answer of a store of Lua's: why it failed */
};

enum { RUN_EMBED = -1, RUN_COMMAND = -2 };

/* The run's outcome, into the journal and the batch. */
static void ran(struct run *r) {
  struct library *lib = r->lib;
  struct batch *b = r->b;
  char *err = r->lua_err ? r->lua_err
             : r->status ? library_failure((int)r->status, r->text.s ? r->text.s : "", b->server)
                         : NULL;
  r->lua_err = NULL;
  if (r->book >= 0) {
    struct book_job *j = &b->books[r->book];
    for (int i = 0; i < j->n; i++) row_state(lib, j->rows[i], err ? OP_FAILED : OP_APPLIED, err);
    if (!err) b->applied++;
    b->done_books++;
  } else if (r->book == RUN_COMMAND) {
    row_state(lib, b->argv_row, err ? OP_FAILED : OP_APPLIED, err);
    if (!err) b->applied++;
    b->done_books = b->nbooks;
  } else {
    b->embedding = 2;
  }
  if (err) {
    log_warn("calibredb%s: %s", r->book == RUN_EMBED ? " (embedding the records in the files)" : "", err);
    /* embedding is not the change: the change stands */
    if (r->book != RUN_EMBED && !b->first_err) b->first_err = err;
    else free(err);
  }
}

static void run_closed(uv_handle_t *h) {
  struct run *r = h->data;
  if (++r->closed < 3) return;
  struct library *lib = r->lib;
  if (r->direct) lib->ours--;
  ran(r);
  r->b->running--;
  sb_free(&r->text);
  free(r);
  pump(lib);
}

static void on_exit_cb(uv_process_t *p, int64_t status, int sig) {
  struct run *r = p->data;
  r->status = status ? status : sig ? 128 + sig : 0;
  uv_close((uv_handle_t *)p, run_closed);
}

static void alloc_cb(uv_handle_t *h, size_t size, uv_buf_t *buf) {
  buf->base = xmalloc(size);
  buf->len = size;
}

static void read_cb(uv_stream_t *s, ssize_t n, const uv_buf_t *buf) {
  struct run *r = s->data;
  if (n > 0) sb_putn(&r->text, buf->base, (size_t)n);
  free(buf->base);
  if (n < 0) uv_close((uv_handle_t *)s, run_closed);
}

/* The server's address with the library named in it, as calibre's server
 * names a library: its folder's name, spaces made underscores. Without
 * it calibredb changes the server's first library, which need not be this
 * one. An address that names one already is left as it is. */
static char *server_url(const char *server, const char *dir) {
  if (strchr(server, '#')) return xstrdup(server);
  const char *slash = strrchr(dir, '/');
  char *id = xstrdup(slash ? slash + 1 : dir);
  for (char *p = id; *p; p++)
    if (*p == ' ') *p = '_';
  char *url = xasprintf("%s#%s", server, id);
  free(id);
  return url;
}

/* calibredb, by the route the holder allows, then args. The run counts in
 * b->running until its handles are closed, failed to start or not. */
static void spawn(struct library *lib, struct batch *b, int book, char **args) {
  int direct = lib->holder == HOLDER_NONE;
  const char *argv[96];
  int n = 0;
  argv[n++] = "calibredb";
  argv[n++] = "--with-library";
  char *password = NULL, *url = NULL;
  if (direct) {
    argv[n++] = b->library_dir;
  } else {
    argv[n++] = url = server_url(b->server, b->library_dir);
    if (*b->user) {
      argv[n++] = "--username";
      argv[n++] = b->user;
    }
    if (*b->password_file) {
      /* lulibre never reads the password: calibredb gets the file's name */
      password = xasprintf("<f:%s>", b->password_file);
      argv[n++] = "--password";
      argv[n++] = password;
    }
  }
  for (int i = 0; args[i] && n < (int)ARRAY_LEN(argv) - 1; i++) argv[n++] = args[i];
  argv[n] = NULL;

  struct run *r = xcalloc(1, sizeof *r);
  r->lib = lib;
  r->b = b;
  r->book = book;
  uv_pipe_init(lib->app->wloop, &r->out, 0);
  uv_pipe_init(lib->app->wloop, &r->err, 0);
  r->out.data = r->err.data = r->proc.data = r;
  uv_stdio_container_t io[3] = {
    {.flags = UV_IGNORE},
    {.flags = UV_CREATE_PIPE | UV_WRITABLE_PIPE, .data.stream = (uv_stream_t *)&r->out},
    {.flags = UV_CREATE_PIPE | UV_WRITABLE_PIPE, .data.stream = (uv_stream_t *)&r->err},
  };
  uv_process_options_t o = {
    .exit_cb = on_exit_cb, .file = "calibredb", .args = (char **)argv, .stdio_count = 3, .stdio = io,
  };
  b->running++;
  int rc = uv_spawn(lib->app->wloop, &r->proc, &o);
  free(password);
  free(url);
  if (rc) {
    r->closed = 1; /* no process to close */
    r->status = 127;
    sb_printf(&r->text, "cannot run calibredb: %s", uv_strerror(rc));
    uv_close((uv_handle_t *)&r->out, run_closed);
    uv_close((uv_handle_t *)&r->err, run_closed);
    return;
  }
  r->direct = direct;
  if (direct) lib->ours++;
  log_debug("calibredb %s, %s", args[0], direct ? "straight to the library folder" : "through the content server");
  uv_read_start((uv_stream_t *)&r->out, alloc_cb, read_cb);
  uv_read_start((uv_stream_t *)&r->err, alloc_cb, read_cb);
}

/* A store of Lua's answered for one book. */
static void stored_by_lua(struct store_req *q, const char *err) {
  struct run *r = q->ud;
  if (err) {
    r->status = 1;
    r->lua_err = xstrdup(err);
  }
  free(q);
  struct library *lib = r->lib;
  ran(r);
  r->b->running--;
  free(r);
  pump(lib);
}

/* The book's changes to the store Lua has put in calibredb's place. */
static void start_lua_store(struct library *lib, struct batch *b, int i) {
  struct book_job *j = &b->books[i];
  struct run *r = xcalloc(1, sizeof *r);
  r->lib = lib;
  r->b = b;
  r->book = i;
  struct store_req *q = xcalloc(1, sizeof *q);
  q->book = j->book;
  q->n = j->n;
  q->fields = j->fields;
  q->values = j->values; /* the batch's, which lives until it finishes */
  q->answer = stored_by_lua;
  q->ud = r;
  b->running++;
  lapi_store_write(q);
}

/* calibredb set_metadata ID --field f:v ... */
static void start_book(struct library *lib, struct batch *b, int i) {
  struct book_job *j = &b->books[i];
  if (registry_lua(REG_STORE)) {
    start_lua_store(lib, b, i);
    return;
  }
  char **args = xcalloc((size_t)(2 * j->n + 3), sizeof *args);
  int n = 0;
  args[n++] = xstrdup("set_metadata");
  args[n++] = xasprintf("%lld", j->book);
  for (int k = 0; k < j->n; k++) {
    char *wire = field_wire(j->fields[k], j->values[k]);
    args[n++] = xstrdup("--field");
    args[n++] = xasprintf("%s:%s", j->fields[k], wire);
    free(wire);
  }
  spawn(lib, b, i, args);
  for (int k = 0; k < n; k++) free(args[k]);
  free(args);
}

/* One embed_metadata for the batch's books that applied (design 30). */
static void start_embed(struct library *lib, struct batch *b) {
  char **args = xcalloc((size_t)b->nbooks + 2, sizeof *args);
  int n = 0;
  args[n++] = xstrdup("embed_metadata");
  for (int i = 0; i < b->nbooks; i++) args[n++] = xasprintf("%lld", b->books[i].book);
  b->embedding = 1;
  spawn(lib, b, RUN_EMBED, args);
  for (int k = 0; k < n; k++) free(args[k]);
  free(args);
}

/* After embedding: the books' files have the record's values in them, and
 * a new size and time; the index takes them, so the files are not read
 * again for it. */
static void embedded(struct library *lib, struct batch *b) {
  sqlite3_stmt *sel, *up;
  char *err = NULL;
  struct db *db = lib->app->wdb;
  if (db_prepare(db, "SELECT id, path FROM files WHERE book = ?", &sel, &err) ||
      db_prepare(db,
                 "UPDATE files SET size = ?, mtime = ?, emb_title = (SELECT title FROM books WHERE id = ?),"
                 " emb_author = (SELECT authors FROM books WHERE id = ?) WHERE id = ?",
                 &up, &err)) {
    log_warn("after embedding: %s", err);
    free(err);
    return;
  }
  for (int i = 0; i < b->nbooks; i++) {
    sqlite3_bind_int64(sel, 1, b->books[i].book);
    while (sqlite3_step(sel) == SQLITE_ROW) {
      struct stat s;
      if (stat((const char *)sqlite3_column_text(sel, 1), &s)) continue;
      sqlite3_bind_int64(up, 1, (sqlite3_int64)s.st_size);
      sqlite3_bind_int64(up, 2, (sqlite3_int64)s.st_mtime);
      sqlite3_bind_int64(up, 3, b->books[i].book);
      sqlite3_bind_int64(up, 4, b->books[i].book);
      sqlite3_bind_int64(up, 5, sqlite3_column_int64(sel, 0));
      sqlite3_step(up);
      sqlite3_reset(up);
    }
    sqlite3_reset(sel);
  }
  sqlite3_finalize(sel);
  sqlite3_finalize(up);
}

/* ---- batches ---- */

static void batch_free(struct batch *b) {
  for (int i = 0; i < b->nbooks; i++) {
    struct book_job *j = &b->books[i];
    for (int k = 0; k < j->n; k++) {
      free(j->fields[k]);
      free(j->values[k]);
    }
    free(j->fields);
    free(j->values);
    free(j->rows);
  }
  free(b->books);
  if (b->argv)
    for (char **a = b->argv; *a; a++) free(*a);
  free(b->argv);
  free(b->server);
  free(b->user);
  free(b->password_file);
  free(b->library_dir);
  free(b->first_err);
  free(b);
}

/* ---- reading calibre's records again, on a worker with a connection of
 * its own: a copy takes a third of a second for a couple of thousand books,
 * which the interface does not wait for ---- */

struct reload {
  uv_work_t req;
  struct library *lib;
  char *index, *library_dir;
  int force, rc;
  char *err;
  long long *ids; /* the books the copy found changed */
  int nids;
  struct reload_wait *waits;
};

static void reload_work(uv_work_t *req) {
  struct reload *r = req->data;
  struct db db;
  if (db_open_writer(&db, r->index, &r->err)) {
    r->rc = -1;
    return;
  }
  r->rc = db_mirror(&db, r->library_dir, r->force, &r->err);
  if (r->rc > 0) r->ids = db_mirror_changed(&db, &r->nids);
  db_close(&db);
}

static void batch_reloaded(int rc, const char *err, void *ud);

static void add_id(struct event *ev, long long id) {
  for (int i = 0; i < ev->nids; i++)
    if (ev->ids[i] == id) return;
  ev->ids = xrealloc(ev->ids, (size_t)(ev->nids + 1) * sizeof *ev->ids);
  ev->ids[ev->nids++] = id;
}

static void add_field(struct event *ev, const char *field) {
  for (int i = 0; i < ev->nfields; i++)
    if (!strcmp(ev->fields[i], field)) return;
  ev->fields = xrealloc(ev->fields, (size_t)(ev->nfields + 1) * sizeof *ev->fields);
  ev->fields[ev->nfields++] = xstrdup(field);
}

/* EV_RECORDS_CHANGED for a reading: the books it found changed and the
 * batches' books, with the fields the batches changed; NULL when none. */
static struct event *changed_event(const struct reload *r) {
  if (!events_wanted(EV_RECORDS_CHANGED)) return NULL;
  struct event *ev = xcalloc(1, sizeof *ev);
  ev->kind = EV_RECORDS_CHANGED;
  for (int i = 0; i < r->nids; i++) add_id(ev, r->ids[i]);
  for (struct reload_wait *w = r->waits; w; w = w->next) {
    if (w->fn != batch_reloaded) continue;
    const struct batch *b = w->ud;
    for (int i = 0; i < b->nbooks; i++) {
      add_id(ev, b->books[i].book);
      for (int k = 0; k < b->books[i].n; k++) add_field(ev, b->books[i].fields[k]);
    }
  }
  if (!ev->nids) {
    events_free(ev);
    return NULL;
  }
  return ev;
}

static void reload_start(struct library *lib);

static void reload_after(uv_work_t *req, int status) {
  struct reload *r = req->data;
  struct library *lib = r->lib;
  lib->reloading = 0;
  if (r->rc < 0) log_warn("reading calibre's records again: %s", r->err);
  struct event *ev = lib->closing ? NULL : changed_event(r);
  for (struct reload_wait *w = r->waits, *n; w; w = n) {
    n = w->next;
    if (!lib->closing) w->fn(r->rc, r->err, w->ud);
    else if (w->fn == batch_reloaded) batch_free(w->ud);
    free(w);
  }
  /* after the batches' callbacks: the files they embedded into are known */
  if (ev) events_post(ev);
  free(r->ids);
  free(r->err);
  free(r->index);
  free(r->library_dir);
  free(r);
  if (lib->closing) {
    if (lib->probe_closed) free(lib);
  } else if (lib->waiting) {
    reload_start(lib);
  }
}

static void reload_start(struct library *lib) {
  struct app *app = lib->app;
  struct reload *r = xcalloc(1, sizeof *r);
  r->req.data = r;
  r->lib = lib;
  r->index = xstrdup(app->db.path);
  char *real = realpath(work_str(S_LIBRARY), NULL);
  r->library_dir = real ? real : xstrdup(work_str(S_LIBRARY));
  r->waits = lib->waiting;
  lib->waiting = NULL;
  for (struct reload_wait *w = r->waits; w; w = w->next) r->force |= w->force;
  lib->reloading = 1;
  if (uv_queue_work(app->wloop, &r->req, reload_work, reload_after)) {
    r->rc = -1;
    r->err = xstrdup("no worker to read calibre's records on");
    reload_after(&r->req, 0);
  }
}

void library_reload(struct library *lib, int force, library_reloaded *done, void *ud) {
  struct reload_wait *w = xcalloc(1, sizeof *w), **p = &lib->waiting;
  w->fn = done;
  w->ud = ud;
  w->force = force;
  while (*p) p = &(*p)->next;
  *p = w;
  if (!lib->reloading) reload_start(lib);
}

/* ---- batches, finishing ---- */

static void batch_done(struct batch *b) {
  if (b->done) b->done(b->id, b->first_err ? OP_FAILED : OP_APPLIED, b->first_err, b->ud);
  batch_free(b);
}

/* The records read again after a batch: the files it embedded into take
 * their new size and time, then the batch is done. */
static void batch_reloaded(int rc, const char *err, void *ud) {
  struct batch *b = ud;
  if (rc >= 0 && b->embedding == 2) embedded(b->lib, b);
  batch_done(b);
}

static void finish_batch(struct library *lib, struct batch *b) {
  lib->head = b->next_batch;
  if (!lib->head) lib->tail = NULL;
  if (b->applied && b->undoes) {
    /* the rows of the batch put back whose undoing applied are undone */
    sqlite3_stmt *st;
    char *err = NULL;
    if (db_prepare(lib->app->wdb,
                   "UPDATE history.journal SET state = ?1 WHERE batch = ?2 AND state = ?3 AND EXISTS(SELECT 1 FROM"
                   " history.journal u WHERE u.batch = ?4 AND u.state = ?3 AND u.book = journal.book"
                   " AND u.field = journal.field)",
                   &st, &err) == 0) {
      sqlite3_bind_int(st, 1, OP_UNDONE);
      sqlite3_bind_int64(st, 2, b->undoes);
      sqlite3_bind_int(st, 3, OP_APPLIED);
      sqlite3_bind_int64(st, 4, b->id);
      sqlite3_step(st);
      sqlite3_finalize(st);
    } else {
      free(err);
    }
  }
  if (b->applied && !b->argv) library_reload(lib, 1, batch_reloaded, b);
  else batch_done(b);
}

static int allowed(const struct library *lib, const struct batch *b) {
  /* a store of Lua's takes its own route: the holder is its to mind */
  if (b->need == NEED_ANY && !b->argv && registry_lua(REG_STORE)) return 1;
  if (lib->holder == HOLDER_PROGRAM || lib->holder == HOLDER_OTHER) return 0;
  if (b->need == NEED_CLOSED) return lib->holder == HOLDER_NONE;
  return lib->holder == HOLDER_NONE || *b->server;
}

static void pump(struct library *lib) {
  struct batch *b;
  while ((b = lib->head)) {
    if (b->running) return;
    if (b->done_books == b->nbooks && b->next >= b->nbooks) {
      if (b->embed && b->applied && !b->embedding && !b->argv) {
        if (!allowed(lib, b)) return;
        start_embed(lib, b);
        if (b->running) return;
      }
      finish_batch(lib, b);
      continue;
    }
    if (!allowed(lib, b)) {
      if (!lib->said_waiting) {
        lib->said_waiting = 1;
        log_info(lib->holder == HOLDER_PROGRAM ? "changes wait while calibre's program has the library open"
                 : lib->holder == HOLDER_OTHER ? "changes wait while a calibre program has another library open"
                                               : "changes wait: calibre's server has the library open, and the setting "
                                                 "server does not say where it is");
      }
      return;
    }
    lib->said_waiting = 0;
    if (b->argv) {
      b->next = b->nbooks;
      row_state(lib, b->argv_row, OP_RUNNING, NULL);
      spawn(lib, b, RUN_COMMAND, b->argv);
      if (b->running) return;
      continue;
    }
    /* straight on the folder, one process at a time: they would contend for
     * calibre's database */
    int jobs = lib->holder == HOLDER_NONE ? 1 : b->jobs;
    while (b->next < b->nbooks && b->running < jobs) {
      struct book_job *j = &b->books[b->next];
      for (int i = 0; i < j->n; i++) row_state(lib, j->rows[i], OP_RUNNING, NULL);
      start_book(lib, b, b->next++);
    }
    if (b->running) return;
  }
}

static struct batch *batch_new(struct library *lib, enum op_need need, const struct op_settings *set,
                               library_done *done, void *ud) {
  struct op_settings own = {work_str(S_SERVER), work_str(S_USER), work_str(S_PASSWORD_FILE), work_bool(S_EMBED),
                            (int)work_int(S_WRITE_JOBS)};
  if (!set) set = &own;
  struct batch *b = xcalloc(1, sizeof *b);
  b->need = need;
  b->server = xstrdup(set->server);
  b->user = xstrdup(set->user);
  b->password_file = xstrdup(set->password_file);
  char *real = realpath(work_str(S_LIBRARY), NULL);
  b->library_dir = real ? real : xstrdup(work_str(S_LIBRARY));
  b->embed = set->embed;
  b->jobs = set->jobs;
  if (b->jobs < 1) b->jobs = 1;
  b->done = done;
  b->ud = ud;
  b->lib = lib;
  return b;
}

static void enqueue(struct library *lib, struct batch *b) {
  if (lib->tail) lib->tail->next_batch = b;
  else lib->head = b;
  lib->tail = b;
  pump(lib);
}

static struct book_job *job_for(struct batch *b, long long book) {
  for (int i = 0; i < b->nbooks; i++)
    if (b->books[i].book == book) return &b->books[i];
  b->books = xrealloc(b->books, (size_t)(b->nbooks + 1) * sizeof *b->books);
  struct book_job *j = &b->books[b->nbooks++];
  memset(j, 0, sizeof *j);
  j->book = book;
  return j;
}

static void job_add(struct book_job *j, const char *field, const char *value, long long row) {
  j->fields = xrealloc(j->fields, (size_t)(j->n + 1) * sizeof *j->fields);
  j->values = xrealloc(j->values, (size_t)(j->n + 1) * sizeof *j->values);
  j->rows = xrealloc(j->rows, (size_t)(j->n + 1) * sizeof *j->rows);
  j->fields[j->n] = xstrdup(field);
  j->values[j->n] = xstrdup(value);
  j->rows[j->n++] = row;
}

/* The changes, resolved against the current values: what calibre is to get
 * goes in b's book jobs; lulibre's own fields and staged files are written
 * now. Returns -1 with *err when a change cannot be made, before the
 * journal holds anything of it. */
static int take_changes(struct library *lib, struct batch *b, const char *label, const struct change *changes,
                        int n, long long undoes, char **err) {
  struct db *db = lib->app->wdb;
  char **olds = xcalloc((size_t)n + 1, sizeof *olds), **news = xcalloc((size_t)n + 1, sizeof *news);
  /* several changes to one field of one book ("+c, -a") apply one after
   * the other: each starts from the one before, which it replaces */
  char *gone = xcalloc((size_t)n + 1, 1);
  int rc = 0;
  for (int i = 0; i < n && !rc; i++) {
    const struct change *c = &changes[i];
    int before = -1;
    for (int j = i - 1; j >= 0 && before < 0; j--)
      if (!gone[j] && changes[j].book == c->book && !strcmp(changes[j].field, c->field)) before = j;
    if (before >= 0) {
      olds[i] = xstrdup(olds[before]);
      news[i] = c->value ? field_resolve(c->field, c->op, news[before], c->value, err) : xstrdup(news[before]);
      gone[before] = 1;
      if (!news[i]) rc = -1;
      continue;
    }
    if (c->book < 0 && field_is_own(c->field)) {
      *err = xasprintf("a staged file has no field %s", c->field);
      rc = -1;
      break;
    }
    olds[i] = c->book < 0 ? xstrdup("") : field_current(db, c->book, c->field, err);
    if (!olds[i]) {
      rc = -1;
      break;
    }
    /* no value: the field keeps its value (a proposal rejected) */
    news[i] = c->value ? field_resolve(c->field, c->op, olds[i], c->value, err) : xstrdup(olds[i]);
    if (!news[i]) rc = -1;
  }
  if (!rc) {
    b->id = next_batch(db);
    int rows = 0;
    for (int i = 0; i < n; i++) {
      const struct change *c = &changes[i];
      if (gone[i]) continue;
      if (!strcmp(olds[i], news[i])) {
        /* no change; a decision on a proposal is kept all the same, for
         * the parse's track record (design 21) */
        if (c->proposal) {
          journal_add(db, b->id, label, b->need, "review", OP_APPLIED, c->book, c->field, olds[i], news[i], NULL, c,
                      undoes);
          rows++;
        }
        continue;
      }
      rows++;
      const char *store = c->book < 0 ? "staging" : field_is_own(c->field) ? "own" : "calibre";
      if (!strcmp(store, "calibre")) {
        long long row = journal_add(db, b->id, label, b->need, store, OP_QUEUED, c->book, c->field, olds[i], news[i],
                                    NULL, c, undoes);
        job_add(job_for(b, c->book), c->field, news[i], row);
        continue;
      }
      char *e = NULL;
      int bad = c->book < 0 ? staged_put(db, c->book, c->field, news[i], &e) : own_put(db, c->book, c->field, news[i], &e);
      journal_add(db, b->id, label, b->need, store, bad ? OP_FAILED : OP_APPLIED, c->book, c->field, olds[i], news[i],
                  NULL, c, undoes);
      if (bad && !b->first_err) b->first_err = e;
      else free(e);
      if (!bad) b->applied++;
    }
    if (!rows) b->id = 0; /* nothing was to change: no batch */
  }
  for (int i = 0; i < n; i++) {
    free(olds[i]);
    free(news[i]);
  }
  free(olds);
  free(news);
  free(gone);
  return rc;
}

int library_submit(struct library *lib, const struct operation *op, library_done *done, void *ud, char **err) {
  struct batch *b = batch_new(lib, op->need, op->set, done, ud);
  struct db *db = lib->app->wdb;
  if (op->argv) {
    int n = 0;
    while (op->argv[n]) n++;
    b->argv = xcalloc((size_t)n + 1, sizeof *b->argv);
    sbuf joined = SBUF_INIT;
    for (int i = 0; i < n; i++) {
      b->argv[i] = xstrdup(op->argv[i]);
      if (i) sb_putc(&joined, '\t');
      sb_puts(&joined, op->argv[i]);
    }
    b->id = next_batch(db);
    b->argv_row = journal_add(db, b->id, op->label, op->need, "calibre", OP_QUEUED, 0, NULL, NULL, NULL, joined.s, NULL, 0);
    sb_free(&joined);
    b->nbooks = 1; /* the command counts as the batch's one job */
    enqueue(lib, b);
    return 0;
  }
  if (take_changes(lib, b, op->label, op->changes, op->nchanges, 0, err)) {
    batch_free(b);
    return -1;
  }
  enqueue(lib, b);
  return 0;
}

int library_undo(struct library *lib, long long batch, const struct op_settings *set, library_done *done, void *ud,
                 char **err) {
  struct db *db = lib->app->wdb;
  sqlite3_stmt *st;
  if (db_prepare(db,
                 "SELECT book, field, old, label FROM history.journal WHERE batch = ? AND state = ? AND field IS NOT NULL"
                 " ORDER BY id DESC",
                 &st, err))
    return -1;
  sqlite3_bind_int64(st, 1, batch);
  sqlite3_bind_int(st, 2, OP_APPLIED);
  struct change *changes = NULL;
  int n = 0;
  char *label = NULL;
  while (sqlite3_step(st) == SQLITE_ROW) {
    changes = xrealloc(changes, (size_t)(n + 1) * sizeof *changes);
    changes[n++] = (struct change){
      .book = sqlite3_column_int64(st, 0),
      .field = xstrdup((const char *)sqlite3_column_text(st, 1)),
      .value = xstrdup(sqlite3_column_text(st, 2) ? (const char *)sqlite3_column_text(st, 2) : ""),
      .op = CHANGE_SET,
    };
    if (!label && sqlite3_column_text(st, 3)) label = xasprintf("undo: %s", sqlite3_column_text(st, 3));
  }
  sqlite3_finalize(st);
  int rc = 0;
  if (!n) {
    *err = xasprintf("batch %lld has nothing applied to undo", batch);
    rc = -1;
  } else {
    struct batch *b = batch_new(lib, NEED_ANY, set, done, ud);
    b->undoes = batch;
    if (take_changes(lib, b, label ? label : "undo", changes, n, batch, err)) {
      batch_free(b);
      rc = -1;
    } else {
      enqueue(lib, b);
    }
  }
  for (int i = 0; i < n; i++) {
    free((char *)changes[i].field);
    free((char *)changes[i].value);
  }
  free(changes);
  free(label);
  return rc;
}

/* ---- the resource ---- */

/* What the journal holds queued is queued again (design 26: the journal
 * is the queue); what was running when lulibre stopped may or may not have
 * reached calibre, and is marked failed. */
void library_resume(struct library *lib) {
  struct db *db = lib->app->wdb;
  char *err = NULL;
  sqlite3_stmt *st;
  if (db_prepare(db, "UPDATE history.journal SET state = ?, error = 'interrupted: lulibre stopped while it ran'"
                     " WHERE state = ?", &st, &err) == 0) {
    sqlite3_bind_int(st, 1, OP_FAILED);
    sqlite3_bind_int(st, 2, OP_RUNNING);
    sqlite3_step(st);
    sqlite3_finalize(st);
  } else {
    free(err);
    err = NULL;
  }
  if (db_prepare(db,
                 "SELECT id, batch, need, book, field, new, argv FROM history.journal"
                 " WHERE state = ? AND store = 'calibre' ORDER BY batch, id",
                 &st, &err)) {
    log_warn("the journal: %s", err);
    free(err);
    return;
  }
  sqlite3_bind_int(st, 1, OP_QUEUED);
  struct batch *b = NULL;
  int n = 0;
  while (sqlite3_step(st) == SQLITE_ROW) {
    long long id = sqlite3_column_int64(st, 0), batch = sqlite3_column_int64(st, 1);
    if (!b || b->id != batch) {
      if (b) enqueue(lib, b);
      b = batch_new(lib, (enum op_need)sqlite3_column_int(st, 2), NULL, NULL, NULL);
      b->id = batch;
      n++;
    }
    const char *argv = (const char *)sqlite3_column_text(st, 6);
    if (argv) {
      int k = 0;
      b->argv = xcalloc(64, sizeof *b->argv);
      char *copy = xstrdup(argv), *save = NULL;
      for (char *a = strtok_r(copy, "\t", &save); a && k < 63; a = strtok_r(NULL, "\t", &save)) b->argv[k++] = xstrdup(a);
      free(copy);
      b->argv_row = id;
      b->nbooks = 1;
    } else {
      job_add(job_for(b, sqlite3_column_int64(st, 3)), (const char *)sqlite3_column_text(st, 4),
              sqlite3_column_text(st, 5) ? (const char *)sqlite3_column_text(st, 5) : "", id);
    }
  }
  sqlite3_finalize(st);
  if (b) enqueue(lib, b);
  if (n) log_info("%d change%s from before wait%s in the journal", n, n == 1 ? "" : "s", n == 1 ? "s" : "");
}

struct library *library_open(struct app *app) {
  struct library *lib = xcalloc(1, sizeof *lib);
  lib->app = app;
  lib->holder = observe(lib);
  uv_timer_init(app->wloop, &lib->probe);
  lib->probe.data = lib;
  uv_timer_start(&lib->probe, probe_cb, PROBE_MS, PROBE_MS);
  uv_unref((uv_handle_t *)&lib->probe); /* looking does not keep the loop running */
  return lib;
}

static void probe_closed(uv_handle_t *h) {
  struct library *lib = h->data;
  lib->probe_closed = 1;
  if (!lib->reloading) free(lib); /* else when the reading ends */
}

int library_idle(const struct library *lib) {
  return !lib->reloading && (!lib->head || !lib->head->running);
}

void library_close(struct library *lib) {
  if (!lib) return;
  for (struct reload_wait *w = lib->waiting, *n; w; w = n) {
    n = w->next;
    if (w->fn == batch_reloaded) batch_free(w->ud);
    free(w);
  }
  lib->waiting = NULL;
  while (lib->head) {
    struct batch *b = lib->head;
    lib->head = b->next_batch;
    batch_free(b); /* what has not run stays queued in the journal */
  }
  lib->closing = 1;
  uv_timer_stop(&lib->probe);
  uv_close((uv_handle_t *)&lib->probe, probe_closed);
}
