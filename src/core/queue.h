#ifndef LULIBRE_QUEUE_H
#define LULIBRE_QUEUE_H

/* The message queue (design 1): how the threads that own state reach each
 * other.
 *
 * Each loop has an inbox. A message is a function and the value it carries;
 * the message owns the value. Any thread posts, and the message runs later
 * on the inbox's loop, never in the poster's stack, also when poster and
 * inbox share one loop (headless). A message runs exactly once: on its
 * loop, or by queue_drain when the loop is gone for good. While an inbox is
 * closed (the Lua thread during :restart-scripts) its messages wait and run
 * when it opens again. */

#include <uv.h>

struct app;

enum loop_id { LOOP_UI, LOOP_LUA, LOOPS };

typedef void queue_fn(struct app *app, void *arg);

/* Before the loop runs: the inbox takes a handle on loop. Messages waiting
 * from before run on the loop's next turn. */
void queue_open(struct app *app, enum loop_id id, uv_loop_t *loop);
/* On the inbox's loop: closes the handle; later messages wait. */
void queue_close(enum loop_id id);
/* Runs the messages waiting, on the calling thread: the loop is gone and
 * will not come back. */
void queue_drain(enum loop_id id);

void queue_post(enum loop_id to, queue_fn *fn, void *arg);

#endif
