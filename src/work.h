#ifndef LULIBRE_WORK_H
#define LULIBRE_WORK_H

/* The background thread: calibre's library (library/library.h) and the
 * indexer (index/indexer.h) live here, with a connection to the index of
 * their own, so the interface never waits on their SQLite writes, their
 * processes or calibre. It runs no Lua: a reader or a store of Lua's is
 * asked on the Lua thread by message (core/registry.h).
 *
 * Everything reaches it by message (LOOP_WORK, core/queue.h), and what it
 * answers goes back the same way. Without the interface there is one
 * thread, and LOOP_WORK is the main loop. */

#include "core/setdefs.h"

struct app;
struct index_stats;

/* Before the loops run: threaded gives the work its own loop and, once
 * work_start runs, its own thread. */
void work_init(struct app *app, int threaded);
/* With the index open (app_open_db): its connection, the settings' copy,
 * and the library. The main thread, before work_start. */
void work_open(struct app *app);
/* The thread starts; from here on the library and the indexer are its. */
void work_start(struct app *app);
/* Lets what is running end (calibredb runs, a reading of calibre's
 * records), cancels the indexer, closes the library and joins the thread.
 * Changes still queued stay in the journal for the next start. */
void work_stop(struct app *app);

/* The settings as the background thread sees them: a copy the store keeps
 * current by message, as the lua_State's is (design 2). Its thread only. */
const char *work_str(enum setting_id id);
long long work_int(enum setting_id id);
int work_bool(enum setting_id id);
/* The main thread: the store's watcher, for setting def. */
void work_setting_changed(struct app *app, int def);

/* An index run. One runs at a time: a request made while one runs is told
 * when that one ends, and its options are not used. done runs on the
 * background thread, once, with the run's numbers (or err, when it did not
 * start); it posts what it has to say to whoever asked. The interface hears
 * of every run (tui_indexing, tui.h). */
typedef void work_index_done(const struct index_stats *st, const char *err, void *ud);
/* The main thread: the options in effect, with pages (when > 0), force,
 * retry and filter (when not NULL) over them. Returns -1 with *err when the
 * filter does not compile. */
int work_index(struct app *app, int pages, int force, int retry, const char *filter, work_index_done *done, void *ud,
               char **err);

#endif
