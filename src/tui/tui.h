#ifndef LULIBRE_TUI_H
#define LULIBRE_TUI_H

#include <stdint.h>

#include <notcurses/notcurses.h>
#include <uv.h>

#include "app.h"
#include "core/util.h"
#include "db/query.h"
#include "index/indexer.h"

/* The interactive interface.
 *
 * Everything here runs on the loop thread. Nothing in this directory opens a
 * book file or runs a slow query directly: list queries go to a reader
 * connection on the thread pool (rows.c), page images are rendered on the
 * thread pool (view_preview.c), and both are dropped if the user has moved on
 * by the time they finish. A frame is drawn at most once per loop iteration,
 * and only when something called tui_dirty(). */

struct tui;

struct rect {
  int y, x, h, w;
};

/* ---------------------------------------------------------------- draw.c */

enum {
  A_BOLD = 1,
  A_ITALIC = 2,
  A_UNDERLINE = 4,
};
#define C_DEFAULT (-1)

struct theme {
  int dim, accent, warn, error, ok;
  int cursor_bg, cursor_bg_blur, visual_bg, mark, title;
  int border;            /* the line between windows side by side */
  int bar_bg, bar_fg;    /* a window's top line; the focused one is accent */
  int on_accent;         /* text drawn on the accent colour */
};
extern struct theme theme;
/* A colour by name ("border", "bar_bg", ...), or NULL. theme_name(i) lists
 * the names; NULL past the last. */
int *theme_slot(const char *name);
const char *theme_name(int i);
/* Fill a window's top line as its bar and leave that style set, so the
 * caller's text lands on it. */
void dr_bar(struct ncplane *n, struct rect r, int focused);

void dr_style(struct ncplane *n, int fg, int bg, unsigned attrs);
void dr_fill(struct ncplane *n, int y, int x, int w);
/* Draw at most maxw columns of s; too-long text ends in an ellipsis. Returns
 * the columns used. Control characters and invalid UTF-8 are replaced. */
int dr_text(struct ncplane *n, int y, int x, int maxw, const char *s);
int dr_textn(struct ncplane *n, int y, int x, int maxw, const char *s, size_t len);
int dr_width(const char *s, size_t len);
/* Bytes of the longest prefix of s that is at most cols columns wide. */
size_t dr_bytes_for_cols(const char *s, size_t len, int cols);
/* Bytes of s (up to len) that fit in maxw columns, breaking at a space when
 * one is available. Used for wrapping. */
size_t dr_wrap(const char *s, size_t len, int maxw);

/* --------------------------------------------------------------- keymap.c */

/* A key is a code point or NCKEY_* value, plus modifier bits. */
#define KEY_CTRL (1u << 30)
#define KEY_ALT (1u << 29)
/* <Leader> in a binding: whichever key the `leader` option names when the
 * key arrives, so changing the option moves every such binding at once */
#define KEY_LEADER (1u << 28)

enum mode {
  MODE_NORMAL = 1,
  MODE_VISUAL = 2,
  MODE_PROMPT = 4, /* the bottom line is taking text: ':' or '/' */
  MODE_PICKER = 8,
};

#define KEYSEQ_MAX 4

struct binding {
  unsigned modes;
  uint32_t keys[KEYSEQ_MAX];
  int nkeys;
  char *command;
};

struct keymap {
  struct binding *b;
  int n, cap;
  uint32_t leader; /* the key KEY_LEADER matches; 0 for none */
  uint32_t pending[KEYSEQ_MAX];
  int npending;
};

uint32_t key_from_input(const struct ncinput *ni);
/* "gg", "<C-w>v", "<Space>": returns the number of keys, 0 if unparseable */
int key_parse(const char *spec, uint32_t out[KEYSEQ_MAX]);
void key_format(sbuf *out, const uint32_t *keys, int n);
/* Add or replace a binding. modes is a bitmask of enum mode. */
int keymap_bind(struct keymap *km, unsigned modes, const char *spec, const char *command);
/* Feed one key. Returns a command to run, or NULL (pending or unbound). */
const char *keymap_feed(struct keymap *km, unsigned mode, uint32_t key);
/* Does a binding in this mode begin with key and run one of these commands
 * (first words, separated by spaces)? */
