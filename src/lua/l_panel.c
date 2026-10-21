/* Panels: tables a script fills and steers. The edit form, proposal review
 * and pattern capture are Lua scripts built on this.
 *
 *   local p <close> = lulibre.panel{
 *     title = "review", help = "a accept  r reject  w write",
 *     columns = { {"Field", 12}, "Current", "Proposed", {"Source", 18} },
 *     rows = { {"authors", "Unknown", "E. Di Nardo", "title page", id = 1299, style = "ok"} },
 *     follow = true,      -- moving through rows moves the list to row.id
 *     preview = 12,       -- the preview shows this book while the panel is up,
 *                         -- or (a string) says that in place of a book
 *     height = 0.45,      -- share of the screen
 *     side = "left",      -- a column down the left instead (width = 0.28);
 *                         -- "main": in the list's window, which comes back when
 *                         -- the panel closes (the focus stays where it was)
 *     focus = false,      -- leave the focus where it is (a panel takes it otherwise)
 *     screen_tab = true,  -- the panel is the bar's Configuration tab while open
 *     moves = true,       -- wait() also returns "<Move>" when the cursor moves
 *     dialog = true,      -- Esc closes it, as q does (a form that asks
 *                         -- something); in other panels Esc goes back to
 *                         -- the window and leaves the panel open
 *     reloads = true,     -- and "<Reload>" when the library has been read again
 *     tabs = { "this run (9)", "all waiting (212)" }, tab = 1,
 *                         -- names in the bar, one of them as the one in view
 *     keys = { "a", "r", "<CR>" },   -- the keys this script handles, and
 *     pass = "preview yank",         -- the global commands its other keys may
 *                                    -- still reach (P, ], yy ...); see below
 *   }
 *   while true do
 *     local key, row = p:wait()     -- nil once the panel is closed
 *     if not key then break end
 *     ...
 *     p:rows(new_rows)
 *   end
 *
 *   p:rows(rows)  p:title(s)  p:help(s)  p:cursor([row])  p:close()
 *   p:preview(id | text | nil)   what the preview shows while it is up; nil
 *                          gives it back to the rows (or the list)
 *   p:hide()  p:show()     off the screen and back, without closing: around a
 *                          panel opened on top of this one
 *   p:height(share)        resize (a share of the screen, 0.1 to 0.9)
 *   p:keys(list)           say again which keys are handled
 *   p:tabs(names, current) the names in the bar and which is in view. The
 *                          panel only draws them: the script switches, on
 *                          keys of its choosing, and wait() returns "<Tab>"
 *                          and the tab's number when one is clicked
 *   p:send(key [, row])    make wait() return key, from another task: how a
 *                          script that is not the panel's own tells it that
 *                          something it shows has changed
 *
 * j k gg G and paging move within the panel; q and Esc close it; Tab, ':'
 * and <C-w> keep their usual meaning. Every other key is returned by wait()
 * in the notation key maps use ("a", "<CR>", "<Space>", "<C-x>"), unless
 * the panel was given `keys` and `pass`: then a key not among `keys` that
 * begins a global binding to one of the `pass` commands runs that binding,
 * so the preview can be paged or shown as an image from inside the panel.
 * A column is a title, or {title, width}: width in columns, or 0 or less
 * for a share of what is left. Row styles: dim accent ok warn error, and
 * head and note, whose first cell is shown across the whole width. */
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <lua.h>
#include <lauxlib.h>

#include "app.h"
#include "core/util.h"
#include "lua/bridge.h"
#include "lua/lapi.h"
#include "lua/sched.h"
#include "tui/tui.h"

#define MT "lulibre.panel"
#define QUEUE 16

/* The panel itself belongs to the interface thread; this, the script's side
 * of it, to the Lua thread. Keys travel from one to the other as messages.
 * It is allocated apart from the Lua object so that a key still on its way
 * when the object is collected has somewhere to land. */
struct lpanel {
  struct app *app;
  struct panel *p; /* NULL once closed from Lua */
  struct task *waiter;
  struct {
    char key[32];
    int row;
  } q[QUEUE];
  int qhead, qn;
  int closed;
  int dead;            /* the Lua object is gone */
  atomic_int inflight; /* keys sent and not yet delivered */
};

struct pevent {
  struct lpanel *lp;
  int has_key, row;
  char key[32];
};

