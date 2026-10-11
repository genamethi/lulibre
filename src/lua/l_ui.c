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
#include <stdio.h>
#include <stdlib.h>
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
#include "tui/tui.h"

/* ---- reporting ---- */

struct report {
  struct app *app;
  int level;
  const char *msg;
};

static void report_ui(void *arg) {
  struct report *r = arg;
  struct tui *t = r->app->tui;
  const char *msg = r->msg;
  log_text(r->level ? LOG_ERROR : LOG_INFO, msg); /* without the interface, errors print from there */
  if (!t || !t->nc) {
    if (!r->level) fprintf(stderr, "%s\n", msg);
    return;
  }
  const char *nl = strchr(msg, '\n');
  if (nl) {
    char *first = xasprintf("%.*s   (` shows the rest)", (int)(nl - msg), msg);
    tui_show_msg(t, r->level, first);
    free(first);
  } else {
    tui_show_msg(t, r->level, msg);
  }
}

void lapi_report(struct app *app, int level, const char *msg) {
  struct report r = {app, level, msg ? msg : ""};
  bridge_ui(app, report_ui, &r);
}

void lapi_tasks_changed(struct app *app) {
  bridge_redraw(app);
}

/* Most of what follows touches the interface, so it runs there: each
 * lulibre.x is a one-line wrapper that sends its x_ui over (lua/bridge.h). */
#define ON_UI(name) \
  static int name(lua_State *L) { return ui_call(L, name##_ui); }

static int l_notify_ui(lua_State *L) {
  const char *msg = luaL_tolstring(L, 1, NULL);
  const char *level = luaL_optstring(L, 2, "info");
  lapi_report(lapi_app(L), !strcmp(level, "error"), msg);
  return 0;
}
ON_UI(l_notify)

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
ON_UI(l_print)

static struct tui *need_tui(lua_State *L) {
  struct tui *t = lapi_app(L)->tui;
  if (!t || !t->nc) luaL_error(L, "this needs the interface, which is not running");
  return t;
}

/* ---- commands and keys ---- */

static int l_command_ui(lua_State *L) {
  const char *name = luaL_checkstring(L, 1);
  luaL_checktype(L, 2, LUA_TFUNCTION);
  const char *help = luaL_optstring(L, 3, "(defined in Lua)");
  luaL_argcheck(L, *name && !strchr(name, ' '), 1, "a command name is one word");
  lua_pushvalue(L, 2);
  command_register_lua(name, luaL_ref(L, LUA_REGISTRYINDEX), help);
  return 0;
}
ON_UI(l_command)

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
  char name[32];
  const char *target;
  if (lua_isfunction(L, 3)) {
    const char *help = luaL_optstring(L, 4, "(a Lua function)");
    snprintf(name, sizeof name, "lua.%d", ++anon);
    lua_pushvalue(L, 3);
    command_register_lua(name, luaL_ref(L, LUA_REGISTRYINDEX), help);
    target = name;
  } else {
    target = luaL_checkstring(L, 3);
  }
  if (keymap_bind(&tui_keymap, mask, keys, target))
    return luaL_error(L, "cannot parse the key sequence '%s'", keys);
  return 0;
}
ON_UI(l_map)

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
ON_UI(l_key)

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
    lua_rawseti(L, -2, ++n);
    sb_free(&k);
  }
  return 1;
}
ON_UI(l_maps)

/* lulibre._place_map(place, key, action): the binding of a key to an action
 * of a place that has keys of its own ("panel", "line", "picker", "pager",
 * "console"); false when there is no such place, so lulibre.map can look
 * elsewhere. */
static int l_place_map_ui(lua_State *L) {
  const char *place = luaL_checkstring(L, 1);
  if (ctx_named(place) < 0) {
    lua_pushboolean(L, 0);
    return 1;
  }
  char *err = NULL;
  if (ctx_bind(place, luaL_checkstring(L, 2), luaL_optstring(L, 3, ""), &err)) {
    lua_pushstring(L, err);
    free(err);
    return lua_error(L);
  }
  lua_pushboolean(L, 1);
  return 1;
}
ON_UI(l_place_map)

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
ON_UI(l_place_keys)

static int l_exec_ui(lua_State *L) {
  tui_exec(need_tui(L), luaL_checkstring(L, 1));
  return 0;
}
ON_UI(l_exec)

/* ---- the list ---- */