int keymap_starts(const struct keymap *km, unsigned mode, uint32_t key, const char *commands);
void keymap_free(struct keymap *km);
/* For a hint on screen: the keys the global keymap has for a command line
 * in normal mode, or ":command" when it has none. The text is good until
 * four more calls. */
const char *key_hint(const char *command);
/* Set what <Leader> stands for, from the option's text. */
void keymap_set_leader(struct keymap *km, const char *spec);
/* The keys a command line is bound to in this mode, written as a person
 * would type them into `out`; 0 when it has no binding. */
int keymap_key_of(const struct keymap *km, unsigned mode, const char *command, sbuf *out);
void keymap_defaults(struct keymap *km);
extern struct keymap tui_keymap;
/* Register the built-in commands and keys; safe to call more than once. */
void tui_setup(void);

/* -------------------------------------------------------------- cmdline.c */

struct lineedit {
  sbuf text;
  size_t cur; /* byte offset */
};

void le_set(struct lineedit *le, const char *s);
void le_insert(struct lineedit *le, const char *s, size_t n); /* at the cursor */
/* Returns 1 if the key edited or moved within the line, 0 if not handled. */
int le_key(struct lineedit *le, uint32_t key, const struct ncinput *ni);
void le_free(struct lineedit *le);

/* ----------------------------------------------------------------- rows.c */

/* The current list: the ids matching the filter, in order, plus cursor and
 * marks. Rows themselves are fetched from the index only when drawn. */
struct rows {
  sqlite3_int64 *ids;
  int n;
  int total;         /* how many the source holds, filter or no filter */
  int cur, top;
  int anchor; /* visual mode anchor row, -1 when not selecting */
  char *filter;
  int source;        /* 0: the calibre library; 1: the sync folder's staged files */
  char *error;       /* last filter error, shown in the status line */
  double took;       /* seconds the last query took */
  uint64_t gen;      /* bumped per request; stale results are dropped */
  int running, running_kind;
  struct lquery *queued[2]; /* newest list and search requests waiting their turn */
  char *search;             /* active search expression, NULL when none */
  char *search_error;
  unsigned char *hits;      /* bitmap by book id */
  sqlite3_int64 hits_cap;
  int nhits;                /* hits within the current list */
  uint64_t sgen;
  int search_origin;        /* row the search started from; -1 once it has landed */
  int search_live;          /* the search prompt is open */
  sqlite3_int64 want_id; /* book to put the cursor on when results land */
  unsigned char *marks;  /* bitmap by book id */
  sqlite3_int64 marks_cap;
  int nmarks;
};

void rows_init(struct tui *t);
void rows_free(struct tui *t);
/* Start (or restart) the list query; returns at once. */
void rows_set_filter(struct tui *t, const char *filter);
void rows_reload(struct tui *t);
/* Switch what the list shows: the library (0) or the sync folder (1). */
void rows_set_source(struct tui *t, int source);
sqlite3_int64 rows_current(const struct tui *t); /* 0 when the list is empty */
void rows_move(struct tui *t, int to);
int rows_goto_id(struct tui *t, sqlite3_int64 id); /* 1 if found */

/* Search marks matching books in the list without narrowing it. */
void rows_search(struct tui *t, const char *expr); /* NULL or "" clears */
void rows_search_begin(struct tui *t);
void rows_search_end(struct tui *t, const char *text, int accept);
void rows_search_next(struct tui *t, int dir);
int rows_hit(const struct tui *t, sqlite3_int64 id);

int rows_marked(const struct tui *t, sqlite3_int64 id);
void rows_mark(struct tui *t, sqlite3_int64 id, int on);
void rows_mark_all(struct tui *t, int how); /* 1 all in list, 0 none anywhere, -1 invert */
/* The books an action applies to: the visual range, else the marks that are
 * in the list, else the row under the cursor. Caller frees. */
sqlite3_int64 *rows_selection(const struct tui *t, int *n);

/* ------------------------------------------------------------------- wm.c */

struct view;

struct view_class {
  const char *name;
  void *(*create)(struct tui *t);
  void (*destroy)(struct tui *t, void *state);
  void (*draw)(struct tui *t, void *state, struct rect r, int focused);
  /* called when the view will not be drawn this frame (hidden or closed) */
  void (*hide)(struct tui *t, void *state);
};