static void deliver(struct app *app, void *arg) { /* Lua thread */
  struct pevent *e = arg;
  struct lpanel *lp = e->lp;
  char keybuf[32];
  memcpy(keybuf, e->key, sizeof keybuf);
  const char *key = e->has_key ? keybuf : NULL;
  int row = e->row, left = atomic_fetch_sub(&lp->inflight, 1) - 1;
  free(e);
  if (lp->dead) {
    if (left == 0) free(lp);
    return;
  }
  if (!key) lp->closed = 1;
  if (lp->waiter) {
    struct task *t = lp->waiter;
    lp->waiter = NULL;
    lua_State *L = sched_end_wait(t);
    if (!L) return;
    if (key) {
      lua_pushstring(L, key);
      lua_pushinteger(L, row + 1);
      sched_wake(t, 2);
    } else {
      lua_pushnil(L);
      sched_wake(t, 1);
    }
    return;
  }
  if (!key) return;
  /* nobody is waiting (the script is busy): keep the key for the next wait().
   * A run of cursor movements is worth only its last position. */
  if (lp->qn > 0 && (!strcmp(key, "<Move>") || !strcmp(key, "<Reload>"))) {
    int last = (lp->qhead + lp->qn - 1) % QUEUE;
    if (!strcmp(lp->q[last].key, key)) {
      lp->q[last].row = row;
      return;
    }
  }
  if (lp->qn == QUEUE) {
    lp->qhead = (lp->qhead + 1) % QUEUE;
    lp->qn--;
  }
  int slot = (lp->qhead + lp->qn++) % QUEUE;
  snprintf(lp->q[slot].key, sizeof lp->q[slot].key, "%s", key);
  lp->q[slot].row = row;
}

/* interface thread: a key the panel does not handle itself, or NULL when the
 * panel has closed */
static void on_event(struct panel *p, const char *key, int row, void *ud) {
  struct lpanel *lp = ud;
  struct pevent *e = xcalloc(1, sizeof *e);
  e->lp = lp;
  e->row = row;
  if (key) {
    e->has_key = 1;
    snprintf(e->key, sizeof e->key, "%s", key);
  }
  atomic_fetch_add(&lp->inflight, 1);
  bridge_lua(lp->app, deliver, e);
}

static struct lpanel *check(lua_State *L) {
  struct lpanel **ud = luaL_checkudata(L, 1, MT);
  if (!*ud) luaL_error(L, "this panel is gone");
  return *ud;
}

static int style_of(lua_State *L, int idx) {
  static const char *const names[] = {"normal", "dim", "accent", "ok", "warn", "error", "head", "note", NULL};
  lua_getfield(L, idx, "style");
  int style = PSTYLE_NORMAL;
  if (lua_isstring(L, -1)) {
    const char *s = lua_tostring(L, -1);
    for (int i = 0; names[i]; i++)
      if (!strcmp(names[i], s)) style = i;
  }
  lua_pop(L, 1);
  return style;
}

/* rows table at idx -> the panel */
static void set_rows(lua_State *L, struct panel *p, int idx) {
  idx = lua_absindex(L, idx);
  luaL_checkstack(L, 80, "panel row");
  panel_clear_rows(p);
  lua_Integer n = (lua_Integer)lua_rawlen(L, idx);
  for (lua_Integer i = 1; i <= n; i++) {
    lua_rawgeti(L, idx, i);
    int row = lua_gettop(L);
    const char *cells[32];
    int nc = 0;
    if (lua_istable(L, row)) {
      lua_Integer m = (lua_Integer)lua_rawlen(L, row);
      for (lua_Integer c = 1; c <= m && nc < 32; c++) {
        lua_rawgeti(L, row, c);
        cells[nc++] = luaL_tolstring(L, -1, NULL); /* stays on the stack until added */
      }
      lua_getfield(L, row, "id");
      sqlite3_int64 id = lua_tointeger(L, -1);
      lua_pop(L, 1);
      panel_add_row(p, nc, cells, id, style_of(L, row));
    } else {
      cells[nc++] = luaL_tolstring(L, row, NULL);
      panel_add_row(p, nc, cells, 0, PSTYLE_NORMAL);
    }
    lua_settop(L, row - 1);
  }
}

