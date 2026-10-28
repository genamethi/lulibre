/* The interface, from Lua.
 *
 *   lulibre.notify(msg [, "error"])     message line (stderr when headless)
 *   print(...)                          same, joined with tabs; never stdout
 *                                       while the interface is up
 *   lulibre.command(name, fn [, help])  define a ':' command; fn(args) runs
 *                                       as a task
 *   lulibre.map(modes, keys, target)    bind keys ("n", "v" or "nv") to a
 *                                       command line or a function
 *   lulibre.exec(line)                  run a command line
 *   lulibre.current()                   id under the cursor, or nil
 *   lulibre.selection()                 ids an action applies to: the range
 *                                       being selected, else marked books in
 *                                       the list, else the current book
 *   lulibre.mark(id [, on])             mark, unmark, or toggle (on omitted)
 *   lulibre.filter([expr])              get, or set, the list filter
 *   lulibre.pick(items [, {title=}])    fuzzy-pick one; returns item, index
 *                                       or nil if cancelled (waits)
 *   lulibre.input([{prompt=, default=, suggestions=, separator=, on_change=}])
 *                                       a line of text, or nil (waits).
 *                                       suggestions: strings or {text=, detail=},
 *                                       best first; Tab takes the highlighted one.
 *                                       separator (" & "): the value is a list and
 *                                       completion applies to its last item.
 *                                       on_change(text) runs after each keystroke.
 *   lulibre.progress(text | nil)        a note in the status line while a
 *                                       script works
 *   lulibre.status(name, text [, style])  a badge in the status line, beside
 *                                       the mode, under a name of your own:
 *                                       set again to change it, with nil to
 *                                       take it away. style: accent (default)
 *                                       ok warn error dim
 *   lulibre.jump(id)                    move the list cursor to a book; false if
 *                                       it is not in the list
 *   lulibre.show(text [, title])        scrollable overlay; text may be a
 *                                       list of lines
 *   lulibre.clipboard(text)             copy to the clipboard: through tmux when
 *                                       inside it, else OSC 52 (works over ssh)
 *   lulibre.clipboard()                 what was copied last (tmux's newest
 *                                       buffer inside tmux), or nil
 *   lulibre.log(text [, level])         write to the log the console (`) shows:
 *                                       "info", "warn", "error", or "debug"
 *                                       (kept only by a debug build)
 *   lulibre.headless                    true when there is no interface
 *
 * This file also holds the ':' commands that exist because of Lua:
 * run, lua, messages, tasks, cancel. */
#include <dirent.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <lua.h>
#include <lauxlib.h>

#include "app.h"
#include "config.h"
#include "core/log.h"
#include "core/util.h"
#include "lua/bridge.h"
#include "lua/lapi.h"
#include "lua/sched.h"
#include "core/queue.h"
#include "tui/tui.h"

/* ---- reporting ---- */

/* On the interface thread: the message line and the log, or stderr. */
static void report_show(struct app *app, int level, const char *msg) {
  struct tui *t = app->tui;
  log_text(level ? LOG_ERROR : LOG_INFO, msg); /* without the interface, errors print from there */
  if (!t || !t->nc) {
    if (!level) fprintf(stderr, "%s\n", msg);
    return;
  }
  const char *nl = strchr(msg, '\n');
  if (nl) {
    char *first = xasprintf("%.*s   (` shows the rest)", (int)(nl - msg), msg);
    tui_show_msg(t, level, first);
    free(first);
  } else {
    tui_show_msg(t, level, msg);
  }
}

struct report {
  int level;
  char *msg;
};

static void report_ui(struct app *app, void *arg) {
  struct report *r = arg;
  report_show(app, r->level, r->msg);
  free(r->msg);
  free(r);
}

/* From either thread: a message, shown in the order sent. */
void lapi_report(struct app *app, int level, const char *msg) {
  struct report *r = xcalloc(1, sizeof *r);
  r->level = level;
  r->msg = xstrdup(msg ? msg : "");
  queue_post(LOOP_UI, report_ui, r);
}

void lapi_tasks_changed(struct app *app) {
  bridge_redraw(app);
}

/* Most of what follows touches the interface, so it runs there (design
 * 34): a call that answers nothing is sent as a message, a call that
 * answers yields the task until the answer comes (lua/uicall.c). Each
 * lulibre.x is a one-line wrapper around its x_ui. */
