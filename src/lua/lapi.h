#ifndef LULIBRE_LAPI_H
#define LULIBRE_LAPI_H

/* Internal interface between the Lua API translation units.
 *
 * Each l_*.c exposes one l_<module>_open(L), called with the `lulibre` table
 * on top of the stack; it adds its functions and leaves the stack as it
 * found it. The whole API is the one flat `lulibre` table:
 *
 *   l_setman.c setman (its own library)           settings
 *   l_evman.c  evman (its own library)            callbacks on shared events
 *   l_job.c    spawn sleep yield tasks cancel     tasks
 *   l_db.c     ids books book count sql authors tags store reload
 *              source stage_refresh
 *   l_doc.c    text lines files extract           indexed text, extraction
 *   l_proc.c   system                             subprocesses
 *   l_hash.c   md5                                content hashes, cached
 *   l_copy.c   copy_db check_db                   copies of SQLite databases, their integrity
 *   l_index.c  index                              run the indexer, and wait
 *   l_theme.c  theme                              colours
 *   l_match.c  fold fuzzy                         matching
 *   l_ui.c     notify command map exec current selection mark filter
 *              pick input show                    the interface
 *   bridge.c   (no Lua functions)                 the Lua thread and its calls
 *                                                 to and from the interface
 *   l_uv.c     lulibre.uv, require "luv"          libuv on the host loop
 *   l_panel.c  lulibre.panel                      tables a script fills and steers
 */

#include "core/setdefs.h"

struct lua_State;
struct app;
struct task;

/* What a Lua thread's extra space points at. The main thread and coroutines
 * made by scripts share the main context (task == NULL); every scheduler
 * task has its own. */
struct lctx {
  struct app *app;
  struct task *task;
};

struct app *lapi_app(struct lua_State *L);
/* The index connection and the event loop that belong to the thread Lua
 * runs on. Opens the index on first use. */
struct db *lapi_db(struct lua_State *L);
struct uv_loop_s *lapi_loop(struct lua_State *L);

/* Show a message from Lua land: the message line and log in the interface,
 * stderr otherwise. level: 0 info, 1 error. From either thread. */
void lapi_report(struct app *app, int level, const char *msg);
/* The set of tasks changed; lets the interface redraw its indicator. */
void lapi_tasks_changed(struct app *app);

/* Load and start a script as a task. args are passed as `...`. Returns the
 * task id, or 0 with *err set. On the thread that owns the Lua state. */
int lapi_run_file(struct app *app, const char *path, int argc, char **argv, char **err);
/* Find a script by name in the script directories; malloc'd path or NULL. */
char *lapi_find_script(struct app *app, const char *name);
/* Directories searched for scripts, in order; NULL-terminated, malloc'd. */
char **lapi_script_dirs(struct app *app);
/* Run a registered Lua function (by registry ref) as a task with one string
 * argument. From the interface thread; the task starts on the Lua thread. */
void lapi_spawn_ref(struct app *app, int ref, const char *name, const char *arg);

/* setman (l_setman.c). The copy of the settings in the registry: filled
 * when the lua_State is made, and kept current by l_setman_changed, a
 * message the store's watcher posts with setman_change_new. */
int luaopen_setman(struct lua_State *L);
void l_setman_fill(struct lua_State *L, const struct settings *st);
struct setman_change *setman_change_new(const struct settings *st, int def);
void l_setman_changed(struct app *app, void *arg);
/* evman (l_evman.c); l_evman_close drops Lua's callbacks before the
 * lua_State goes. */
int luaopen_evman(struct lua_State *L);
void l_evman_close(struct app *app);

/* package.path and cpath, from the runtime, the configuration directory
 * and mod_tree (lstate.c). */
void lstate_paths(struct lua_State *L);

/* lulibre.reading (l_reading.c), a module written in C, preloaded. */
int luaopen_lulibre_reading(struct lua_State *L);
int luaopen_lulibre_similar(struct lua_State *L);

/* A value from the copy, for C on the Lua thread; the string is malloc'd. */
long long lapi_setting_int(struct lua_State *L, enum setting_id id);
char *lapi_setting_str(struct lua_State *L, enum setting_id id);

void l_job_open(struct lua_State *L);
void l_db_open(struct lua_State *L);
void l_doc_open(struct lua_State *L);
void l_proc_open(struct lua_State *L);
void l_hash_open(struct lua_State *L);
void l_copy_open(struct lua_State *L);
void l_index_open(struct lua_State *L);
void l_theme_open(struct lua_State *L);
void l_match_open(struct lua_State *L);
void l_learn_open(struct lua_State *L);
void l_ui_open(struct lua_State *L);
void l_uv_open(struct lua_State *L);
void l_uv_preload(struct lua_State *L); /* after the lulibre table exists */
void l_panel_open(struct lua_State *L);

#endif
