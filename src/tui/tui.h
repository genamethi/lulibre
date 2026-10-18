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
/* Shift, kept only for keys it does not change the character of (<S-Tab>) */
#define KEY_SHIFT (1u << 27)

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
  char *about; /* what the help overlay says the key does, when given; else the command */
  int hidden;  /* left out of the help overlay */
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
/* Add or replace a binding. modes is a bitmask of enum mode; about is what
 * the help overlay is to say of it (NULL: the command itself), or hidden
 * from it. */
int keymap_bind_as(struct keymap *km, unsigned modes, const char *spec, const char *command, const char *about,
                   int hidden);
/* Feed one key. Returns a command to run, or NULL (pending or unbound). */
const char *keymap_feed(struct keymap *km, unsigned mode, uint32_t key);
/* Does a binding in this mode begin with key and run one of these commands
 * (first words, separated by spaces)? */
int keymap_starts(const struct keymap *km, unsigned mode, uint32_t key, const char *commands);
void keymap_free(struct keymap *km);
/* For a hint on screen: the keys the global keymap has for a command line
 * in normal mode, or ":command" when it has none. The text is good until
 * four more calls. */
/* The key a command is on, for a hint (":command" when it is on none), in a
 * buffer of the caller's: key_hint() gives each call its own, which lives
 * until the end of the statement or block it is written in. */
#define KEY_HINT_MAX 48
const char *key_hint_in(char *buf, size_t size, const char *command);
#define key_hint(command) key_hint_in((char[KEY_HINT_MAX]){0}, KEY_HINT_MAX, (command))
/* Set what <Leader> stands for, from the option's text. */
void keymap_set_leader(struct keymap *km, const char *spec);
/* The keys a command line is bound to in this mode, written as a person
 * would type them into `out`; 0 when it has no binding. */
int keymap_key_of(const struct keymap *km, unsigned mode, const char *command, sbuf *out);
void keymap_defaults(struct keymap *km);
extern struct keymap tui_keymap;
/* Register the built-in commands and keys; safe to call more than once. */
void tui_setup(void);

/* -------------------------------------------------------------- ctxkeys.c */

/* Keys that belong to a place: each place has named actions, and its code
 * asks which action a key means. The numbers follow the tables in ctxkeys.c. */
enum { KC_PANEL, KC_LINE, KC_PICKER, KC_PAGER, KC_CONSOLE, KC_SELECT, KC_N };
enum { SA_LEFT = 1, SA_RIGHT, SA_UP, SA_DOWN, SA_WORD, SA_BACK, SA_START, SA_END, SA_TOP, SA_BOTTOM, SA_MARK, SA_LINE,
       SA_COPY, SA_LEAVE };
enum { PA_DOWN = 1, PA_UP, PA_TOP, PA_BOTTOM, PA_HALF_DOWN, PA_HALF_UP, PA_PAGE_DOWN, PA_PAGE_UP, PA_CLOSE, PA_BACK };
enum { LA_ACCEPT = 1, LA_CANCEL, LA_PASTE, LA_COPY, LA_COMPLETE, LA_NEXT, LA_PREV, LA_UP, LA_DOWN,
       LA_PREVIEW_UP, LA_PREVIEW_DOWN, LA_LEFT, LA_RIGHT, LA_HOME, LA_END, LA_BACKSPACE, LA_DELETE,
       LA_KILL_START, LA_KILL_END, LA_KILL_WORD };
enum { KA_ACCEPT = 1, KA_CANCEL, KA_DOWN, KA_UP, KA_PAGE_DOWN, KA_PAGE_UP };
enum { GA_DOWN = 1, GA_UP, GA_PAGE_DOWN, GA_PAGE_UP, GA_TOP };
enum { CA_UP = 1, CA_DOWN, CA_HALF_UP, CA_HALF_DOWN, CA_TOP, CA_FOLLOW, CA_ERRORS, CA_WARNINGS, CA_NOTICES,
       CA_EVERYTHING, CA_CLEAR, CA_CLOSE };
#define CTX_PENDING (-1) /* the key may be the first of two: wait for the next */

