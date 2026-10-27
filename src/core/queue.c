#include "core/queue.h"

#include <stdlib.h>

#include "core/util.h"

struct msg {
  queue_fn *fn;
  void *arg;
  struct msg *next;
};

/* The list and the open flag are shared with posting threads, under mu;
 * the handle belongs to the inbox's loop. */
static struct inbox {
  struct app *app;
  uv_mutex_t mu;
  struct msg *head, *tail;
  int open;
  uv_async_t async;
} boxes[LOOPS];

static uv_once_t once = UV_ONCE_INIT;

static void init_once(void) {
  for (int i = 0; i < LOOPS; i++) uv_mutex_init(&boxes[i].mu);
}

static struct msg *take(struct inbox *b) {
  uv_mutex_lock(&b->mu);
  struct msg *m = b->head;
  if (m) {
    b->head = m->next;
    if (!b->head) b->tail = NULL;
  }
  uv_mutex_unlock(&b->mu);
  return m;
}

static void run(struct inbox *b) {
  for (struct msg *m; (m = take(b));) {
    m->fn(b->app, m->arg);
    free(m);
  }
}

static void wake(uv_async_t *h) {
  run(h->data);
}

void queue_open(struct app *app, enum loop_id id, uv_loop_t *loop) {
  uv_once(&once, init_once);
  struct inbox *b = &boxes[id];
  b->app = app;
  uv_async_init(loop, &b->async, wake);
  b->async.data = b;
  uv_mutex_lock(&b->mu);
  b->open = 1;
  int waiting = b->head != NULL;
  uv_mutex_unlock(&b->mu);
  if (waiting) uv_async_send(&b->async);
}

static void closed(uv_handle_t *h) {
}

void queue_close(enum loop_id id) {
  struct inbox *b = &boxes[id];
  uv_mutex_lock(&b->mu);
  b->open = 0;
  uv_mutex_unlock(&b->mu);
  uv_close((uv_handle_t *)&b->async, closed);
}

void queue_drain(enum loop_id id) {
  uv_once(&once, init_once);
  run(&boxes[id]);
}

void queue_post(enum loop_id to, queue_fn *fn, void *arg) {
  uv_once(&once, init_once);
  struct inbox *b = &boxes[to];
  struct msg *m = xcalloc(1, sizeof *m);
  m->fn = fn;
  m->arg = arg;
  uv_mutex_lock(&b->mu);
  if (b->tail) b->tail->next = m;
  else b->head = m;
  b->tail = m;
  /* uv_async_send while mu is held: queue_close cannot close the handle
   * between the check and the send */
  if (b->open) uv_async_send(&b->async);
  uv_mutex_unlock(&b->mu);
}