/* a list of key names at idx -> the keys the script calls its own */
static void set_tabs(lua_State *L, struct panel *p, int idx, int current) {
  const char *names[PANEL_TABS];
  idx = lua_absindex(L, idx);
  int n = (int)lua_rawlen(L, idx);
  if (n > PANEL_TABS) n = PANEL_TABS;
  for (int i = 0; i < n; i++) {
    lua_rawgeti(L, idx, i + 1);
    names[i] = luaL_tolstring(L, -1, NULL); /* stays on the stack until set */
    lua_remove(L, -2);
  }
  panel_set_tabs(p, n, names, current);
  lua_pop(L, n);
}

static void set_own(lua_State *L, struct panel *p, int idx) {
  idx = lua_absindex(L, idx);
  uint32_t keys[128];
  int n = 0;
  lua_Integer m = (lua_Integer)lua_rawlen(L, idx);
  for (lua_Integer i = 1; i <= m && n < 128; i++) {
    lua_rawgeti(L, idx, i);
    uint32_t seq[KEYSEQ_MAX];
    const char *spec = lua_tostring(L, -1);
    if (spec && key_parse(spec, seq) == 1) keys[n++] = seq[0];
    lua_pop(L, 1);
  }
  panel_set_own(p, n, keys);
}

static void set_columns(lua_State *L, struct panel *p, int idx) {
  idx = lua_absindex(L, idx);
  const char *titles[32];
  int widths[32], n = 0;
  lua_Integer m = (lua_Integer)lua_rawlen(L, idx);
  int base = lua_gettop(L);
  for (lua_Integer i = 1; i <= m && n < 32; i++) {
    lua_rawgeti(L, idx, i);
    widths[n] = 0;
    if (lua_istable(L, -1)) {
      lua_rawgeti(L, -1, 1);
      titles[n] = lua_tostring(L, -1);
      lua_rawgeti(L, -2, 2);
      widths[n] = (int)lua_tointeger(L, -1);
      lua_pop(L, 1);
    } else {
      titles[n] = lua_tostring(L, -1);
    }
    if (!titles[n]) titles[n] = "";
    n++;
  }
  panel_set_columns(p, n, titles, widths);
  lua_settop(L, base);
}

static int l_panel_ui(lua_State *L) {
  struct tui *t = lapi_app(L)->tui;
  if (!t || !t->nc) return luaL_error(L, "panels need the interface, which is not running");
  luaL_checktype(L, 1, LUA_TTABLE);
  lua_getfield(L, 1, "side");
  char side = !lua_isstring(L, -1) ? 'b' : lua_tostring(L, -1)[0] == 'l' ? 'l' : lua_tostring(L, -1)[0] == 'm' ? 'm' : 'b';
  lua_getfield(L, 1, side == 'l' ? "width" : "height");
  float size = (float)luaL_optnumber(L, -1, side == 'l' ? 0.28 : 0.45);
  lua_pop(L, 2);

  struct lpanel **ud = lua_newuserdatauv(L, sizeof *ud, 0);
  *ud = NULL;
  luaL_setmetatable(L, MT);
  struct lpanel *lp = *ud = xcalloc(1, sizeof *lp);
  lp->app = lapi_app(L);
  lua_getfield(L, 1, "focus");
  int keep_focus = lua_isboolean(L, -1) && !lua_toboolean(L, -1);
  lua_getfield(L, 1, "screen_tab");
  int screen_tab = lua_toboolean(L, -1);
  lua_pop(L, 2);
  struct node *was = t->focus;
  lp->p = panel_open(t, size, side);
  if (keep_focus && was) t->focus = was;
  panel_on_event(lp->p, on_event, lp);
  if (screen_tab) panel_set_screen_tab(lp->p);

  lua_getfield(L, 1, "title");
  if (lua_isstring(L, -1)) panel_set_title(lp->p, lua_tostring(L, -1));
  lua_getfield(L, 1, "help");
  if (lua_isstring(L, -1)) panel_set_help(lp->p, lua_tostring(L, -1));
  lua_getfield(L, 1, "follow");
  panel_set_follow(lp->p, lua_toboolean(L, -1));
  lua_getfield(L, 1, "moves");
  panel_set_moves(lp->p, lua_toboolean(L, -1));
  lua_getfield(L, 1, "dialog");
  panel_set_dialog(lp->p, lua_toboolean(L, -1));
  lua_getfield(L, 1, "reloads");
  panel_set_reloads(lp->p, lua_toboolean(L, -1));
  lua_pop(L, 2);
  lua_getfield(L, 1, "pass");
  if (lua_isstring(L, -1)) panel_set_pass(lp->p, lua_tostring(L, -1));
  lua_getfield(L, 1, "keys");
  if (lua_istable(L, -1)) set_own(L, lp->p, -1);
  lua_pop(L, 6);
  lua_getfield(L, 1, "columns");
  if (lua_istable(L, -1)) set_columns(L, lp->p, -1);
  lua_pop(L, 1);
  lua_getfield(L, 1, "tab");
  int tab = (int)luaL_optinteger(L, -1, 1) - 1;
  lua_getfield(L, 1, "tabs");
  if (lua_istable(L, -1)) set_tabs(L, lp->p, -1, tab);
  lua_pop(L, 2);
  lua_getfield(L, 1, "rows");
  if (lua_istable(L, -1)) set_rows(L, lp->p, -1);
  lua_pop(L, 1);
  lua_getfield(L, 1, "preview");
  if (lua_isinteger(L, -1)) panel_set_preview(lp->p, 1, lua_tointeger(L, -1), NULL);
  else if (lua_type(L, -1) == LUA_TSTRING) panel_set_preview(lp->p, 1, 0, lua_tostring(L, -1));
  lua_pop(L, 1);
  panel_set_cursor(lp->p, 0);
  return 1;
}

