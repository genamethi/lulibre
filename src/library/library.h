#ifndef LULIBRE_LIBRARY_H
#define LULIBRE_LIBRARY_H

/* The library (design 24-31): one resource, owned by C on the main thread,
 * so editing works with no Lua.
 *
 * The holder (calibre's content server, calibre's program, or none) is kept
 * current by observation, calibre's lock among the machine's sockets, and
 * posted as EV_HOLDER. Every calibre operation is a message to the library
 * with a need: any holder, or the library closed. It runs once the need is
 * met, by the route the holder allows: through the server, or straight to
 * the library folder; while calibre's program has the library, it waits.
 * No caller asks for the route. The journal records every operation
 * through one lifecycle: queued, running, applied or failed, undone. An
 * operation that applies reads calibre's records again (library_reload),
 * after embedding the records in the books' files when the operation asks,
 * and is done once they are read. */

struct app;

/* HOLDER_OTHER: calibre's lock is held by a program with another library
 * open; calibre's lock is one for all of a user's libraries. */
enum library_holder { HOLDER_NONE, HOLDER_SERVER, HOLDER_PROGRAM, HOLDER_OTHER };

enum op_need { NEED_ANY, NEED_CLOSED };

enum op_state { OP_QUEUED, OP_RUNNING, OP_APPLIED, OP_FAILED, OP_UNDONE };

enum change_op { CHANGE_SET, CHANGE_ADD, CHANGE_REMOVE };

struct change {
  long long book;
  const char *field; /* a calibre field (library/fields.h), or "#name" for one of lulibre's own */
  const char *value; /* NULL: the field keeps its value */
  enum change_op op;
  /* where the change came from (design 27); 0 and NULL for a hand edit. A
   * change with a proposal is journaled even when it changes nothing: it
   * is a review decision. */
  long long proposal;
  const char *proposed; /* the value as proposed */
  const char *source;   /* the grammar or service that supplied it */
};

/* The settings an operation runs by, taken by whoever made it, as it was
 * made (design 4): a change made after setman.set("embed", true) embeds. */
struct op_settings {
  const char *server, *user, *password_file;
  int embed, jobs;
};

struct operation {
  const struct op_settings *set; /* NULL: the background thread's copy (work.h) */
  const char *label;
  enum op_need need;
  const struct change *changes;
  int nchanges;
  const char *const *argv; /* a structural calibredb command, NULL-terminated, in place of changes */
  long long batch; /* a batch of the journal to join, else 0 for a new one */
  char **output;   /* a command's: what it printed goes here (malloc'd) before done fires */
};

struct library;
struct db;

/* batch: the journal's batch, 0 when nothing was to change; state:
 * OP_APPLIED, OP_FAILED (err says why, for the first book that failed). */
typedef void library_done(long long batch, enum op_state state, const char *err, void *ud);

/* The library lives on the background thread (work.h): every call here
 * but library_holder is that thread's, and every callback runs there. */
struct library *library_open(struct app *app);
void library_close(struct library *lib);
/* Nothing running: no calibredb run, no reading of the records. */
int library_idle(const struct library *lib);
/* Queues again what the journal holds queued; by those that run the loop
 * (the interface, lulibre run), not by a command that only reads. */
void library_resume(struct library *lib);

/* Any thread. */
enum library_holder library_holder(const struct library *lib);

/* Queues op as one batch of the journal; op is copied, and the settings it
 * runs by (the route's, embedding, processes at once) are taken now. done
 * fires on the main loop when the batch has applied or failed, at once
 * when nothing was to change. Returns -1 with *err for a change that
 * cannot be made (an unknown field, a malformed value). */
int library_submit(struct library *lib, const struct operation *op, library_done *done, void *ud, char **err);

/* Reads calibre's records into the index again, on a worker: when
 * metadata.db has changed, or always with force; force 2 reads every book,
 * not only those calibre changed (db_mirror, db/db.h). done runs on the main loop
 * with rc as db_mirror's (db/db.h). The books found changed, and those of
 * the operations it was read for with the fields they changed, are posted
 * as EV_RECORDS_CHANGED. Readings asked for while one runs share the next. */
typedef void library_reloaded(int rc, const char *err, void *ud);
void library_reload(struct library *lib, int force, library_reloaded *done, void *ud);

/* Puts a batch's old values back, as an operation of its own. */
int library_undo(struct library *lib, long long batch, const struct op_settings *set, library_done *done, void *ud,
                 char **err);

/* After db_mirror copied calibre's records (it returned above 0): what changed
 * that lulibre didn't change goes into the journal as a batch labelled
 * "outside", field by field, and whole books added or removed. On db's thread. */
void library_log_outside(struct db *db);

/* What puts a command's batch back: a calibredb command, its arguments in
 * argv (NULL-terminated). library_undo runs it in place of anything else
 * in the batch. */
int library_command_undo(struct library *lib, long long batch, const char *const *argv, char **err);

/* A row of the journal for a change lulibre made some way of its own, which
 * only the code that made it can put back, in batch or a new one: the batch. */
long long library_note(struct library *lib, long long batch, long long book, const char *field, const char *old,
                       const char *new, const char *label);

/* The batch's applied rows are undone. */
void library_mark_undone(struct library *lib, long long batch);

/* Takes a batch out of the queue if it hasn't begun. Returns 0, or -1 with *err. */
int library_cancel(struct library *lib, long long batch, char **err);

/* Takes a staged file (book, below 0) out of the sync folder, to the path
 * held, as a change of the journal that undo puts back, its record too, in
 * batch, or a new one. Returns the batch, or 0 with *err. */
long long library_drop(struct library *lib, long long book, const char *held, long long batch, char **err);

/* One book's changes for the calibre store Lua has put in calibredb's place
 * (core/registry.h): fields[i] gets values[i], in the form library/fields.h
 * gives. answer() runs on the main loop with err NULL when they were made. */
struct store_req {
  long long book;
  int n;
  char **fields, **values;
  void (*answer)(struct store_req *req, const char *err);
  void *ud;
};
/* Hands a request to store.calibre (lua/l_library.c); any thread. */
void lapi_store_write(struct store_req *req);

/* What went wrong with a calibredb run, in words: the one place its error
 * text is read. status: its exit status; out: what it printed. malloc'd. */
char *library_failure(int status, const char *out, const char *server);

/* prefs.c: calibre's configuration folder, as calibre finds it; the library
 * calibre opened last, when its settings name one that is there (NULL
 * otherwise). malloc'd. */
char *calibre_config_dir(void);
char *calibre_library_path(void);
/* calibre's content server, running: its process (0 for none; one with
 * library, a real path, among its arguments first), its address and
 * whether it asks for a password. *url malloc'd. */
int calibre_server_find(const char *library, char **url, int *auth);

#endif
