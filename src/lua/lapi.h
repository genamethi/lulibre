#ifndef LULIBRE_LAPI_H
#define LULIBRE_LAPI_H

/* Internal interface between the Lua API translation units.
 *
 * What scripts reach, and from where (lstate.c builds it):
 *
 *   globals     lulib     (version, build, headless) l_proc.c exec,
 *                         l_hash.c md5, l_index.c index
 *               taskman   l_job.c: spawn sleep yield tasks cancel
 *               uiman     l_ui.c, l_panel.c panel, l_theme.c theme
 *               setman    l_setman.c        evman  l_evman.c
 *               keymap, cmd                 (l_ui.c's callers)
 *               lulibre   l_db.c sql store: until wit and net take them
 *   preloaded   bookman   l_db.c, l_doc.c files
 *               store     l_library.c, l_db.c reload
 *               txt       l_txt.c           curl    l_curl.c
 *               expr.core l_match.c         lsqlite3 (vendor/)
 *               mesr      l_mesr.c, l_match.c fuzzy
 *               lulibre.ocr.core, lulibre.stores.core
 *   luv         l_uv.c: luv on the Lua loop
 *
 * Each l_<name>_open(L) adds its functions to the table on top of the
 * stack and leaves the stack as it found it; each luaopen_* returns its
 * module. */

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
/* The set of tasks changed: the list goes to the interface, for :tasks and
 * its indicator. */
struct sched_task_list;
void lapi_tasks_changed(struct app *app, struct sched_task_list *list); /* takes list */

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
/* Releases a function's reference in the main lua_State, from either
 * thread: by message to the Lua thread. */
void lapi_unref(int ref);
/* A new lua_State is coming (:restart-scripts): references into the old
 * one, still on their way in messages, are dropped where they land. */
void lapi_new_generation(void);
int luaopen_keymap(struct lua_State *L);
int luaopen_cmd(struct lua_State *L);

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

/* txt (l_txt.c), a module written in C, preloaded. */
int luaopen_txt(struct lua_State *L);
/* expr.core (l_match.c): fold, lower and upper, for expr (lua/expr.lua). */
int luaopen_expr_core(struct lua_State *L);
int luaopen_mesr(struct lua_State *L);
int l_mesr_fuzzy(struct lua_State *L); /* l_match.c */
int luaopen_store(struct lua_State *L);
int luaopen_bookman(struct lua_State *L);
int l_db_reload(struct lua_State *L);  /* store.reload */
int l_doc_files(struct lua_State *L);  /* bookman.files */
int luaopen_lulibre_ocr_core(struct lua_State *L);
int luaopen_lulibre_stores_core(struct lua_State *L);
/* curl (l_curl.c): requests through libcurl on the Lua loop, preloaded. */
int luaopen_curl(struct lua_State *L);
/* lsqlite3 (vendor/lsqlite3), preloaded. */
int luaopen_lsqlite3(struct lua_State *L);
/* Hands an OCR request to lulibre.ocr.read (l_ocr.c); any thread. */
struct ocr_req;
void lapi_ocr_read(struct ocr_req *req);

/* lua/reply.c: a handle on a request a task answers once; fail runs with
 * the request when the handle is closed or collected unanswered. take
 * returns the request, and raises an error when it was answered. */
typedef void lapi_reply_fail(void *req, const char *why);
void lapi_push_reply(struct lua_State *L, void *req, lapi_reply_fail *fail);
void *lapi_take_reply(struct lua_State *L, int idx);

/* Calls into the interface (lua/uicall.c): fn runs on the interface thread
 * with copies of L's arguments, on a lua_State that holds only values.
 * ui_send returns at once (fn's errors are reported); ui_ask yields the
 * task until fn's results come back, and raises fn's error. */
int ui_send(struct lua_State *L, int (*fn)(struct lua_State *), const char *name);
int ui_ask(struct lua_State *L, int (*fn)(struct lua_State *), const char *name);
void ui_state_close(void);

/* A value from the copy, for C on the Lua thread; the string is malloc'd. */
long long lapi_setting_int(struct lua_State *L, enum setting_id id);
char *lapi_setting_str(struct lua_State *L, enum setting_id id);

void l_job_open(struct lua_State *L);
void l_db_open(struct lua_State *L);
void l_proc_open(struct lua_State *L);
void l_hash_open(struct lua_State *L);
void l_index_open(struct lua_State *L);
void l_theme_open(struct lua_State *L);
void l_ui_open(struct lua_State *L);
void l_uv_open(struct lua_State *L);
void l_uv_preload(struct lua_State *L); /* after the globals exist */
void l_panel_open(struct lua_State *L);

#endif