struct node {
  char split; /* 0 leaf; 'v' side by side; 'h' stacked */
  float ratio;
  struct node *a, *b, *parent;
  const struct view_class *cls;
  void *state;
  struct rect r;
};

extern const struct view_class view_list, view_preview, view_panel, view_console;

void wm_init(struct tui *t);
void wm_free(struct tui *t);
void wm_layout(struct tui *t, struct rect area);
void wm_draw(struct tui *t);
int wm_split(struct tui *t, char dir, const char *view);
void wm_close(struct tui *t);
/* Close a given window; t->focus stays valid (see wm.c). */
void wm_close_leaf(struct tui *t, struct node *n);
void wm_only(struct tui *t);
void wm_focus_next(struct tui *t, int delta);
void wm_focus_dir(struct tui *t, char dir); /* h j k l */
void wm_resize(struct tui *t, int delta);
const struct view_class *wm_class(const char *name);
struct node *wm_dock(struct tui *t, const struct view_class *cls, void *state, float size, char side);
void wm_undock(struct tui *t, void *state);
/* Give the docked window showing this state that share of the screen. */
void wm_set_size(struct tui *t, void *state, float size);
/* Start an indexing run with these options and call done when it ends; if
 * one is already under way, done is called when that one ends instead.
 * Returns 0, or -1 with *err set. Interface thread. */
int tui_index(struct tui *t, const struct index_opts *o, void (*done)(const struct index_stats *st, void *ud),
              void *ud, char **err);
/* Every window, left to right and top to bottom; returns how many. */
int wm_leaves(struct tui *t, struct node **out, int max);
/* The window showing this state, or NULL. */
struct node *wm_leaf_of(struct tui *t, void *state);
/* The window at a screen position, or NULL. */
struct node *wm_at(struct tui *t, int y, int x);
/* First leaf showing this class, or NULL. */
struct node *wm_find(struct tui *t, const struct view_class *cls);

/* ----------------------------------------------------------- view_preview.c */

void preview_scroll(struct tui *t, int delta);
void preview_page(struct tui *t, int delta);
void preview_pan(struct tui *t, int delta);
void preview_zoom(struct tui *t, int delta); /* 0 resets */
void preview_toggle_graphic(struct tui *t);
/* The mouse in a text preview: what is 0 for a press at that cell, 1 while
 * dragging, 2 on release. Dragging selects text, a double click a word, a
 * triple click a line; what was selected is copied. Returns 1 while a drag
 * is under way. */
int preview_mouse(struct tui *t, void *state, int y, int x, int what);

/* clip.c: copy to, and paste from, the clipboard (tmux's inside tmux) */
int clip_copy(const char *s, size_t n);
char *clip_paste(void); /* malloc'd, or NULL when there is nothing */
void clip_free(void);
void preview_book_changed(struct tui *t);
int list_page_rows(struct tui *t); /* visible rows in the list view */

/* ------------------------------------------------------------ view_panel.c */

/* A table a script fills and steers: the edit form, proposal review and
 * pattern capture are all panels. It docks along the bottom, so the list
 * and preview stay in view, and with `follow` set moving through its rows
 * moves the list to the row's book. Movement keys are handled here; every
 * other key is handed to whoever is listening. */
struct panel;
/* HEAD and NOTE rows show their first cell across the whole width: a
 * heading, and text too long for a column. */
enum { PSTYLE_NORMAL, PSTYLE_DIM, PSTYLE_ACCENT, PSTYLE_OK, PSTYLE_WARN, PSTYLE_ERROR, PSTYLE_HEAD, PSTYLE_NOTE };
/* key is NULL when the panel has closed */
typedef void panel_event_fn(struct panel *p, const char *key, int row, void *ud);

/* side: 'b' along the bottom (size is a share of the height), 'l' down the
 * left (a share of the width). */
struct panel *panel_open(struct tui *t, float size, char side);
void panel_close(struct panel *p);  /* safe to call twice */
/* Take the panel off the screen without closing it, and put it back. A
 * script does this around a panel it opens on top of its own. */
