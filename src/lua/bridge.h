#ifndef LULIBRE_BRIDGE_H
#define LULIBRE_BRIDGE_H

/* The two threads of the interactive program, and how they talk.
 *
 * With the interface up, Lua does not run on the interface's thread. The
 * interface thread owns the terminal, the windows, the list, the options
 * and its own event loop. The Lua thread owns the Lua state, the task
 * scheduler, a second event loop (the one luv and the timers, subprocesses
 * and worker jobs of the `lulibre` API use) and its own database connection.
 * Nothing a script does can therefore hold up a keystroke or a redraw.
 *
 *   Lua -> interface   bridge_ui / ui_call: run a function on the interface
 *                      thread and wait for it. While it runs, the Lua thread
 *                      is parked, so the function may use the Lua state.
 *   interface -> Lua   bridge_lua: queue a function for the Lua thread and
 *                      return at once. The interface never waits for Lua.
 *
 * Without the interface (`lulibre run`, or before the interface has started)
 * there is one thread and one loop, and every call below simply runs in
 * place. */

#include <lua.h>

struct app;

/* Call once, before the Lua state exists. threaded: give Lua its own loop,
 * to be run by its own thread once bridge_start is called. */
void bridge_init(struct app *app, int threaded);
/* Interface thread: hand the Lua state to a new thread and let it run. */
void bridge_start(struct app *app);
/* Interface thread: cancel every task, serve the Lua thread's last calls,
 * and take the Lua state back. */
void bridge_stop(struct app *app);

/* Run fn(arg) on the interface thread; returns when it has. */
void bridge_ui(struct app *app, void (*fn)(void *), void *arg);
/* Run a Lua C function on the interface thread with L's current arguments.
 * ui_call returns its result count and raises its errors; ui_pcall returns
 * the status instead, leaving the results or the message on the stack. Lua
 * functions that wait must not be called this way: the function cannot
 * yield. */
int ui_call(lua_State *L, lua_CFunction fn);
int ui_pcall(lua_State *L, lua_CFunction fn);

/* Run fn(app, arg) on the Lua thread, later; fn owns arg. */
void bridge_lua(struct app *app, void (*fn)(struct app *, void *), void *arg);

/* Ask the interface to redraw; from either thread. */
void bridge_redraw(struct app *app);

#endif
