#ifndef LULIBRE_BRIDGE_H
#define LULIBRE_BRIDGE_H

/* The two threads of the interactive program.
 *
 * With the interface up, Lua does not run on the interface's thread. The
 * interface thread owns the terminal, the windows, the list, the settings
 * and its own event loop. The Lua thread owns the Lua state, the task
 * scheduler, a second event loop (the one luv and the timers, subprocesses
 * and worker jobs of the `lulibre` API use) and its own database connection.
 * They talk by messages (core/queue.h); neither waits for the other
 * (design 34), so nothing a script does can hold up a keystroke or a redraw.
 *
 * Without the interface (`lulibre run`, or before the interface has started)
 * there is one thread and one loop. */

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

/* Interface thread: stop the Lua thread as bridge_stop does, without
 * waiting for it: once it is gone, then(app) runs on the interface loop,
 * with the old Lua state still there for it to close (:restart-scripts). */
void bridge_restart(struct app *app, void (*then)(struct app *app));
/* Ask the interface to redraw; from either thread. */
void bridge_redraw(struct app *app);

#endif
