#include "core/events.h"

#include <stdatomic.h>
#include <stdlib.h>

#include "core/util.h"

struct listener {
  enum event_kind kind;
  event_fn *fn; /* NULL: removed during a dispatch, dropped after it */
  void *ud;
};

/* A loop's callbacks belong to that loop. Other threads see only `want`. */
static struct loop_listeners {
  struct listener *l;
  int n, cap;
  int dispatching;
  atomic_int listened[EV_KINDS]; /* callbacks per kind */
} loops[LOOPS];

/* An event on its way to several loops: freed by the last. */
struct shared {
  struct event *ev;
  atomic_int refs;
};

struct delivery {
  enum loop_id loop;
  struct shared *sh;
};

int events_wanted(enum event_kind kind) {
  for (int i = 0; i < LOOPS; i++)
    if (atomic_load(&loops[i].listened[kind])) return 1;
  return 0;
}

static void recount(struct loop_listeners *ll, enum event_kind kind) {
  int n = 0;
  for (int i = 0; i < ll->n; i++)
    if (ll->l[i].fn && ll->l[i].kind == kind) n++;
  atomic_store(&ll->listened[kind], n);
}

void events_free(struct event *ev) {
  if (!ev) return;
  free(ev->ids);
  for (int i = 0; i < ev->nfields; i++) free(ev->fields[i]);
  free(ev->fields);
  free(ev->files);
  free(ev->selection);
  free(ev);
}

/* Drops the entries removed while dispatching. */
static void compact(struct loop_listeners *ll) {
  int w = 0;
  for (int i = 0; i < ll->n; i++)
    if (ll->l[i].fn) ll->l[w++] = ll->l[i];
  ll->n = w;
}

static void deliver(struct app *app, void *arg) {
  struct delivery *d = arg;
  struct loop_listeners *ll = &loops[d->loop];
  struct event *ev = d->sh->ev;
  ll->dispatching++;
  /* a callback added during the dispatch waits for the next event */
  for (int i = 0, n = ll->n; i < n; i++) {
    struct listener *l = &ll->l[i];
    if (l->fn && l->kind == ev->kind) l->fn(ev, l->ud);
  }
  if (--ll->dispatching == 0) compact(ll);
  if (atomic_fetch_sub(&d->sh->refs, 1) == 1) {
    events_free(ev);
    free(d->sh);
  }
  free(d);
}

void events_post(struct event *ev) {
  int to[LOOPS], n = 0;
  for (int i = 0; i < LOOPS; i++)
    if (atomic_load(&loops[i].listened[ev->kind])) to[n++] = i;
  if (!n) {
    events_free(ev);
    return;
  }
  struct shared *sh = xcalloc(1, sizeof *sh);
  sh->ev = ev;
  atomic_init(&sh->refs, n);
  for (int i = 0; i < n; i++) {
    struct delivery *d = xcalloc(1, sizeof *d);
    d->loop = to[i];
    d->sh = sh;
    queue_post(to[i], deliver, d);
  }
}

void events_listen(enum loop_id on, enum event_kind kind, event_fn *fn, void *ud) {
  struct loop_listeners *ll = &loops[on];
  if (ll->n == ll->cap) {
    ll->cap = ll->cap ? ll->cap * 2 : 8;
    ll->l = xrealloc(ll->l, ll->cap * sizeof *ll->l);
  }
  ll->l[ll->n++] = (struct listener){kind, fn, ud};
  recount(ll, kind);
}

static void remove_where(struct loop_listeners *ll, int (*match)(const struct listener *, const void *),
                         const void *key) {
  unsigned touched = 0;
  for (int i = 0; i < ll->n; i++) {
    if (!ll->l[i].fn || !match(&ll->l[i], key)) continue;
    touched |= 1u << ll->l[i].kind;
    ll->l[i].fn = NULL;
  }
  if (!ll->dispatching) compact(ll);
  for (int k = 0; k < EV_KINDS; k++)
    if (touched & 1u << k) recount(ll, k);
}

struct one {
  enum event_kind kind;
  event_fn *fn;
  void *ud;
};

static int is_one(const struct listener *l, const void *key) {
  const struct one *o = key;
  return l->kind == o->kind && l->fn == o->fn && l->ud == o->ud;
}

void events_unlisten(enum loop_id on, enum event_kind kind, event_fn *fn, void *ud) {
  remove_where(&loops[on], is_one, &(struct one){kind, fn, ud});
}

static int has_fn(const struct listener *l, const void *key) {
  return l->fn == *(event_fn *const *)key;
}

void events_unlisten_all(enum loop_id on, event_fn *fn) {
  remove_where(&loops[on], has_fn, &fn);
}
