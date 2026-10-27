#ifndef LULIBRE_EVENTS_H
#define LULIBRE_EVENTS_H

/* Shared events (design 1, 5, 24, 29, 36, 42).
 *
 * Any thread posts an event; the event travels by the queue to the threads
 * with callbacks for its kind and is dispatched there. A payload is built
 * only when some callback wants the kind, and only with the parts the
 * callbacks asked for. A view's own events (keys, rows) are not shared
 * events: the task that owns the view pulls them (design 33). */

#include "core/queue.h"

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
/* In events_want: some callback, even one that asks for no part. */
#define EP_LISTENED (1u << 31)

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

/* The parts some callback wants for kind, over every loop; 0 when no
 * callback exists. A poster builds only these parts, and posts nothing when
 * there are none. Any thread. */
unsigned events_want(enum event_kind kind);

/* Posts ev, taking it: each loop with callbacks for the kind gets it by the
 * queue, and the last to dispatch frees it. ev->parts says what was built.
 * Any thread. */
void events_post(struct event *ev);
/* Frees an event and the parts it holds (service is static). */
void events_free(struct event *ev);

/* A callback on loop `on`, called there; register and unregister on that
 * loop's thread, or before it runs. The indexer: EV_RECORDS_CHANGED with
 * EP_FILES. Unregistering during a dispatch is allowed. */
typedef void event_fn(const struct event *ev, void *ud);
void events_listen(enum loop_id on, enum event_kind kind, unsigned parts, event_fn *fn, void *ud);
void events_unlisten(enum loop_id on, enum event_kind kind, event_fn *fn, void *ud);
/* Every callback fn on loop `on`, of any kind: Lua's, when the lua_State is
 * torn down (design 7). */
void events_unlisten_all(enum loop_id on, event_fn *fn);

#endif