void ctx_defaults(void);
void ctx_free(void);
int ctx_named(const char *name); /* a place's number, or -1 */
/* Put a key (one, or two in a row) on an action; an empty action unbinds. */
int ctx_bind(const char *ctx, const char *spec, const char *action, char **err);
/* The action a key means: 0 for none, CTX_PENDING while a pair is open.
 * pending holds the first key of a pair between calls; NULL where pairs are
 * not wanted. */
int ctx_feed(int ctx, uint32_t *pending, uint32_t key);
int ctx_bound(int ctx, uint32_t key); /* does any binding there begin with it? */
/* A place's key for an action, for a hint ("" when unbound); like key_hint,
 * each ctx_hint() has a buffer of its own. */
const char *ctx_hint_in(char *buf, size_t size, int ctx, int action);
#define ctx_hint(ctx, action) ctx_hint_in((char[KEY_HINT_MAX]){0}, KEY_HINT_MAX, (ctx), (action))
void ctx_describe(int ctx, sbuf *out, int names);

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
/* A heading of a grouped list: an author, a series, a subject (subjects
 * nest: "math/number-theory" is under "math") with the books under it. */
struct ghead {
  char *path;        /* what it is known by: "math/number-theory" */
  char *label;       /* its last part, as shown */
  char *sortkey;
  int depth, parent; /* parent: a heading's number, -1 at the top */
  int count;         /* books under it, those of the headings within it included */
  int *books;        /* those books, as rows of rows.all, in the list's order */
  int nbooks, bcap;
  int *direct;       /* the books that stand right under it */
  int ndirect, dcap;
  int *kids;         /* the headings within it */
  int nkids, kcap;
  int open, last, seen;
};

