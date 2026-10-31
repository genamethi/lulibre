#ifndef LULIBRE_EVENTS_H
#define LULIBRE_EVENTS_H

/* Shared events (design 1, 5, 24, 29, 36, 42).
 *
 * Any thread posts an event; the event travels by the queue to the threads
 * with callbacks for its kind and is dispatched there. Each kind has one
 * payload, built only when some callback exists for the kind. A view's own events (keys, rows) are not shared
 * events: the task that owns the view pulls them (design 33). */

#include "core/queue.h"

enum event_kind {
  EV_CURSOR,          /* the book under the cursor */
  EV_MARKS,           /* marks or the selection */
  EV_RECORDS_CHANGED, /* lulibre's writes and changes found in calibre */
  EV_HOLDER,          /* the library's holder (library.h) */
  EV_SOURCE_ARRIVED,  /* an online answer for a book */
  EV_PROPOSED,        /* a book's proposals made anew */
  EV_KINDS
};

/* The payload, by kind:
 *   EV_CURSOR           book
 *   EV_MARKS            selection
 *   EV_RECORDS_CHANGED  ids; fields, those lulibre changed (none when the
 *                       change was made outside lulibre)
 *   EV_HOLDER           holder
 *   EV_SOURCE_ARRIVED   book, service
 *   EV_PROPOSED         book */
struct event {
  enum event_kind kind;
  long long *ids;
  int nids;
  char **fields;
  int nfields;
  long long book;
  long long *selection;
  int nselection;
  int holder;          /* enum library_holder */
  const char *service; /* static: a service's name */
};

/* Whether some callback exists for kind, on any loop. A poster builds the
 * payload only when one does. Any thread. */
int events_wanted(enum event_kind kind);

/* Posts ev, taking it: each loop with callbacks for the kind gets it by the
 * queue, and the last to dispatch frees it. Any thread. */
void events_post(struct event *ev);
/* Frees an event and the parts it holds (service is static). */
void events_free(struct event *ev);

/* A callback on loop `on`, called there; register and unregister on that
 * loop's thread, or before it runs. The indexer listens for
 * EV_RECORDS_CHANGED. Unregistering during a dispatch is allowed. */
typedef void event_fn(const struct event *ev, void *ud);
void events_listen(enum loop_id on, enum event_kind kind, event_fn *fn, void *ud);
void events_unlisten(enum loop_id on, enum event_kind kind, event_fn *fn, void *ud);
/* Every callback fn on loop `on`, of any kind: Lua's, when the lua_State is
 * torn down (design 7). */
void events_unlisten_all(enum loop_id on, event_fn *fn);

#endif
