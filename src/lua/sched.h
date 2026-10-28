#ifndef LULIBRE_SCHED_H
#define LULIBRE_SCHED_H

/* Lua tasks: coroutines that take turns where they wait.
 *
 * Tasks share one Lua state and one thread (the Lua thread when the
 * interface is up; see lua/bridge.h). A task runs until it waits (a
 * subprocess, a timer, text extraction, a picker) or calls lulibre.yield():
 * between two of those, nothing else runs on its thread, so its steps there
 * are one step for the others. A task that computes for long holds the
 * others up, not the interface. Everything here belongs to the Lua thread,
 * except where a function says otherwise. */

struct lua_State;
struct app;
struct task;

void sched_init(struct app *app);
void sched_free(struct app *app);

/* The function and its nargs arguments are on top of L's stack; they are
 * moved into a new task, which starts on the next loop iteration. Returns
 * the task id. */
int sched_spawn(struct lua_State *L, int nargs, const char *name);

/* The same, but the task runs its first slice now, until it first waits,
 * yields or ends: what it does before that is done when this returns. */
int sched_spawn_now(struct lua_State *L, int nargs, const char *name);

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

/* The task that is running, for another thread: how long it has run
 * without waiting (0: none runs), and its id. Any thread. */
long long sched_running_ms(void);
int sched_running_id(void);
/* Any thread: task id is to stop if it is running when the hook next
 * looks (sched_signalled). */
void sched_stop_running(int id);
/* From a signal handler on the Lua thread: a hook on the running task,
 * which says it runs too long (once a run) and stops it when it is
 * cancelled or named by sched_stop_running (lua/bridge.c sends the
 * signal). */
void sched_signalled(void);

/* Push an array of {id=, name=, state=} onto L. */
void sched_push_tasks(struct lua_State *L);
int sched_current_id(struct lua_State *L); /* 0 outside a task */

#endif