static int l_current_ui(lua_State *L) {
  struct tui *t = lapi_app(L)->tui;
  sqlite3_int64 id = t ? rows_current(t) : 0;
  if (id) lua_pushinteger(L, id);
  else lua_pushnil(L);
  return 1;
}
ON_UI(l_current)

/* With the cursor in a panel that follows the list (review, duplicates,
 * orphans), "the book under the cursor" is the one that panel's row stands
 * for. The list normally sits on the same book; when it cannot (the book was
 * removed, or the filter leaves it out) the list's own cursor is on some
 * other book, and acting on that one instead would be a nasty surprise. */
static void selection_under_panel(lua_State *L, struct tui *t) {
  sqlite3_int64 id;
  if (!t->focus || t->focus->cls != &view_panel || !panel_points_at(t->focus->state, &id)) return;
  if (id == rows_current(t) && id != 0) return;
  if (id == 0) {
    lua_pushliteral(L, "the row under the cursor is not a book: nothing is selected");
    lua_error(L);
  }
  if (rows_goto_id(t, id)) {
    preview_book_changed(t);
    return;
  }
  lua_pushfstring(L, "book %I is not in the list any more (removed, or the filter leaves it out): nothing is selected",
                  (lua_Integer)id);
  lua_error(L);
}

static int l_selection_ui(lua_State *L) {
  struct tui *t = lapi_app(L)->tui;
  lua_newtable(L);
  if (!t) return 1;
  int n;
  sqlite3_int64 *ids = rows_selection(t, &n);
  /* a range or marks say for themselves what is meant; the cursor alone does not */
  int by_cursor = t->mode != MODE_VISUAL && (n == 0 || (n == 1 && !rows_marked(t, ids[0])));
  if (by_cursor) {
    free(ids);
    selection_under_panel(L, t); /* raises, or leaves the list on the panel's book */
    ids = rows_selection(t, &n);
  }
  for (int i = 0; i < n; i++) {
    lua_pushinteger(L, ids[i]);
    lua_rawseti(L, -2, i + 1);
  }
  free(ids);
  return 1;
}
ON_UI(l_selection)

static int l_mark_ui(lua_State *L) {
  struct tui *t = need_tui(L);
  lua_Integer id = luaL_checkinteger(L, 1);
  rows_mark(t, id, lua_isnoneornil(L, 2) ? -1 : lua_toboolean(L, 2));
  return 0;
}
ON_UI(l_mark)

static int l_filter_ui(lua_State *L) {
  struct tui *t = need_tui(L);
  if (lua_isnoneornil(L, 1)) {
    lua_pushstring(L, t->rows.filter ? t->rows.filter : "");
    return 1;
  }
  rows_set_filter(t, luaL_checkstring(L, 1));
  return 0;
}
ON_UI(l_filter)

/* ---- pick ----
 * The picker lives on the interface thread and the waiting task on the Lua
 * thread: the picker is built over there, its answer is sent back here. */

struct pwait {
  struct app *app;
  struct task *task;
  struct tui *t;
  int items_ref;
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
  luaL_unref(app->L, LUA_REGISTRYINDEX, w->items_ref);
  free(w);
  free(d);
}

static void pick_finish(struct pwait *w, sqlite3_int64 index) {
  struct pdone *d = xcalloc(1, sizeof *d);
  d->w = w;
  d->index = index;
  bridge_lua(w->app, pick_done, d);
}

static void pick_accept(struct tui *t, sqlite3_int64 id, const char *text, void *ud) {
  pick_finish(ud, id);
}

static void pick_cancel(struct tui *t, void *ud) {
  pick_finish(ud, 0);
}

static void picker_close_ui(void *arg) {
  picker_close(arg); /* reports back through pick_cancel */
}

static void pick_task_cancelled(void *ud) {
  struct pwait *w = ud;
  bridge_ui(w->app, picker_close_ui, w->t);
}

/* items, options, the pwait */
static int pick_open_ui(lua_State *L) {
  struct tui *t = need_tui(L);
  struct pwait *w = lua_touserdata(L, 3);
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
  struct pwait *w = xcalloc(1, sizeof *w);
  w->app = lapi_app(L);
  lua_settop(L, 2);
  lua_pushvalue(L, 1);
  w->items_ref = luaL_ref(L, LUA_REGISTRYINDEX);
  lua_pushlightuserdata(L, w);
  /* waiting before the picker exists, so its answer cannot come too early */
  w->task = sched_begin_wait(L);
  sched_on_cancel(w->task, pick_task_cancelled, w);
  if (ui_pcall(L, pick_open_ui) != LUA_OK) {
    sched_abort_wait(w->task);
    luaL_unref(L, LUA_REGISTRYINDEX, w->items_ref);
    free(w);
    return lua_error(L);
  }
  return lua_yield(L, 0);
}