struct rows {
  /* What the list draws. Without a grouping these are the books the filter
   * matched; with one, headings stand among them, as rows whose id is 0. */
  sqlite3_int64 *ids;
  int n;
  sqlite3_int64 *all; /* the books the filter matched, in its order */
  int nall;
  char *group;        /* what the list is grouped by, NULL when it is not */
  int group_by_count; /* headings in order of size, not of name */
  struct ghead *heads;
  int nheads;
  int *head_of;       /* per drawn row: the heading it is, or is under (-1: none) */
  char **opened;      /* headings opened ("+grouping\tpath") and closed ("-...") by hand */
  int nopened;
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
/* The book under the cursor; on a heading, the first book under it. 0 when
 * the list is empty. */
sqlite3_int64 rows_current(const struct tui *t);
/* Group the list: by author, subject, series, publisher, year, format or
 * folder (the folders of the calibre library); NULL or "none" for the plain
 * list. by_count orders the headings by size. Returns 0, or -1 for a
 * grouping there is not. */
int rows_set_group(struct tui *t, const char *by, int by_count);
extern const char *const rows_groupings[]; /* their names, NULL at the end */
/* The heading at a drawn row, or NULL when the row is a book. */
const struct ghead *rows_head(const struct tui *t, int row);
/* How deep a drawn row stands under headings: 0 in a plain list. */
int rows_depth(const struct tui *t, int row);
/* Open and close headings. how: 't' toggle, 'o' open, 'c' close the one at
 * the cursor (on a book, 'c' closes the heading it is under); 'O' open all,
 * 'C' close all. */
void rows_fold(struct tui *t, int how);
/* Put the cursor on a book, opening the headings it is under if need be. */
int rows_reveal(struct tui *t, sqlite3_int64 id);
/* group.c: build what is drawn from rows.all and the grouping */
void rows_regroup(struct tui *t);
void rows_group_free(struct rows *r);
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
  /* a view put over this window's own for a while (wm_over_list): the own
   * one waits here and comes back when the other is undocked */
  const struct view_class *under_cls;
  void *under_state;
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
/* the windows: the list, the previews, the console; panels are passed over */
void wm_focus_next(struct tui *t, int delta);
void wm_focus_dir(struct tui *t, char dir); /* h j k l */
/* the panels: from a window, the one last in; from a panel, the next */
void wm_focus_panel(struct tui *t, int delta);
/* from a panel, back to the window it was reached from */
void wm_focus_back(struct tui *t);
/* note which window or panel has the focus (render does, once a frame) */
void wm_note_focus(struct tui *t);
void wm_resize(struct tui *t, int delta);
/* Move the line between the focused window and its neighbour: dir is h j k l
 * (left, down, up, right), cells how far. */
void wm_resize_dir(struct tui *t, char dir, int cells);
/* The line between two windows at a screen position: 'v' for the rule
 * between windows side by side, 'h' for the bar of a window with another
 * above it, 0 for neither. wm_divider_drag moves the one at (*y, *x) towards
 * the pointer, sets them to where it now is, and returns 0 when there is no
 * line there any more. */
char wm_divider_at(struct tui *t, int y, int x);
int wm_divider_drag(struct tui *t, int *y, int *x, int to_y, int to_x);
struct node *wm_dock(struct tui *t, const struct view_class *cls, void *state, float size, char side);
/* Show a view in the list's window for a while, the list kept aside until
 * it is undocked; the focus stays where it is. Docks on the left when there
 * is no list window. */
struct node *wm_over_list(struct tui *t, const struct view_class *cls, void *state);
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
/* Where the preview is: its book, the page shown and how many pages of the
 * file have been read. 0 when there is no preview, or no file in it. */
int preview_position(struct tui *t, sqlite3_int64 *book, int *page, int *indexed);
/* The mouse in a text preview: what is 0 for a press at that cell, 1 while
 * dragging, 2 on release. Dragging selects text, a double click a word, a
 * triple click a line; what was selected is copied. Returns 1 while a drag
 * is under way. */
int preview_mouse(struct tui *t, void *state, int y, int x, int what);

int preview_has_selection(void *state);
/* Selecting text with the keys: preview_select puts a cursor in the page's
 * text and takes the focus there; while preview_selecting, preview_select_key
 * is given each key first and returns 1 for those that were its own. */
void preview_select(struct tui *t);
int preview_selecting(struct tui *t);
int preview_select_key(struct tui *t, uint32_t key);
/* Is this cell in a preview's page text, where the preview does the selecting? */
int preview_owns(void *state, int y, int x);

/* select.c: selecting what is drawn on the screen, outside a preview's text.
 * clip is the window (or line) the selection stays within; nd the window
 * pressed in, when there is one. */
void sel_press(struct tui *t, int y, int x, struct rect clip, struct node *nd);
void sel_move(struct tui *t, int y, int x);
void sel_release(struct tui *t, int y, int x);
void sel_clear(struct tui *t);
void sel_draw(struct tui *t); /* over the finished frame */

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
/* Names shown in the bar after the title, one of them as the one in view.
 * The panel only draws them: the script decides which keys switch, and is
 * told "<Tab>" with the tab's index when one is clicked. */
#define PANEL_TABS 12
void panel_set_tabs(struct panel *p, int n, const char *const *names, int current);
void panel_set_follow(struct panel *p, int follow);
/* For a panel that follows: 1, and the book its cursor row stands for (0
 * when that row is not a book). 0 for a panel that does not follow. */
int panel_points_at(const struct panel *p, sqlite3_int64 *id);
/* Report cursor movement to the event function as the key "<Move>". */
void panel_set_moves(struct panel *p, int moves);
/* A dialog (a form that asks something): Esc closes it, where in another
 * panel it goes back to the window and leaves the panel open. */
void panel_set_dialog(struct panel *p, int dialog);
/* This panel is the bar's Configuration tab while it is open: the tab is
 * shown as the one in view, and going to the list's tabs closes it. */
void panel_set_screen_tab(struct panel *p);
/* Close the panel that is the Configuration tab, if one is open. */
void panel_leave_screen_tab(struct tui *t);
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
void panel_click(struct panel *p, int line, int x);
/* The whole text of the cell drawn at a screen position (r is the panel's
 * window), or NULL where there is none. */
const char *panel_text_at(struct panel *p, struct rect r, int y, int x);
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
/* Call fn for each command, in the order they were made; a non-zero return stops. */
void command_each(int (*fn)(const char *name, const char *help, void *ud), void *ud);

/* ------------------------------------------------------------------ tui.c */

enum prompt_kind { PROMPT_NONE, PROMPT_COMMAND, PROMPT_FILTER, PROMPT_SEARCH, PROMPT_INPUT };
/* text is NULL when the prompt was cancelled */
typedef void input_fn(struct tui *t, const char *text, void *ud);

#define TUI_BADGES 6 /* named notes scripts may keep in the status line at once */
struct tui {
  struct app *app;
  struct db rdb; /* read-only connection used by the query worker */
  struct notcurses *nc;
  struct ncplane *std;
  int rows_n, cols_n; /* terminal size */