/* The methods that touch the panel run on the interface thread. */
#define ON_UI(name) \
  static int name(lua_State *L) { return ui_call(L, name##_ui); }
ON_UI(l_panel)

static int m_rows_ui(lua_State *L) {
  struct lpanel *lp = check(L);
  luaL_checktype(L, 2, LUA_TTABLE);
  if (lp->p && !lp->closed) {
    int cur = panel_cursor(lp->p);
    set_rows(L, lp->p, 2);
    panel_set_cursor(lp->p, cur < 0 ? 0 : cur);
  }
  return 0;
}
ON_UI(m_rows)

static int m_title_ui(lua_State *L) {
  struct lpanel *lp = check(L);
  if (lp->p && !lp->closed) panel_set_title(lp->p, luaL_checkstring(L, 2));
  return 0;
}
ON_UI(m_title)

static int m_help_ui(lua_State *L) {
  struct lpanel *lp = check(L);
  if (lp->p && !lp->closed) panel_set_help(lp->p, luaL_checkstring(L, 2));
  return 0;
}
ON_UI(m_help)

static int m_columns_ui(lua_State *L) {
  struct lpanel *lp = check(L);
  luaL_checktype(L, 2, LUA_TTABLE);
  if (lp->p && !lp->closed) set_columns(L, lp->p, 2);
  return 0;
}
ON_UI(m_columns)

static int m_cursor_ui(lua_State *L) {
  struct lpanel *lp = check(L);
  if (!lp->p || lp->closed) return 0;
  if (!lua_isnoneornil(L, 2)) panel_set_cursor(lp->p, (int)luaL_checkinteger(L, 2) - 1);
  int cur = panel_cursor(lp->p);
  if (cur < 0) lua_pushnil(L);
  else lua_pushinteger(L, cur + 1);
  return 1;
}
ON_UI(m_cursor)

static int m_hide_ui(lua_State *L) {
  struct lpanel *lp = check(L);
  if (lp->p && !lp->closed) panel_hide(lp->p);
  return 0;
}
ON_UI(m_hide)

static int m_preview_ui(lua_State *L) {
  struct lpanel *lp = check(L);
  if (lp->p && !lp->closed) {
    if (lua_isinteger(L, 2)) panel_set_preview(lp->p, 1, lua_tointeger(L, 2), NULL);
    else if (lua_type(L, 2) == LUA_TSTRING) panel_set_preview(lp->p, 1, 0, lua_tostring(L, 2));
    else panel_set_preview(lp->p, 0, 0, NULL);
  }
  return 0;
}
ON_UI(m_preview)

static int m_show_ui(lua_State *L) {
  struct lpanel *lp = check(L);
  if (lp->p && !lp->closed) panel_show(lp->p);
  return 0;
}
ON_UI(m_show)

static int m_height_ui(lua_State *L) {
  struct lpanel *lp = check(L);
  if (lp->p && !lp->closed) panel_set_size(lp->p, (float)luaL_checknumber(L, 2));
  return 0;
}
ON_UI(m_height)

static int m_keys_ui(lua_State *L) {
  struct lpanel *lp = check(L);
  luaL_checktype(L, 2, LUA_TTABLE);
  if (lp->p && !lp->closed) set_own(L, lp->p, 2);
  return 0;
}
ON_UI(m_keys)

static int m_tabs_ui(lua_State *L) {
  struct lpanel *lp = check(L);
  luaL_checktype(L, 2, LUA_TTABLE);
  if (lp->p && !lp->closed) set_tabs(L, lp->p, 2, (int)luaL_optinteger(L, 3, 1) - 1);
  return 0;
}
ON_UI(m_tabs)

/* Lua thread: a key from another task, as if the panel had sent it */
static int m_send(lua_State *L) {
  struct lpanel *lp = check(L);
  const char *key = luaL_checkstring(L, 2);
  int row = (int)luaL_optinteger(L, 3, 1) - 1;
  if (lp->closed || !lp->p) return 0;
  struct pevent *e = xcalloc(1, sizeof *e);
  e->lp = lp;
  e->row = row;
  e->has_key = 1;
  snprintf(e->key, sizeof e->key, "%s", key);
  atomic_fetch_add(&lp->inflight, 1);
  deliver(lp->app, e);
  return 0;
}

static void close_ui(void *arg) {
  struct panel *p = arg;
  if (panel_is_open(p)) panel_close(p); /* reports back through on_event */
}

static void wait_cancelled(void *ud) {
  struct lpanel *lp = ud;
  if (lp->p) bridge_ui(lp->app, close_ui, lp->p);
}

static int m_wait(lua_State *L) {
  struct lpanel *lp = check(L);
  if (lp->qn > 0) {
    lua_pushstring(L, lp->q[lp->qhead].key);
    lua_pushinteger(L, lp->q[lp->qhead].row + 1);
    lp->qhead = (lp->qhead + 1) % QUEUE;
    lp->qn--;
    return 2;
  }
  if (lp->closed || !lp->p) {
    lua_pushnil(L);
    return 1;
  }
  lp->waiter = sched_begin_wait(L);
  sched_on_cancel(lp->waiter, wait_cancelled, lp);
  return lua_yield(L, 0);
}

static void release_ui(void *arg) {
  struct panel *p = arg;
  if (panel_is_open(p)) panel_close(p); /* a waiter is woken with nil */
  panel_on_event(p, NULL, NULL);        /* no key is sent after this */
  panel_unref(p);
}

static void release(struct lpanel *lp) {
  if (!lp->p) return;
  struct panel *p = lp->p;
  lp->p = NULL;
  lp->closed = 1;
  bridge_ui(lp->app, release_ui, p);
}

static int m_close(lua_State *L) {
  struct lpanel **ud = luaL_checkudata(L, 1, MT);
  if (*ud) release(*ud);
  return 0;
}

static int m_gc(lua_State *L) {
  struct lpanel **ud = luaL_checkudata(L, 1, MT);
  struct lpanel *lp = *ud;
  if (!lp) return 0;
  *ud = NULL;
  release(lp);
  lp->dead = 1;
  if (atomic_load(&lp->inflight) == 0) free(lp); /* else when the last key lands */
  return 0;
}

static int m_is_open(lua_State *L) {
  struct lpanel *lp = check(L);
  lua_pushboolean(L, lp->p && !lp->closed);
  return 1;
}

void l_panel_open(lua_State *L) {
  static const luaL_Reg methods[] = {
    {"rows", m_rows},     {"title", m_title}, {"help", m_help},   {"columns", m_columns},
    {"cursor", m_cursor}, {"wait", m_wait},   {"close", m_close}, {"is_open", m_is_open},
    {"hide", m_hide},     {"show", m_show},   {"preview", m_preview},   {"height", m_height}, {"keys", m_keys},
    {"tabs", m_tabs},     {"send", m_send},
    {"__gc", m_gc},      {"__close", m_close}, {NULL, NULL},
  };
  luaL_newmetatable(L, MT);
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");
  luaL_setfuncs(L, methods, 0);
  lua_pop(L, 1);
  lua_pushcfunction(L, l_panel);
  lua_setfield(L, -2, "panel");
}