/* ---- input ---- */

struct iwait {
  struct app *app;
  struct task *task;
  struct tui *t;
  int change_ref; /* registry ref of on_change, or LUA_NOREF */
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
    luaL_unref(app->L, LUA_REGISTRYINDEX, w->change_ref);
    free(w);
  } else if (w->change_ref != LUA_NOREF) {
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
  bridge_lua(w->app, input_event, e);
}

static void input_answer(struct tui *t, const char *text, void *ud) {
  input_send(ud, text, 1);
}

static void input_changed(struct tui *t, const char *text, void *ud) {
  input_send(ud, text ? text : "", 0);
}

static void input_cancel_ui(void *arg) {
  tui_input_cancel(arg);
}

static void input_task_cancelled(void *ud) {
  struct iwait *w = ud;
  bridge_ui(w->app, input_cancel_ui, w->t);
}

/* the options table (or prompt string), the iwait */
static int input_open_ui(lua_State *L) {
  struct tui *t = need_tui(L);
  struct iwait *w = lua_touserdata(L, 2);
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
  struct iwait *w = xcalloc(1, sizeof *w);
  w->app = lapi_app(L);
  w->change_ref = LUA_NOREF;
  lua_settop(L, 1);
  if (lua_istable(L, 1)) {
    lua_getfield(L, 1, "on_change");
    if (lua_isfunction(L, -1)) w->change_ref = luaL_ref(L, LUA_REGISTRYINDEX);
    else lua_pop(L, 1);
  }
  lua_pushlightuserdata(L, w);
  w->task = sched_begin_wait(L);
  sched_on_cancel(w->task, input_task_cancelled, w);
  if (ui_pcall(L, input_open_ui) != LUA_OK) {
    sched_abort_wait(w->task);
    luaL_unref(L, LUA_REGISTRYINDEX, w->change_ref);
    free(w);
    return lua_error(L);
  }
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
ON_UI(l_clipboard)

static int l_progress_ui(lua_State *L) {
  struct app *app = lapi_app(L);
  const char *text = lua_isnoneornil(L, 1) ? NULL : luaL_tolstring(L, 1, NULL);
  if (app->tui && app->tui->nc) tui_progress(app->tui, text);
  return 0;
}
ON_UI(l_progress)

static int l_goto_ui(lua_State *L) {
  struct tui *t = need_tui(L);
  lua_Integer id = luaL_checkinteger(L, 1);
  int found = rows_goto_id(t, id);
  if (found) preview_book_changed(t);
  lua_pushboolean(L, found);
  return 1;
}
ON_UI(l_goto)

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
ON_UI(l_show)

/* ---- scripts ---- */

char **lapi_script_dirs(struct app *app) {
  char **dirs = xcalloc(4, sizeof *dirs);
  int n = 0;
  char *cfg = config_dir_path(&app->cfg);
  dirs[n++] = xasprintf("%s/scripts", cfg);
  free(cfg);
  char exe[4096];
  ssize_t len = readlink("/proc/self/exe", exe, sizeof exe - 1);
  if (len > 0) { /* running from a build tree: build/lulibre -> ./scripts */
    exe[len] = '\0';
    char *slash = strrchr(exe, '/');
    if (slash) {
      *slash = '\0';
      char *dev = xasprintf("%s/../scripts", exe);
      if (access(dev, R_OK) == 0) dirs[n++] = dev;
      else free(dev);
    }
  }
  dirs[n++] = xstrdup(LULIBRE_DATADIR "/scripts");
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

struct spawn_req {
  int ref;
  char *name, *arg;
};

static void spawn_ref(struct app *app, void *arg) {
  struct spawn_req *r = arg;
  lua_State *L = app->L;
  lua_rawgeti(L, LUA_REGISTRYINDEX, r->ref);
  lua_pushstring(L, r->arg);
  sched_spawn(L, 1, r->name);
  free(r->name);
  free(r->arg);
  free(r);
}

void lapi_spawn_ref(struct app *app, int ref, const char *name, const char *arg) {
  struct spawn_req *r = xcalloc(1, sizeof *r);
  r->ref = ref;
  r->name = xstrdup(name);
  r->arg = xstrdup(arg ? arg : "");
  bridge_lua(app, spawn_ref, r);
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
    bridge_lua(t->app, run_line, msg);
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

static void eval_line(struct app *app, void *arg) {
  lua_State *L = app->L;
  lua_getglobal(L, "lulibre");
  lua_getfield(L, -1, "_eval");
  lua_remove(L, -2);
  if (!lua_isfunction(L, -1)) {
    lua_pop(L, 1);
    lapi_report(app, 1, "the Lua runtime files were not found; :lua is unavailable");
  } else {
    lua_pushstring(L, arg);
    sched_spawn(L, 1, ":lua");
  }
  free(arg);
}

static void c_lua(struct tui *t, const char *args) {
  bridge_lua(t->app, eval_line, xstrdup(args));
}

/* ---- :reload-cfg : read init.lua again ----
 * Keys go back to the built-in ones first, so a binding taken out of
 * init.lua is gone; options keep their values unless init.lua sets them, and
 * what the command line set is applied on top again, as at start. */

static void keys_reset_ui(void *arg) {
  keymap_free(&tui_keymap);
  keymap_defaults(&tui_keymap);
  ctx_defaults();
}

static void cli_again_ui(void *arg) {
  struct app *app = arg;
  char *err = NULL;
  if (app_apply_cli(app, &err)) {
    lapi_report(app, 1, err);
    free(err);
  }
}

static void reload_cfg(struct app *app, void *arg) { /* Lua thread */
  char *path = arg;
  lua_State *L = app->L;
  bridge_ui(app, keys_reset_ui, NULL);
  lua_getglobal(L, "require");
  lua_pushliteral(L, "lulibre.ui.keys");
  if (lua_pcall(L, 1, 1, 0) == LUA_OK) {
    lua_getfield(L, -1, "reset");
    if (lua_pcall(L, 0, 0, 0) != LUA_OK) lua_pop(L, 1);
  }
  lua_pop(L, 1);
  if (luaL_dofile(L, path) != LUA_OK) {
    lapi_report(app, 1, lua_tostring(L, -1));
    lua_pop(L, 1);
  } else {
    char *msg = xasprintf("read %s again", path);
    lapi_report(app, 0, msg);
    free(msg);
  }
  bridge_ui(app, cli_again_ui, app);
  bridge_redraw(app);
  free(path);
}

static void c_reload_cfg(struct tui *t, const char *args) {
  char *dir = config_dir_path(&t->app->cfg);
  char *init = xasprintf("%s/init.lua", dir);
  free(dir);
  if (access(init, R_OK) != 0) {
    tui_msg(t, 1, "there is no %s to read (lulibre config --write makes one)", init);
    free(init);
    return;
  }
  bridge_lua(t->app, reload_cfg, init);
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

static void tasks_pager_ui(void *arg) {
  struct app *app = ((void **)arg)[0];
  if (app->tui && app->tui->nc) tui_pager(app->tui, "tasks", ((void **)arg)[1]);
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
  void *args[2] = {app, out.s};
  bridge_ui(app, tasks_pager_ui, args);
  sb_free(&out);
}

static void c_tasks(struct tui *t, const char *args) {
  bridge_lua(t->app, list_tasks, NULL);
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
  bridge_lua(t->app, cancel_tasks, xstrdup(args));
}

void l_ui_open(lua_State *L) {
  static const luaL_Reg fns[] = {
    {"notify", l_notify}, {"command", l_command}, {"map", l_map},
    {"exec", l_exec},     {"current", l_current}, {"selection", l_selection},
    {"mark", l_mark},     {"filter", l_filter},   {"pick", l_pick},
    {"input", l_input},   {"show", l_show},       {"progress", l_progress},
    {"jump", l_goto},     {"clipboard", l_clipboard}, {"log", l_log},
    {"key", l_key},       {"maps", l_maps},       {"_place_map", l_place_map},
    {"place_keys", l_place_keys}, {NULL, NULL},
  };
  luaL_setfuncs(L, fns, 0);
  lua_pushcfunction(L, l_print);
  lua_setglobal(L, "print");

  command_register("run", c_run, "[script [args]]  run a Lua script; no argument lists them");
  command_register("lua", c_lua, "code  run a line of Lua and show what it returns");
  command_register("reload-cfg", c_reload_cfg, "read init.lua again: keys are reset first, options it sets take effect");
  command_register("messages", c_messages, "the log so far, in a pager");
  command_register("console", c_console, "[focus]  show or hide the log console");
  command_register("tasks", c_tasks, "scripts that are running");
  command_register("cancel", c_cancel, "ID | all  stop a running script");
}