  uv_poll_t *input;   /* the terminal's input; made anew when the terminal is taken back */
  unsigned nc_gen;    /* counts notcurses contexts: planes of an earlier one are gone */
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
  int list_rows; /* the list's rows of books when last drawn: a page */

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
  struct badge {    /* named notes scripts keep in the status line, beside the mode */
    char *name, *text;
    int color;
  } badges[TUI_BADGES];
  int nbadges;

  struct picker *picker;
  char *help; /* pager overlay text (help, messages, script output); NULL when closed */
  char *pager_title;
  int help_scroll;
  uint64_t errors_seen; /* log errors the console has shown (core/log.h) */
  void *drag;           /* the preview a mouse drag began in, while it lasts */
  /* A click in a preview moves the cursor's window there only if it turns
   * out to be a plain click: selecting text to copy (a drag, a double click)
   * leaves the cursor where the copy is wanted, in review say. */
  struct {
    void *state; /* the preview pressed in, until the button comes up */
    void *back;  /* the window the cursor left for it, should a second click make it a double */
    double at;   /* when it was pressed */
  } pv;
  struct {              /* a line between windows being dragged */
    int on;             /* it is moving */
    int armed;          /* the press was on a window's bar: resize if the pointer goes up or down */
    char split;         /* 'v' or 'h' */
    int y, x;           /* where the line is now */
  } rs;
  struct {              /* text being selected on the screen (select.c) */
    int on;             /* the button is down */
    int active;         /* and the pointer has left the cell it went down on */
    int shown;          /* a finished selection, highlighted until the next key or click */
    int y0, x0, y1, x1; /* where it began, where it is now */
    struct rect clip;
    int clicks, click_y, click_x;
    double click_at;
  } sel;
  sqlite3_int64 peek;   /* a book the preview shows instead of the list's: the one a
                         * following panel is on when the list does not hold it */
  /* whoever asked to be told when the indexing run ends (tui_index) */
  void (*ix_hook[8])(const struct index_stats *st, void *ud);
  void *ix_hook_ud[8];
  int nix_hook;
  int tab_x[4];         /* where the bar's tabs were drawn: columns of their edges */
  int tab_n;            /* how many tabs it has: library, [sync folder,] configuration */
  struct panel *screen_tab; /* the panel that is the bar's Configuration tab, while it is open */
  /* the views last focused among the windows and among the panels, so that
   * Tab and Esc go back to them (wm_focus_panel, wm_focus_back); found again
   * by wm_leaf_of, so one that has closed is simply not found */
  void *last_window, *last_panel;
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
/* Hand the terminal to an editor ($VISUAL, $EDITOR, else vim, else vi) on
 * path, and take it back when it exits. Returns the editor's exit status,
 * or -1 when none could be run. */
int tui_edit_file(struct tui *t, const char *path);
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
/* A badge in the status line under a name of the script's choosing: set again
 * to change it, with NULL text to take it away. color is a theme colour. */
void tui_badge(struct tui *t, const char *name, const char *text, int color);
/* Show text in a scrollable overlay. */
void tui_pager(struct tui *t, const char *title, const char *text);
/* Put text on the message line without logging it (tui_msg logs first). */
void tui_show_msg(struct tui *t, int error, const char *text);
/* The console window (view_console.c): its keys when focused, the wheel. */
int console_key(struct tui *t, void *state, uint32_t key);
void console_wheel(void *state, int delta);
void tui_start_index(struct tui *t, int force);

#endif
