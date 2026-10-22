#ifndef LULIBRE_SCHED_H
#define LULIBRE_SCHED_H

/* Lua tasks: coroutines the loop runs a few milliseconds at a time.
 *
 * Tasks share one Lua state and one thread (the Lua thread when the
 * interface is up; see lua/bridge.h), and take turns. Functions that wait (a
 * subprocess, a timer, text extraction, a picker) park the task and hand
 * control back to the loop until their result arrives. And a task that just
 * computes is interrupted by an instruction-count hook once its time slice
 * is spent, then continued on a later loop iteration, so one busy script
 * does not starve the others. Everything here belongs to the Lua thread,
 * except sched_live and sched_failed, which any thread may call. */

struct lua_State;
struct app;
struct task;

void sched_init(struct app *app);
void sched_free(struct app *app);

/* The function and its nargs arguments are on top of L's stack; they are
 * moved into a new task, which starts on the next loop iteration. Returns
 * the task id. */
int sched_spawn(struct lua_State *L, int nargs, const char *name);

/* ---- for C functions that wait ----
 *
 *   struct task *t = sched_begin_wait(L);   // raises unless L is a task
 *   ... start the operation, remembering t ...
 *   return lua_yield(L, 0);
 *
 * and when the operation completes, on the loop thread:
 *
 *   lua_State *co = sched_end_wait(t);
 *   if (co) { push results onto co; sched_wake(t, nresults); }
 *
 * sched_end_wait returns NULL when the task was cancelled meanwhile. */
struct task *sched_begin_wait(struct lua_State *L);
void sched_abort_wait(struct task *t); /* the operation could not start */
struct lua_State *sched_end_wait(struct task *t);
void sched_wake(struct task *t, int nargs);
/* The same for a job on a worker thread (uv_queue_work): counted, so that
 * the loop is not stopped while one runs (bridge_stop waits for them). */
struct task *sched_begin_job(struct lua_State *L);
struct lua_State *sched_end_job(struct task *t);
int sched_jobs(const struct app *app); /* jobs begun and not yet ended */
/* Raise a Lua error unless L is a task that may wait. */
void sched_require_task(struct lua_State *L);

/* How to hurry a waiting task along when it is cancelled (kill the process,
 * stop the timer). The operation must still complete through
 * sched_end_wait. Cleared when the wait ends. */
typedef void sched_cancel_fn(void *ud);
void sched_on_cancel(struct task *t, sched_cancel_fn *fn, void *ud);

int sched_cancel(struct app *app, int id); /* 0 if there is no such task */
void sched_cancel_all(struct app *app);
int sched_live(const struct app *app);   /* tasks not yet finished */
int sched_failed(const struct app *app); /* tasks that ended in an error */
/* An error outside any task (a luv callback's) counts as a failure too:
 * `lulibre run` then exits 1. */
void sched_note_failure(struct app *app);

/* Push an array of {id=, name=, state=} onto L. */
void sched_push_tasks(struct lua_State *L);
int sched_current_id(struct lua_State *L); /* 0 outside a task */

#endif
