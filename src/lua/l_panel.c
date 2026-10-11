/* Panels: tables a script fills and steers. The edit form, proposal review
 * and pattern capture are Lua scripts built on this.
 *
 *   local p <close> = lulibre.panel{
 *     title = "review", help = "a accept  r reject  w write",
 *     columns = { {"Field", 12}, "Current", "Proposed", {"Source", 18} },
 *     rows = { {"authors", "Unknown", "E. Di Nardo", "title page", id = 1299, style = "ok"} },
 *     follow = true,      -- moving through rows moves the list to row.id
 *     height = 0.45,      -- share of the screen
 *     side = "left",      -- a column down the left instead (width = 0.28)
 *     moves = true,       -- wait() also returns "<Move>" when the cursor moves
 *   }
 *   while true do
 *     local key, row = p:wait()     -- nil once the panel is closed
 *     if not key then break end
 *     ...
 *     p:rows(new_rows)
 *   end
 *
 *   p:rows(rows)  p:title(s)  p:help(s)  p:cursor([row])  p:close()
 *
 * j k gg G and paging move within the panel; q and Esc close it; Tab, ':'
 * and <C-w> keep their usual meaning. Every other key is returned by wait()
 * in the notation key maps use ("a", "<CR>", "<Space>", "<C-x>").
 * A column is a title, or {title, width}: width in columns, or 0 or less
 * for a share of what is left. Row styles: dim accent ok warn error head. */
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
  if (lp->qn > 0 && !strcmp(key, "<Move>")) {
    int last = (lp->qhead + lp->qn - 1) % QUEUE;
    if (!strcmp(lp->q[last].key, "<Move>")) {
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
  static const char *const names[] = {"normal", "dim", "accent", "ok", "warn", "error", "head", NULL};
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
  char side = lua_isstring(L, -1) && lua_tostring(L, -1)[0] == 'l' ? 'l' : 'b';
  lua_getfield(L, 1, side == 'l' ? "width" : "height");
  float size = (float)luaL_optnumber(L, -1, side == 'l' ? 0.28 : 0.45);
  lua_pop(L, 2);

  struct lpanel **ud = lua_newuserdatauv(L, sizeof *ud, 0);
  *ud = NULL;
  luaL_setmetatable(L, MT);
  struct lpanel *lp = *ud = xcalloc(1, sizeof *lp);
  lp->app = lapi_app(L);
  lp->p = panel_open(t, size, side);
  panel_on_event(lp->p, on_event, lp);

  lua_getfield(L, 1, "title");
  if (lua_isstring(L, -1)) panel_set_title(lp->p, lua_tostring(L, -1));
  lua_getfield(L, 1, "help");
  if (lua_isstring(L, -1)) panel_set_help(lp->p, lua_tostring(L, -1));
  lua_getfield(L, 1, "follow");
  panel_set_follow(lp->p, lua_toboolean(L, -1));
  lua_getfield(L, 1, "moves");
  panel_set_moves(lp->p, lua_toboolean(L, -1));
  lua_pop(L, 4);
  lua_getfield(L, 1, "columns");
  if (lua_istable(L, -1)) set_columns(L, lp->p, -1);
  lua_pop(L, 1);
  lua_getfield(L, 1, "rows");
  if (lua_istable(L, -1)) set_rows(L, lp->p, -1);
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