#define SEND(name, word) \
  static int name(lua_State *L) { return ui_send(L, name##_ui, word); }
#define ASK(name, word) \
  static int name(lua_State *L) { return ui_ask(L, name##_ui, word); }

static int l_notify_ui(lua_State *L) {
  const char *msg = luaL_tolstring(L, 1, NULL);
  const char *level = luaL_optstring(L, 2, "info");
  lapi_report(lapi_app(L), !strcmp(level, "error"), msg);
  return 0;
}
SEND(l_notify, "notify")

static int l_print_ui(lua_State *L) {
  struct app *app = lapi_app(L);
  int n = lua_gettop(L);
  luaL_Buffer b;
  luaL_buffinit(L, &b);
  for (int i = 1; i <= n; i++) {
    size_t len;
    const char *s = luaL_tolstring(L, i, &len); /* pushes the string */
    if (i > 1) luaL_addchar(&b, '\t');
    luaL_addvalue(&b); /* pops it */
    (void)s;
    (void)len;
  }
  luaL_pushresult(&b);
  const char *out = lua_tostring(L, -1);
  if (app->tui && app->tui->nc) lapi_report(app, 0, out);
  else puts(out);
  return 0;
}
SEND(l_print, "print")

static struct tui *need_tui(lua_State *L) {
  struct tui *t = lapi_app(L)->tui;
  if (!t || !t->nc) luaL_error(L, "this needs the interface, which is not running");
  return t;
}

/* ---- commands and keys ---- */

static int l_command_ui(lua_State *L) {
  const char *name = luaL_checkstring(L, 1);
  /* the function, as its reference in the main lua_State (lua/uicall.c) */
  int ref = (int)luaL_checkinteger(L, 2);
  const char *help = luaL_optstring(L, 3, "(defined in Lua)");
  luaL_argcheck(L, *name && !strchr(name, ' '), 1, "a command name is one word");
  command_register_lua(name, ref, help);
  return 0;
}

/* lulibre.map(modes, keys, target [, about])
 * target: a command line, or a function (which runs as a task).
 * about: what the help overlay (?) is to say the key does; without it the
 * overlay shows the command line, or for a function "a Lua function".
 * false keeps the key out of the overlay. */
static int l_map_ui(lua_State *L) {
  static int anon;
  const char *modes = luaL_checkstring(L, 1);
  const char *keys = luaL_checkstring(L, 2);
  unsigned mask = 0;
  for (const char *m = modes; *m; m++) {
    if (*m == 'n') mask |= MODE_NORMAL;
    else if (*m == 'v') mask |= MODE_VISUAL;
    else return luaL_argerror(L, 1, "modes are \"n\" (normal), \"v\" (selecting) or \"nv\"");
  }
  int hidden = lua_isboolean(L, 4) && !lua_toboolean(L, 4);
  const char *about = lua_type(L, 4) == LUA_TSTRING ? lua_tostring(L, 4) : NULL;
  char name[32];
  const char *target;
  if (lua_isinteger(L, 3)) { /* a function, as its reference in the main lua_State */
    snprintf(name, sizeof name, "lua.%d", ++anon);
    command_register_lua(name, (int)lua_tointeger(L, 3), about ? about : "(a Lua function)");
    target = name;
    if (!about) about = "a Lua function";
  } else {
    target = luaL_checkstring(L, 3);
  }
  if (keymap_bind_as(&tui_keymap, mask, keys, target, about, hidden))
    return luaL_error(L, "cannot parse the key sequence '%s'", keys);
  return 0;
}

/* lulibre.key(command [, mode]): the keys bound to that command line, as
 * they are typed ("gr", "<C-w>v"), or nil when nothing is. For messages
 * that name a key, so they name the one in force. */
static int l_key_ui(lua_State *L) {
  const char *command = luaL_checkstring(L, 1);
  const char *mode = luaL_optstring(L, 2, "n");
  sbuf out = SBUF_INIT;
  if (keymap_key_of(&tui_keymap, *mode == 'v' ? MODE_VISUAL : MODE_NORMAL, command, &out)) lua_pushstring(L, out.s);
  else lua_pushnil(L);
  sb_free(&out);
  return 1;
}
ASK(l_key, "key")

/* lulibre.maps(): every global binding, { {modes = "nv", keys = "gg", command = "move top"}, ... } */
static int l_maps_ui(lua_State *L) {
  lua_newtable(L);
  int n = 0;
  for (int i = 0; i < tui_keymap.n; i++) {
    const struct binding *b = &tui_keymap.b[i];
    if (!(b->modes & (MODE_NORMAL | MODE_VISUAL))) continue; /* replaced by a later binding */
    sbuf k = SBUF_INIT;
    key_format(&k, b->keys, b->nkeys);
    lua_createtable(L, 0, 3);
    lua_pushstring(L, b->modes & MODE_NORMAL ? (b->modes & MODE_VISUAL ? "nv" : "n") : "v");
    lua_setfield(L, -2, "modes");
    lua_pushstring(L, k.s);
    lua_setfield(L, -2, "keys");
    lua_pushstring(L, b->command);
    lua_setfield(L, -2, "command");
    if (b->about) {
      lua_pushstring(L, b->about);
      lua_setfield(L, -2, "about");
    }
    lua_pushboolean(L, b->hidden);
    lua_setfield(L, -2, "hidden");
    lua_rawseti(L, -2, ++n);
    sb_free(&k);
  }
  return 1;
}
ASK(l_maps, "maps")

/* lulibre.commands(): every command there is, { {name = "group", help = "..."}, ... } */
static int add_command(const char *name, const char *help, void *ud) {
  lua_State *L = ud;
  lua_createtable(L, 0, 2);
  lua_pushstring(L, name);
  lua_setfield(L, -2, "name");
  lua_pushstring(L, help);
  lua_setfield(L, -2, "help");
  lua_rawseti(L, -2, (lua_Integer)lua_rawlen(L, -2) + 1);
  return 0;
}

static int l_commands_ui(lua_State *L) {
  lua_newtable(L);
  command_each(add_command, L);
  return 1;
}
ASK(l_commands, "commands")

/* keymap.set(place, key, action): a key of a place that has keys of its
 * own ("panel", "line", "picker", "pager", "console", "select") bound to
 * one of its actions; "" unbinds. */
static int l_place_map_ui(lua_State *L) {
  const char *place = luaL_checkstring(L, 1);
  if (ctx_named(place) < 0) return luaL_error(L, "no place is called %s", place);
  char *err = NULL;
  if (ctx_bind(place, luaL_checkstring(L, 2), luaL_optstring(L, 3, ""), &err)) {
    lua_pushstring(L, err);
    free(err);
    return lua_error(L);
  }
  lua_pushboolean(L, 1);
  return 1;
}

/* lulibre.place_keys(place): the keys of a place as lines of text, each
 * "keys   what they do"; nil for no such place. */
static int l_place_keys_ui(lua_State *L) {
  int c = ctx_named(luaL_checkstring(L, 1));
  if (c < 0) {
    lua_pushnil(L);
    return 1;
  }
  sbuf out = SBUF_INIT;
  ctx_describe(c, &out, 0);
  lua_pushstring(L, out.s ? out.s : "");
  sb_free(&out);
  return 1;
}
ASK(l_place_keys, "place_keys")

static int l_exec_ui(lua_State *L) {
  tui_exec(need_tui(L), luaL_checkstring(L, 1));
  return 0;
}
SEND(l_exec, "exec")

/* ---- the list ---- */


static int l_mark_ui(lua_State *L) {
  struct tui *t = need_tui(L);
  lua_Integer id = luaL_checkinteger(L, 1);
  rows_mark(t, id, lua_isnoneornil(L, 2) ? -1 : lua_toboolean(L, 2));
  return 0;
}
SEND(l_mark, "mark")

static int l_filter_ui(lua_State *L) {
  struct tui *t = need_tui(L);
  if (lua_isnoneornil(L, 1)) {
    lua_pushstring(L, t->rows.filter ? t->rows.filter : "");
    return 1;
  }
  rows_set_filter(t, luaL_checkstring(L, 1));
  return 0;
}
ASK(l_filter, "filter")

/* ---- pick ----
 * The picker lives on the interface thread and the waiting task on the Lua
 * thread: the picker is built over there, its answer is sent back here. */

/* Which lua_State a reference belongs to: one more at each restart, so a
 * message about a reference into the old state is dropped. */
static atomic_uint generation;

void lapi_new_generation(void) {
  atomic_fetch_add(&generation, 1);
}

struct pwait {
  struct app *app;
  struct task *task;
  struct tui *t; /* set on the interface thread when the picker opens */
  int items_ref;
  unsigned gen; /* the lua_State items_ref is in */
};

struct pdone {
  struct pwait *w;
  sqlite3_int64 index;
};

static void pick_done(struct app *app, void *arg) { /* Lua thread */
  struct pdone *d = arg;
  struct pwait *w = d->w;
  lua_State *L = sched_end_wait(w->task);
  if (L) {
    if (d->index > 0) {
      lua_rawgeti(L, LUA_REGISTRYINDEX, w->items_ref);
      lua_rawgeti(L, -1, d->index);
      lua_remove(L, -2);
      lua_pushinteger(L, d->index);
      sched_wake(w->task, 2);
    } else {
      lua_pushnil(L);
      sched_wake(w->task, 1);
    }
  }
  if (w->gen == atomic_load(&generation)) luaL_unref(app->L, LUA_REGISTRYINDEX, w->items_ref);
  free(w);
  free(d);
}

static void pick_finish(struct pwait *w, sqlite3_int64 index) {
  struct pdone *d = xcalloc(1, sizeof *d);
  d->w = w;
  d->index = index;
  queue_post(LOOP_LUA, pick_done, d);
}

static void pick_accept(struct tui *t, sqlite3_int64 id, const char *text, void *ud) {
  pick_finish(ud, id);
}

static void pick_cancel(struct tui *t, void *ud) {
  pick_finish(ud, 0);
}

static void picker_close_ui(struct app *app, void *arg) {
  struct pwait *w = arg;
  if (w->t) picker_close(w->t); /* reports back through pick_cancel */
}

static void pick_task_cancelled(void *ud) {
  queue_post(LOOP_UI, picker_close_ui, ud);
}

/* items, options, the pwait (an integer) */
static int pick_open_ui(lua_State *L) {
  struct pwait *w = (struct pwait *)(intptr_t)luaL_checkinteger(L, 3);
  struct tui *t = lapi_app(L)->tui;
  if (!t || !t->nc) {
    pick_finish(w, 0);
    return 0;
  }
  const char *title = "pick";
  if (lua_istable(L, 2)) {
    lua_getfield(L, 2, "title");
    if (lua_isstring(L, -1)) title = lua_tostring(L, -1);
  }
  w->t = t;
  struct picker *p = picker_new(t, title, pick_accept, w);
  picker_on_cancel(p, pick_cancel);
  lua_Integer n = (lua_Integer)lua_rawlen(L, 1);
  for (lua_Integer i = 1; i <= n; i++) {
    lua_rawgeti(L, 1, i);
    const char *text = NULL, *detail = NULL;
    int pushed = 1;
    if (lua_istable(L, -1)) {
      lua_getfield(L, -1, "text");
      if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        lua_rawgeti(L, -1, 1);
      }
      lua_getfield(L, -2, "detail");
      text = lua_tostring(L, -2);
      detail = lua_tostring(L, -1);
      pushed = 3;
    } else {
      text = luaL_tolstring(L, -1, NULL);
      pushed = 2;
    }
    picker_add(p, i, text ? text : "", detail);
    lua_pop(L, pushed);
  }
  picker_open(t, p);
  return 0;
}

static int l_pick(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  sched_require_task(L);
  if (!lapi_app(L)->tui) return luaL_error(L, "this needs the interface, which is not running");
  struct pwait *w = xcalloc(1, sizeof *w);
  w->gen = atomic_load(&generation);
  w->app = lapi_app(L);
  lua_settop(L, 2);
  lua_pushvalue(L, 1);
  w->items_ref = luaL_ref(L, LUA_REGISTRYINDEX);
  lua_pushinteger(L, (lua_Integer)(intptr_t)w);
  /* waiting before the picker exists, so its answer cannot come too early */
  w->task = sched_begin_wait(L);
  sched_on_cancel(w->task, pick_task_cancelled, w);
  ui_send(L, pick_open_ui, "pick");
  return lua_yield(L, 0);
}

/* ---- input ---- */

struct iwait {
  struct app *app;
  struct task *task;
  struct tui *t;
  int change_ref; /* registry ref of on_change, or LUA_NOREF */
  unsigned gen;   /* the lua_State change_ref is in */
};

struct itext {
  struct iwait *w;
  char *text; /* NULL: cancelled */
  int final;
};

static void input_event(struct app *app, void *arg) { /* Lua thread */
  struct itext *e = arg;
  struct iwait *w = e->w;
  if (e->final) {
    lua_State *L = sched_end_wait(w->task);
    if (L) {
      if (e->text) lua_pushstring(L, e->text);
      else lua_pushnil(L);
      sched_wake(w->task, 1);
    }
    if (w->gen == atomic_load(&generation)) luaL_unref(app->L, LUA_REGISTRYINDEX, w->change_ref);
    free(w);
  } else if (w->change_ref != LUA_NOREF && w->gen == atomic_load(&generation)) {
    /* on_change runs on the main state, between keystrokes: it cannot wait */
    lua_State *L = app->L;
    lua_rawgeti(L, LUA_REGISTRYINDEX, w->change_ref);
    lua_pushstring(L, e->text ? e->text : "");
    if (lua_pcall(L, 1, 0, 0) != LUA_OK) {
      lapi_report(app, 1, lua_tostring(L, -1));
      lua_pop(L, 1);
    }
  }
  free(e->text);
  free(e);
}

static void input_send(struct iwait *w, const char *text, int final) {
  struct itext *e = xcalloc(1, sizeof *e);
  e->w = w;
  e->text = text ? xstrdup(text) : NULL;
  e->final = final;
  queue_post(LOOP_LUA, input_event, e);
}

static void input_answer(struct tui *t, const char *text, void *ud) {
  input_send(ud, text, 1);
}

static void input_changed(struct tui *t, const char *text, void *ud) {
  input_send(ud, text ? text : "", 0);
}

static void input_cancel_ui(struct app *app, void *arg) {
  struct iwait *w = arg;
  if (w->t) tui_input_cancel(w->t);
}

static void input_task_cancelled(void *ud) {
  queue_post(LOOP_UI, input_cancel_ui, ud);
}

/* the options table (or prompt string), the iwait (an integer) */
static int input_open_ui(lua_State *L) {
  struct iwait *w = (struct iwait *)(intptr_t)luaL_checkinteger(L, 2);
  struct tui *t = lapi_app(L)->tui;
  if (!t || !t->nc) {
    input_send(w, NULL, 1);
    return 0;
  }
  const char *prompt = "> ", *initial = "", *sep = NULL;
  const char **texts = NULL, **details = NULL;
  int nsugg = 0;
  if (lua_istable(L, 1)) {
    lua_getfield(L, 1, "prompt");
    if (lua_isstring(L, -1)) prompt = lua_tostring(L, -1);
    lua_getfield(L, 1, "default");
    if (lua_isstring(L, -1)) initial = lua_tostring(L, -1);
    lua_getfield(L, 1, "separator");
    if (lua_isstring(L, -1)) sep = lua_tostring(L, -1);
    lua_getfield(L, 1, "suggestions");
    if (lua_istable(L, -1)) {
      int tbl = lua_gettop(L);
      int n = (int)lua_rawlen(L, tbl);
      luaL_checkstack(L, n * 3 + 8, "too many suggestions");
      texts = lua_newuserdatauv(L, ((size_t)n + 1) * sizeof *texts, 0);
      details = lua_newuserdatauv(L, ((size_t)n + 1) * sizeof *details, 0);
      memset(texts, 0, ((size_t)n + 1) * sizeof *texts);
      memset(details, 0, ((size_t)n + 1) * sizeof *details);
      for (int i = 1; i <= n; i++) { /* strings stay on the stack until copied */
        lua_rawgeti(L, tbl, i);
        if (lua_istable(L, -1)) {
          lua_getfield(L, -1, "text");
          lua_getfield(L, -2, "detail");
          texts[nsugg] = lua_tostring(L, -2);
          details[nsugg] = lua_tostring(L, -1);
        } else {
          texts[nsugg] = lua_tostring(L, -1);
        }
        if (texts[nsugg] && *texts[nsugg]) nsugg++;
      }
    }
  } else if (lua_isstring(L, 1)) {
    prompt = lua_tostring(L, 1);
  }
  w->t = t;
  tui_input(t, prompt, initial, input_answer, w);
  if (nsugg) tui_input_suggest(t, nsugg, texts, details, sep);
  if (w->change_ref != LUA_NOREF) tui_input_on_change(t, input_changed);
  return 0;
}

static int l_input(lua_State *L) {
  sched_require_task(L);
  if (!lapi_app(L)->tui) return luaL_error(L, "this needs the interface, which is not running");
  struct iwait *w = xcalloc(1, sizeof *w);
  w->gen = atomic_load(&generation);
  w->app = lapi_app(L);
  w->change_ref = LUA_NOREF;
  lua_settop(L, 1);
  if (lua_istable(L, 1)) {
    lua_getfield(L, 1, "on_change");
    if (lua_isfunction(L, -1)) w->change_ref = luaL_ref(L, LUA_REGISTRYINDEX);
    else lua_pop(L, 1);
  }
  lua_pushinteger(L, (lua_Integer)(intptr_t)w);
  w->task = sched_begin_wait(L);
  sched_on_cancel(w->task, input_task_cancelled, w);
  ui_send(L, input_open_ui, "input");
  return lua_yield(L, 0);
}

/* lulibre.clipboard(text) copies; lulibre.clipboard() gives back what was
 * copied last (tui/clip.c says where from). */
static int l_clipboard_ui(lua_State *L) {
  if (lua_isnoneornil(L, 1)) {
    char *text = clip_paste();
    if (text) lua_pushstring(L, text);
    else lua_pushnil(L);
    free(text);
    return 1;
  }
  size_t n;
  const char *s = luaL_checklstring(L, 1, &n);
  lua_pushboolean(L, clip_copy(s, n));
  return 1;
}
ASK(l_clipboard, "clipboard")

/* lulibre.edit_file(path): the editor ($VISUAL, $EDITOR, else vim or vi) on
 * a file, with the terminal handed over until it exits. Returns its exit
 * status, or nil and why when none could be run. */
static int l_edit_file_ui(lua_State *L) {
  struct app *app = lapi_app(L);
  const char *path = luaL_checkstring(L, 1);
  int status = -1;
  if (app->tui && app->tui->nc) {
    status = tui_edit_file(app->tui, path);
  } else {
    /* no interface: the terminal is the editor's anyway */
    const char *editor = getenv("VISUAL");
    if (!editor || !*editor) editor = getenv("EDITOR");
    if (!editor || !*editor) editor = "vi";
    char *cmd = xasprintf("%s '%s'", editor, path);
    int rc = system(cmd);
    free(cmd);
    status = rc == -1 ? -1 : WEXITSTATUS(rc);
  }
  if (status < 0) {
    lua_pushnil(L);
    lua_pushstring(L, "no editor: set $EDITOR (vim and vi were not found either)");
    return 2;
  }
  lua_pushinteger(L, status);
  return 1;
}
ASK(l_edit_file, "edit_file")

/* lulibre.in_terminal(argv): a program with the terminal handed over until
 * it exits (sudo asking for a password, say); argv[1] is looked for on
 * $PATH. Without the interface it runs in the terminal lulibre runs in.
 * Returns its exit status, or nil and why when it could not be run. */
static int l_in_terminal_ui(lua_State *L) {
  struct app *app = lapi_app(L);
  luaL_checktype(L, 1, LUA_TTABLE);
  int n = (int)lua_rawlen(L, 1);
  if (n < 1) return luaL_error(L, "in_terminal: { program, arguments... }");
  char **argv = xcalloc((size_t)n + 1, sizeof *argv);
  for (int i = 1; i <= n; i++) {
    lua_rawgeti(L, 1, i);
    argv[i - 1] = (char *)luaL_checkstring(L, -1); /* (the table keeps the string) */
    lua_pop(L, 1);
  }
  int status = -1;
  if (app->tui && app->tui->nc) {
    status = tui_in_terminal(app->tui, argv);
  } else {
    pid_t pid = fork();
    if (pid == 0) {
      execvp(argv[0], argv);
      _exit(127);
    } else if (pid > 0) {
      int st;
      while (waitpid(pid, &st, 0) < 0 && errno == EINTR) {
      }
      status = WIFEXITED(st) ? WEXITSTATUS(st) : -1;
    }
  }
  free(argv);
  if (status == 127 || status < 0) {
    lua_pushnil(L);
    lua_pushstring(L, status == 127 ? "could not be run" : "did not exit");
    return 2;
  }
  lua_pushinteger(L, status);
  return 1;
}
ASK(l_in_terminal, "in_terminal")

static int l_progress_ui(lua_State *L) {
  struct app *app = lapi_app(L);
  const char *text = lua_isnoneornil(L, 1) ? NULL : luaL_tolstring(L, 1, NULL);
  if (app->tui && app->tui->nc) tui_progress(app->tui, text);
  return 0;
}
SEND(l_progress, "progress")

static int l_status_ui(lua_State *L) {
  static const char *const styles[] = {"accent", "ok", "warn", "error", "dim", NULL};
  struct app *app = lapi_app(L);
  const char *name = luaL_checkstring(L, 1);
  const char *text = lua_isnoneornil(L, 2) ? NULL : luaL_tolstring(L, 2, NULL);
  int style = luaL_checkoption(L, 3, "accent", styles);
  int color = style == 1 ? theme.ok : style == 2 ? theme.warn : style == 3 ? theme.error
            : style == 4 ? theme.dim : theme.accent;
  if (app->tui && app->tui->nc) tui_badge(app->tui, name, text, color);
  return 0;
}
SEND(l_status, "status")

static int l_goto_ui(lua_State *L) {
  struct tui *t = need_tui(L);
  lua_Integer id = luaL_checkinteger(L, 1);
  int found = rows_reveal(t, id);
  if (found) preview_book_changed(t);
  /* a list that is still being read may yet hold it: land there when it comes */
  else if (t->rows.running || t->rows.queued[0]) t->rows.want_id = id;
  lua_pushboolean(L, found);
  return 1;
}
SEND(l_goto, "goto")

static int l_show_ui(lua_State *L) {
  struct app *app = lapi_app(L);
  const char *title = luaL_optstring(L, 2, "");
  if (lua_istable(L, 1)) { /* a list of lines */
    luaL_Buffer b;
    luaL_buffinit(L, &b);
    lua_Integer n = (lua_Integer)lua_rawlen(L, 1);
    for (lua_Integer i = 1; i <= n; i++) {
      lua_rawgeti(L, 1, i);
      luaL_tolstring(L, -1, NULL);
      lua_remove(L, -2);
      luaL_addvalue(&b);
      luaL_addchar(&b, '\n');
    }
    luaL_pushresult(&b);
  } else {
    luaL_tolstring(L, 1, NULL);
  }
  const char *text = lua_tostring(L, -1);
  if (app->tui && app->tui->nc) tui_pager(app->tui, title, text);
  else fputs(text, stdout);
  return 0;
}
SEND(l_show, "show")

/* ---- scripts ---- */

char **lapi_script_dirs(struct app *app) {
  char **dirs = xcalloc(4, sizeof *dirs);
  int n = 0;
  dirs[n++] = xasprintf("%s/scripts", app->config_dir);
  /* the bundled scripts of one runtime only, as for modules (lstate.c): a
   * build tree's (build/lulibre -> ../scripts), LULIBRE_RUNTIME's (its lua/
   * folder's sibling), or the installed ones */
  const char *rt = getenv("LULIBRE_RUNTIME");
  if (rt && rt[0]) dirs[n++] = xasprintf("%s/../scripts", rt);
  char exe[4096];
  ssize_t len = n == 1 ? readlink("/proc/self/exe", exe, sizeof exe - 1) : -1;
  if (len > 0) {
    exe[len] = '\0';
    char *slash = strrchr(exe, '/');
    if (slash) {
      *slash = '\0';
      char *dev = xasprintf("%s/../scripts", exe);
      char *lua = xasprintf("%s/../lua", exe); /* a tree has both */
      if (access(dev, R_OK) == 0 && access(lua, R_OK) == 0) dirs[n++] = dev;
      else free(dev);
      free(lua);
    }
  }
  if (n == 1) dirs[n++] = xasprintf("%s/scripts", lstate_datadir());
  return dirs;
}

static void free_dirs(char **dirs) {
  for (char **d = dirs; *d; d++) free(*d);
  free(dirs);
}

char *lapi_find_script(struct app *app, const char *name) {
  if (strchr(name, '/')) return access(name, R_OK) == 0 ? xstrdup(name) : NULL;
  char **dirs = lapi_script_dirs(app);
  char *found = NULL;
  size_t nl = strlen(name);
  int has_ext = nl > 4 && !strcmp(name + nl - 4, ".lua");
  for (char **d = dirs; *d && !found; d++) {
    char *p = xasprintf("%s/%s%s", *d, name, has_ext ? "" : ".lua");
    if (access(p, R_OK) == 0) found = p;
    else free(p);
  }
  free_dirs(dirs);
  if (!found && access(name, R_OK) == 0) found = xstrdup(name);
  return found;
}

int lapi_run_file(struct app *app, const char *path, int argc, char **argv, char **err) {
  lua_State *L = app->L;
  if (luaL_loadfile(L, path) != LUA_OK) {
    *err = xstrdup(lua_tostring(L, -1));
    lua_pop(L, 1);
    return 0;
  }
  for (int i = 0; i < argc; i++) lua_pushstring(L, argv[i]);
  const char *base = strrchr(path, '/');
  return sched_spawn(L, argc, base ? base + 1 : path);
}

/* ---- what the interface asks of Lua: each request is sent to the Lua
 * thread, which answers through lapi_report or the pager ---- */

/* A command or key's function, run as a task with what the interface was
 * at when it was invoked (design 4, 34): fn{ name=, args=, book=,
 * selection = { id, ... } }. */
struct spawn_req {
  int ref;
  unsigned gen;
  char *name, *arg;
  long long book;
  long long *selection;
  int nselection;
};

static void spawn_ref(struct app *app, void *arg) {
  struct spawn_req *r = arg;
  lua_State *L = app->L;
  if (L && r->gen == atomic_load(&generation)) {
    lua_rawgeti(L, LUA_REGISTRYINDEX, r->ref);
    lua_createtable(L, 0, 4);
    lua_pushstring(L, r->name);
    lua_setfield(L, -2, "name");
    lua_pushstring(L, r->arg);
    lua_setfield(L, -2, "args");
    if (r->book) {
      lua_pushinteger(L, r->book);
      lua_setfield(L, -2, "book");
    }
    lua_createtable(L, r->nselection, 0);
    for (int i = 0; i < r->nselection; i++) {
      lua_pushinteger(L, r->selection[i]);
      lua_rawseti(L, -2, i + 1);
    }
    lua_setfield(L, -2, "selection");
    sched_spawn(L, 1, r->name);
  }
  free(r->selection);
  free(r->name);
  free(r->arg);
  free(r);
}

/* The interface thread. */
void lapi_spawn_ref(struct app *app, int ref, const char *name, const char *arg) {
  struct spawn_req *r = xcalloc(1, sizeof *r);
  r->ref = ref;
  r->gen = atomic_load(&generation);
  r->name = xstrdup(name);
  r->arg = xstrdup(arg ? arg : "");
  struct tui *t = app->tui;
  if (t) {
    r->book = rows_current(t);
    sqlite3_int64 *ids = rows_selection(t, &r->nselection);
    r->selection = xcalloc((size_t)r->nselection + 1, sizeof *r->selection);
    for (int i = 0; i < r->nselection; i++) r->selection[i] = ids[i];
    free(ids);
  }
  queue_post(LOOP_LUA, spawn_ref, r);
}

struct unref_req {
  int ref;
  unsigned gen;
};

static void unref(struct app *app, void *arg) {
  struct unref_req *u = arg;
  if (app->L && u->gen == atomic_load(&generation)) luaL_unref(app->L, LUA_REGISTRYINDEX, u->ref);
  free(u);
}

void lapi_unref(int ref) {
  if (ref <= 0) return;
  struct unref_req *u = xcalloc(1, sizeof *u);
  u->ref = ref;
  u->gen = atomic_load(&generation);
  queue_post(LOOP_LUA, unref, u);
}

/* "path\0arg arg": load the script and start it */
static void run_line(struct app *app, void *arg) {
  char *path = arg, *args = path + strlen(path) + 1, *save = NULL;
  char *argv[32];
  int argc = 0;
  for (char *a = strtok_r(args, " ", &save); a && argc < 32; a = strtok_r(NULL, " ", &save))
    argv[argc++] = a;
  char *err = NULL;
  if (!lapi_run_file(app, path, argc, argv, &err)) {
    lapi_report(app, 1, err);
    free(err);
  }
  free(path);
}

/* "name arg arg": the script is looked up here, on the interface thread,
 * which owns the options that say where scripts are */
static void run_named(struct tui *t, const char *line) {
  while (*line == ' ') line++;
  size_t nl = strcspn(line, " ");
  char *name = xstrndup(line, nl);
  char *path = *name ? lapi_find_script(t->app, name) : NULL;
  if (!path) {
    tui_msg(t, 1, "no script named '%s' (see :run with no argument)", name);
  } else {
    const char *args = line + nl;
    size_t pl = strlen(path), al = strlen(args);
    char *msg = xmalloc(pl + al + 2);
    memcpy(msg, path, pl + 1);
    memcpy(msg + pl + 1, args, al + 1);
    queue_post(LOOP_LUA, run_line, msg);
  }
  free(path);
  free(name);
}

static void run_picked(struct tui *t, sqlite3_int64 id, const char *text, void *ud) {
  run_named(t, text);
}

static void c_run(struct tui *t, const char *args) {
  if (*args) {
    run_named(t, args);
    return;
  }
  struct picker *p = picker_new(t, "scripts", run_picked, NULL);
  char **dirs = lapi_script_dirs(t->app);
  for (char **d = dirs; *d; d++) {
    DIR *dir = opendir(*d);
    if (!dir) continue;
    for (struct dirent *e; (e = readdir(dir));) {
      size_t n = strlen(e->d_name);
      if (n <= 4 || strcmp(e->d_name + n - 4, ".lua")) continue;
      char *name = xstrndup(e->d_name, n - 4);
      picker_add(p, 0, name, *d);
      free(name);
    }
    closedir(dir);
  }
  free_dirs(dirs);
  picker_open(t, p);
}

/* :lua CODE: lulibre.eval.run(CODE) as a task */
static void eval_line(struct app *app, void *arg) {
  lua_State *L = app->L;
  if (!L) {
    free(arg);
    return;
  }
  lua_getglobal(L, "require");
  lua_pushliteral(L, "lulibre.eval");
  if (lua_pcall(L, 1, 1, 0) != LUA_OK) {
    lapi_report(app, 1, lua_tostring(L, -1));
    lua_pop(L, 1);
  } else {
    lua_getfield(L, -1, "run");
    lua_remove(L, -2);
    lua_pushstring(L, arg);
    sched_spawn(L, 1, ":lua");
  }
  free(arg);
}

static void c_lua(struct tui *t, const char *args) {
  queue_post(LOOP_LUA, eval_line, xstrdup(args));
}

static void message_line(const struct log_entry *e, void *ud) {
  time_t secs = (time_t)e->when;
  struct tm tm;
  char stamp[16];
  localtime_r(&secs, &tm);
  strftime(stamp, sizeof stamp, "%H:%M:%S", &tm);
  sb_printf(ud, "%s %-5s  %s\n", stamp, log_level_name(e->level), e->text);
}

/* the whole log in the pager; the console (`) is the live view of the same */
static void c_messages(struct tui *t, const char *args) {
  sbuf out = SBUF_INIT;
  log_each(message_line, &out);
  tui_pager(t, "messages", out.len ? out.s : "(nothing has been logged yet)\n");
  sb_free(&out);
  t->help_scroll = 1 << 20; /* newest at the bottom; the pager clamps this */
}

/* ` : show or hide the console, leaving the focus where it is */
static void c_console(struct tui *t, const char *args) {
  struct node *open = wm_find(t, &view_console);
  if (open && open->cls == &view_console) {
    /* not through t->focus: the focused node may be the one whose place the
     * console's sibling takes, and would be freed under a saved pointer */
    wm_close_leaf(t, open);
  } else {
    struct node *was = t->focus;
    wm_dock(t, &view_console, view_console.create(t), 0.3f, 'b');
    if (!strcmp(args, "focus")) return;
    t->focus = was;
  }
  tui_dirty(t);
}

/* lulibre.log(text [, level]): level is "info" (default), "warn", "error" or
 * "debug"; debug entries are dropped by a release build. Any thread. */
static int l_log(lua_State *L) {
  static const char *const levels[] = {"error", "warn", "info", "debug", NULL};
  int level = luaL_checkoption(L, 2, "info", levels);
  const char *text = luaL_tolstring(L, 1, NULL);
  if (level == LOG_DEBUG && !LULIBRE_DEBUG) return 0;
  log_text(level, text);
  return 0;
}

static void tasks_pager_ui(struct app *app, void *arg) {
  if (app->tui && app->tui->nc) tui_pager(app->tui, "tasks", arg);
  free(arg);
}

static void list_tasks(struct app *app, void *arg) {
  lua_State *L = app->L;
  sbuf out = SBUF_INIT;
  sched_push_tasks(L);
  lua_Integer n = (lua_Integer)lua_rawlen(L, -1);
  for (lua_Integer i = 1; i <= n; i++) {
    lua_rawgeti(L, -1, i);
    lua_getfield(L, -1, "id");
    lua_getfield(L, -2, "state");
    lua_getfield(L, -3, "name");
    sb_printf(&out, "  %-4d %-10s %s\n", (int)lua_tointeger(L, -3), lua_tostring(L, -2),
              lua_tostring(L, -1));
    lua_pop(L, 4);
  }
  lua_pop(L, 1);
  if (!out.len) sb_puts(&out, "no tasks are running\n");
  else sb_puts(&out, "\n:cancel ID stops one; :cancel all stops every task.\n");
  queue_post(LOOP_UI, tasks_pager_ui, sb_take(&out));
}

static void c_tasks(struct tui *t, const char *args) {
  queue_post(LOOP_LUA, list_tasks, NULL);
}

static void cancel_tasks(struct app *app, void *arg) {
  char *which = arg;
  if (!strcmp(which, "all")) {
    sched_cancel_all(app);
    lapi_report(app, 0, "cancelling every task");
  } else if (!sched_cancel(app, atoi(which))) {
    char *msg = xasprintf("no task %s (see :tasks)", which);
    lapi_report(app, 1, msg);
    free(msg);
  }
  free(which);
}

static void c_cancel(struct tui *t, const char *args) {
  /* the running task, if it is the one, at once: it reads no message */
  bridge_interrupt(t->app, !strcmp(args, "all") ? sched_running_id() : atoi(args));
  queue_post(LOOP_LUA, cancel_tasks, xstrdup(args));
}

/* ---- keymap and cmd: key bindings and commands, as Neovim's ----
 *
 *   keymap.set(mode, lhs, rhs [, opts])  mode "n", "v", "nv" or {"n", "v"}, or a
 *                                        place ("panel", "line", "picker",
 *                                        "pager", "console", "select") and rhs
 *                                        one of its actions ("" unbinds);
 *                                        rhs a command line, or a function
 *                                        run as a task with {book=,
 *                                        selection=}; opts {desc=, hidden=}
 *   keymap.del(mode, lhs)
 *   cmd.create(name, fn [, opts])        :name runs fn{name=, args=, book=,
 *                                        selection=} as a task; opts {desc=};
 *                                        a command of that name is replaced
 *   cmd.del(name)
 *
 * Each is a message to the interface (design 34): an error there (a key
 * sequence it cannot read) is reported, not raised. */

static const char *modes_of(lua_State *L, int idx) {
  if (lua_istable(L, idx)) {
    int n = (int)lua_rawlen(L, idx);
    luaL_Buffer b;
    luaL_buffinit(L, &b);
    for (int i = 1; i <= n; i++) {
      lua_rawgeti(L, idx, i);
      luaL_addvalue(&b);
    }
    luaL_pushresult(&b);
    lua_replace(L, idx);
  }
  const char *m = luaL_checkstring(L, idx);
  for (const char *p = m; *p; p++)
    if (*p != 'n' && *p != 'v') luaL_argerror(L, idx, "modes are \"n\" (normal), \"v\" (selecting) or both");
  return m;
}

static int is_place(lua_State *L, int idx) {
  return lua_type(L, idx) == LUA_TSTRING && strspn(lua_tostring(L, idx), "nv") != strlen(lua_tostring(L, idx));
}

static int keymap_set(lua_State *L) {
  if (is_place(L, 1)) { /* a place's key: one of its actions */
    luaL_checkstring(L, 2);
    luaL_checkstring(L, 3);
    lua_settop(L, 3);
    return ui_send(L, l_place_map_ui, "keymap.set");
  }
  modes_of(L, 1);
  luaL_checkstring(L, 2);
  uint32_t keys[KEYSEQ_MAX];
  if (!key_parse(lua_tostring(L, 2), keys)) return luaL_argerror(L, 2, "not a key sequence (\"gr\", \"<C-w>v\", \"<Space>\")");
  if (!lua_isfunction(L, 3)) luaL_checkstring(L, 3);
  /* the about l_map_ui takes: the description, or false to hide the key */
  int hidden = 0;
  const char *desc = NULL;
  if (lua_istable(L, 4)) {
    lua_getfield(L, 4, "hidden");
    hidden = lua_toboolean(L, -1);
    lua_getfield(L, 4, "desc");
    desc = lua_tostring(L, -1);
    lua_pop(L, 2);
  }
  lua_settop(L, 3);
  if (hidden) lua_pushboolean(L, 0);
  else if (desc) lua_pushstring(L, desc);
  return ui_send(L, l_map_ui, "keymap.set");
}

static int keymap_del_ui(lua_State *L) {
  const char *modes = luaL_checkstring(L, 1);
  unsigned mask = (strchr(modes, 'n') ? MODE_NORMAL : 0) | (strchr(modes, 'v') ? MODE_VISUAL : 0);
  if (keymap_unbind(&tui_keymap, mask, luaL_checkstring(L, 2)) > 0)
    return luaL_error(L, "nothing is bound to %s", lua_tostring(L, 2));
  return 0;
}

static int keymap_del(lua_State *L) {
  if (is_place(L, 1)) {
    luaL_checkstring(L, 2);
    lua_settop(L, 2);
    lua_pushliteral(L, "");
    return ui_send(L, l_place_map_ui, "keymap.del");
  }
  modes_of(L, 1);
  luaL_checkstring(L, 2);
  lua_settop(L, 2);
  return ui_send(L, keymap_del_ui, "keymap.del");
}

static int cmd_create(lua_State *L) {
  const char *name = luaL_checkstring(L, 1);
  luaL_argcheck(L, *name && !strchr(name, ' '), 1, "a command name is one word");
  luaL_checktype(L, 2, LUA_TFUNCTION);
  const char *desc = NULL;
  if (lua_istable(L, 3)) {
    lua_getfield(L, 3, "desc");
    desc = lua_tostring(L, -1);
    lua_pop(L, 1);
  }
  lua_settop(L, 2);
  lua_pushstring(L, desc ? desc : "(defined in Lua)");
  return ui_send(L, l_command_ui, "cmd.create");
}

static int cmd_del_ui(lua_State *L) {
  if (command_remove_lua(luaL_checkstring(L, 1))) return luaL_error(L, "no command %s was made in Lua", lua_tostring(L, 1));
  return 0;
}

static int cmd_del(lua_State *L) {
  luaL_checkstring(L, 1);
  lua_settop(L, 1);
  return ui_send(L, cmd_del_ui, "cmd.del");
}

int luaopen_keymap(lua_State *L) {
  static const luaL_Reg fns[] = {{"set", keymap_set}, {"del", keymap_del}, {NULL, NULL}};
  luaL_newlib(L, fns);
  return 1;
}

int luaopen_cmd(lua_State *L) {
  static const luaL_Reg fns[] = {{"create", cmd_create}, {"del", cmd_del}, {NULL, NULL}};
  luaL_newlib(L, fns);
  return 1;
}

void l_ui_open(lua_State *L) {
  static const luaL_Reg fns[] = {
    {"notify", l_notify},
    {"exec", l_exec},
    {"mark", l_mark},     {"filter", l_filter},   {"pick", l_pick},
    {"input", l_input},   {"show", l_show},       {"progress", l_progress},
    {"status", l_status}, {"edit_file", l_edit_file}, {"in_terminal", l_in_terminal},
    {"commands", l_commands},
    {"jump", l_goto},     {"clipboard", l_clipboard}, {"log", l_log},
    {"key", l_key},       {"maps", l_maps},       
    {"place_keys", l_place_keys}, {NULL, NULL},
  };
  luaL_setfuncs(L, fns, 0);
  lua_pushcfunction(L, l_print);
  lua_setglobal(L, "print");

  command_register("run", c_run, "[script [args]]  run a Lua script; no argument lists them");
  command_register("lua", c_lua, "code  run a line of Lua and show what it returns");
  command_register("messages", c_messages, "the log so far, in a pager");
  command_register("console", c_console, "[focus]  show or hide the log console");
  command_register("tasks", c_tasks, "scripts that are running");
  command_register("cancel", c_cancel, "ID | all  stop a running script");
}
