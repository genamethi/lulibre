#ifndef LULIBRE_LIBRARY_H
#define LULIBRE_LIBRARY_H

/* The library (design 24-32): one resource, owned by C on the interface
 * thread, so editing works with no Lua.
 *
 * The holder (the content server, calibre's program, or none) is kept
 * current by observation and posted as EV_HOLDER. Every calibre operation
 * is a message to the library with a need: any holder, or the library
 * closed. An operation runs once the need is met, by the route the holder
 * allows; the journal records every operation through one lifecycle. A
 * write that applies posts EV_RECORDS_CHANGED, after embedding and opf
 * files where the operation asks for them. */

struct app;

enum library_holder { HOLDER_NONE, HOLDER_SERVER, HOLDER_PROGRAM };

enum op_need { NEED_ANY, NEED_CLOSED };

enum op_state { OP_QUEUED, OP_RUNNING, OP_APPLIED, OP_FAILED, OP_UNDONE };

enum change_op { CHANGE_SET, CHANGE_ADD, CHANGE_REMOVE };

struct change {
  long long book;
  const char *field; /* a calibre field, or "#name" for a field of lulibre's own */
  const char *value;
  enum change_op op;
  /* where the change came from (design 27); NULL and 0 for a hand edit */
  long long proposal;
  const char *proposed; /* the value as proposed */
  const char *source;   /* the grammar or service that supplied the field */
};

struct operation {
  const char *label;
  enum op_need need;
  const char *store; /* a REG_STORE entry: "calibre", "staging", "own" */
  const struct change *changes;
  int nchanges;
  const char *const *argv; /* a structural calibredb command, in place of changes */
  /* taken from the settings when the operation is made (design 4) */
  int embed;
  int jobs;
};

struct library;

typedef void library_done(long long batch, enum op_state state, const char *err, void *ud);

/* All return 0 on success; on failure *err is a malloc'd message. */
struct library *library_open(struct app *app, char **err);
void library_close(struct library *lib);

enum library_holder library_holder(const struct library *lib);

/* Queues op (copied) as one batch of the journal; done fires on the
 * interface loop when the batch has applied or failed. */
int library_submit(struct library *lib, const struct operation *op, library_done *done, void *ud, char **err);

/* Puts a batch's old values back, as an operation of its own. */
int library_undo(struct library *lib, long long batch, library_done *done, void *ud, char **err);

#endif