void panel_hide(struct panel *p);
void panel_show(struct panel *p);
void panel_set_size(struct panel *p, float size);
/* Keys the script handles (panel_set_own) and the global commands, by first
 * word and separated by spaces, that its other keys may reach
 * (panel_set_pass): "preview yank" lets P and yy through. */
void panel_set_own(struct panel *p, int n, const uint32_t *keys);
void panel_set_pass(struct panel *p, const char *commands);
int panel_passes(const struct panel *p, uint32_t key);
void panel_unref(struct panel *p);  /* the opener's reference */
int panel_is_open(const struct panel *p);
void panel_on_event(struct panel *p, panel_event_fn *fn, void *ud);
void panel_set_title(struct panel *p, const char *title);
void panel_set_help(struct panel *p, const char *help);
void panel_set_follow(struct panel *p, int follow);
/* For a panel that follows: 1, and the book its cursor row stands for (0
 * when that row is not a book). 0 for a panel that does not follow. */
int panel_points_at(const struct panel *p, sqlite3_int64 *id);
/* Report cursor movement to the event function as the key "<Move>". */
void panel_set_moves(struct panel *p, int moves);
/* Report to the event function, as the key "<Reload>", that the library has
 * been read again (something changed it), so the rows can be brought up to
 * date. panels_reloaded tells every panel on screen that asked. */
void panel_set_reloads(struct panel *p, int reloads);
void panels_reloaded(struct tui *t);
/* width > 0: that many columns; width <= 0: a share of what is left */
void panel_set_columns(struct panel *p, int n, const char *const *titles, const int *widths);
void panel_clear_rows(struct panel *p);
void panel_add_row(struct panel *p, int ncells, const char *const *cells, sqlite3_int64 id,
                   int style);
int panel_cursor(const struct panel *p); /* 0-based; -1 when empty */
void panel_set_cursor(struct panel *p, int row);
/* Returns 1 if the key was the panel's. */
int panel_key(struct tui *t, struct panel *p, uint32_t key);
/* The mouse: a click on the panel's line `line` (0 is its bar), the wheel. */
void panel_click(struct panel *p, int line);
void panel_wheel(struct panel *p, int delta);

/* ---------------------------------------------------------------- picker.c */

struct picker;
typedef void picker_accept(struct tui *t, sqlite3_int64 id, const char *text, void *ud);

struct picker *picker_new(struct tui *t, const char *title, picker_accept *accept, void *ud);
/* text is copied; detail is a short right-aligned note, may be NULL */
void picker_add(struct picker *p, sqlite3_int64 id, const char *text, const char *detail);
/* Called if the picker closes without a choice. */
typedef void picker_cancel_fn(struct tui *t, void *ud);
void picker_on_cancel(struct picker *p, picker_cancel_fn *fn);
void picker_open(struct tui *t, struct picker *p);
void picker_close(struct tui *t);
void picker_key(struct tui *t, uint32_t key, const struct ncinput *ni);
void picker_draw(struct tui *t);

/* --------------------------------------------------------------- command.c */

typedef void command_fn(struct tui *t, const char *args);

void command_register(const char *name, command_fn *fn, const char *help);
/* A command implemented in Lua: ref is a registry reference to the function. */
void command_register_lua(const char *name, int ref, const char *help);
/* Run "name args". Unknown commands report in the message line. */
void tui_exec(struct tui *t, const char *line);
void commands_builtin(void);
void commands_free(void);
void command_help(struct tui *t);

/* ------------------------------------------------------------------ tui.c */

enum prompt_kind { PROMPT_NONE, PROMPT_COMMAND, PROMPT_FILTER, PROMPT_SEARCH, PROMPT_INPUT };
/* text is NULL when the prompt was cancelled */
typedef void input_fn(struct tui *t, const char *text, void *ud);

struct tui {
  struct app *app;
  struct db rdb; /* read-only connection used by the query worker */
  struct notcurses *nc;
  struct ncplane *std;
  int rows_n, cols_n; /* terminal size */

  uv_poll_t input;
  uv_prepare_t prepare;
  uv_timer_t tick;     /* periodic: has calibre's metadata.db changed? */
  uv_timer_t settle;   /* fires once the cursor has rested on a book */
  uv_timer_t ftimer;   /* live filter: runs shortly after the last keystroke */
  int settled;
  int dirty, quit;

