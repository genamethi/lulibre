#ifndef LULIBRE_EVENTS_H
#define LULIBRE_EVENTS_H

/* Shared events (design 1, 5, 24, 29, 36, 42).
 *
 * Any thread posts an event; the event travels by the queue to the threads
 * with callbacks for its kind and is dispatched there. A payload is built
 * only when some callback wants the kind, and only with the parts the
 * callbacks asked for. A view's own events (keys, rows) are not shared
 * events: the task that owns the view pulls them (design 33). */

#include <stdatomic.h>

struct app;

enum event_kind {
  EV_CURSOR,          /* the book under the cursor */
  EV_MARKS,           /* marks or the selection */
  EV_RECORDS_CHANGED, /* lulibre's writes and changes found in calibre */
  EV_HOLDER,          /* the library's holder (library.h) */
  EV_SOURCE_ARRIVED,  /* an online answer for a book */
  EV_TASKS,           /* tasks started or ended */
  EV_KINDS
};

/* The parts of a payload, as bits. */
enum event_part {
  EP_IDS = 1 << 0,
  EP_FIELDS = 1 << 1,
  EP_FILES = 1 << 2,  /* new or changed files: the indexer's trigger */
  EP_BOOK = 1 << 3,
  EP_SELECTION = 1 << 4,
  EP_HOLDER = 1 << 5,
  EP_SERVICE = 1 << 6,
};

struct event {
  enum event_kind kind;
  unsigned parts; /* the parts built */
  long long *ids;
  int nids;
  char **fields;
  int nfields;
  long long *files;
  int nfiles;
  long long book;
  long long *selection;
  int nselection;
  int holder;          /* enum library_holder */
  const char *service; /* static: a service's name */
};

/* The parts wanted for each kind: the union over every callback, 0 when no
 * callback exists. Atomic, so a posting thread reads the bits without a
 * lock; the threads that register callbacks keep the bits current. */
extern _Atomic unsigned events_wanted[EV_KINDS];

/* Posts ev, built with the parts events_wanted names; the receivers free
 * the event after dispatch. Posting a kind nobody wants is a no-op that
 * frees ev. */
void events_post(struct app *app, struct event *ev);

/* A C callback, on the thread that registers it (the indexer on
 * EV_RECORDS_CHANGED with EP_FILES). */
typedef void event_fn(const struct event *ev, void *ud);
void events_listen(struct app *app, enum event_kind kind, unsigned parts, event_fn *fn, void *ud);
void events_unlisten(struct app *app, enum event_kind kind, event_fn *fn, void *ud);

/* Lua's callbacks, all dropped at once when the lua_State is torn down
 * (design 7). */
void events_drop_lua(struct app *app);

#endif