  unsigned mode;
  struct keymap *km; /* the global keymap */
  struct node *root, *focus;
  struct rows rows;

  enum prompt_kind prompt;
  struct lineedit line;
  char *prompt_saved; /* filter to restore if the '/' prompt is cancelled */
  /* what was entered at the ':', '&' and '/' prompts, oldest first; kept
   * between sessions in the index's kv table */
  struct {
    char **v;
    int n;
  } hist[3];
  int hist_pos;
  char *hist_prefix; /* what was typed before Up was pressed; Up and Down look for it */
  char *comp_ctx;    /* what the completion candidates were built for (complete.c) */
  int sugg_prefix;   /* 0: fuzzy; 1: by prefix, once something is typed; 2: by prefix, all when nothing is */

  input_fn *input_cb; /* PROMPT_INPUT: who gets the answer */
  input_fn *input_change; /* optional: called after every edit of the line */
  void *input_ud;
  char *input_label;
  struct suggestion *sugg; /* completions offered under PROMPT_INPUT */
  int nsugg;
  char *sugg_sep;   /* values are lists separated by this; complete the last */
  int *sugg_order;  /* indexes of matching suggestions, best first */
  int nsugg_match, sugg_sel;
  char *progress;   /* a script's progress note for the status line */

  struct picker *picker;
  char *help; /* pager overlay text (help, messages, script output); NULL when closed */
  char *pager_title;
  int help_scroll;
  uint64_t errors_seen; /* log errors the console has shown (core/log.h) */
  void *drag;           /* the preview a mouse drag began in, while it lasts */
  sqlite3_int64 peek;   /* a book the preview shows instead of the list's: the one a
                         * following panel is on when the list does not hold it */
  /* whoever asked to be told when the indexing run ends (tui_index) */
  void (*ix_hook[8])(const struct index_stats *st, void *ud);
  void *ix_hook_ud[8];
  int nix_hook;
  int tab_x[3];         /* where the source tabs were drawn: columns of their edges */
  /* a terminal paste in progress (tui.c): keys held while they might be one
   * of its markers, and the text between the markers */
  struct ncinput held[6];
  int nheld, pasting;
  uv_timer_t held_timer;
  sbuf paste;

  char *msg;
  int msg_error;

  struct indexer *ix;
  int ix_done, ix_total, ix_failed;
};

int tui_run(struct app *app);
void tui_dirty(struct tui *t);
void tui_msg(struct tui *t, int error, const char *fmt, ...) PRINTF(3, 4);
void tui_prompt(struct tui *t, enum prompt_kind kind, const char *initial);
/* Ask for a line of text; cb gets the answer, or NULL if cancelled. */
void tui_input(struct tui *t, const char *label, const char *initial, input_fn *cb, void *ud);
void tui_input_cancel(struct tui *t); /* as if the user pressed Esc */
void tui_prompt_cancel(struct tui *t); /* the same for whatever the bottom line is taking */
/* Offer completions for the input prompt just opened. Texts are copied.
 * With sep set (" & " for authors), the value is a list and completion
 * applies to its last item. Tab takes the highlighted one. */
struct suggestion {
  char *text, *folded, *detail;
};
void tui_input_suggest(struct tui *t, int n, const char *const *texts,
                       const char *const *details, const char *sep);
void tui_input_on_change(struct tui *t, input_fn *fn);
/* complete.c: offer completions for the ':', '&' or '/' line as it stands */
void complete_refresh(struct tui *t);
const char *command_at(int i, const char **help); /* the i-th command's name; NULL past the last */
void tui_progress(struct tui *t, const char *text); /* NULL clears */
/* Show text in a scrollable overlay. */
void tui_pager(struct tui *t, const char *title, const char *text);
/* Put text on the message line without logging it (tui_msg logs first). */
void tui_show_msg(struct tui *t, int error, const char *text);
/* The console window (view_console.c): its keys when focused, the wheel. */
int console_key(struct tui *t, void *state, uint32_t key);
void console_wheel(void *state, int delta);
void tui_start_index(struct tui *t, int force);

#endif
