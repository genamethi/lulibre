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
  A_STRUCK = 8,
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
/* A box: r filled with bg, with a rounded border on its edge. */
void dr_frame(struct ncplane *n, struct rect r, int bg);

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
/* Break s into lines of at most maxw columns: at its own newlines, and at
 * the last space that fits (dr_wrap). Fills off and len for the first max
 * lines and returns how many there are, which may be more than max. */
int dr_lines(const char *s, int maxw, size_t *off, size_t *len, int max);

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
  char *command; /* NULL for a Lua function's */
  int lua_ref;   /* the function, as its reference in the main lua_State; 0 for none */
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
/* The same with a Lua function in place of a command: ref is its reference
 * in the main lua_State, released when no mode is left bound to it. */
int keymap_bind_fn(struct keymap *km, unsigned modes, const char *spec, int ref, const char *about, int hidden);
/* Takes a binding out of these modes: 0, 1 when there was none, -1 when
 * spec is no key sequence. */
int keymap_unbind(struct keymap *km, unsigned modes, const char *spec);
/* Feed one key. Returns the binding to run (a command, or a Lua function),
 * or NULL (pending or unbound). Valid until the keymap next changes. */
const struct binding *keymap_feed(struct keymap *km, unsigned mode, uint32_t key);
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
enum { KC_PANEL, KC_LINE, KC_PICKER, KC_PAGER, KC_CONSOLE, KC_SELECT, KC_FORM, KC_N };
enum { SA_LEFT = 1, SA_RIGHT, SA_UP, SA_DOWN, SA_WORD, SA_BACK, SA_START, SA_END, SA_TOP, SA_BOTTOM, SA_MARK, SA_LINE,
       SA_COPY, SA_LEAVE };
enum { PA_DOWN = 1, PA_UP, PA_TOP, PA_BOTTOM, PA_HALF_DOWN, PA_HALF_UP, PA_PAGE_DOWN, PA_PAGE_UP, PA_CLOSE, PA_BACK };
enum { LA_ACCEPT = 1, LA_CANCEL, LA_PASTE, LA_COPY, LA_COMPLETE, LA_NEXT, LA_PREV, LA_UP, LA_DOWN,
       LA_PREVIEW_UP, LA_PREVIEW_DOWN, LA_LEFT, LA_RIGHT, LA_HOME, LA_END, LA_BACKSPACE, LA_DELETE,
       LA_KILL_START, LA_KILL_END, LA_KILL_WORD, LA_WORD_LEFT, LA_WORD_RIGHT };
enum { KA_ACCEPT = 1, KA_CANCEL, KA_DOWN, KA_UP, KA_PAGE_DOWN, KA_PAGE_UP };
enum { GA_DOWN = 1, GA_UP, GA_PAGE_DOWN, GA_PAGE_UP, GA_TOP, GA_BOTTOM, GA_TOGGLE, GA_OPEN, GA_CLOSE, GA_ALL, GA_NONE,
       GA_SEARCH, GA_NEXT, GA_PREV, GA_FOLLOW, GA_BACK, GA_FORWARD, GA_LEAVE };
enum { FA_EDIT = 1, FA_DROP, FA_WRITE };
enum { CA_UP = 1, CA_DOWN, CA_HALF_UP, CA_HALF_DOWN, CA_TOP, CA_FOLLOW, CA_ERRORS, CA_WARNINGS, CA_NOTICES,
       CA_EVERYTHING, CA_CLEAR, CA_CLOSE };
#define CTX_PENDING (-1) /* the key may be the first of two: wait for the next */

void ctx_defaults(void);
void ctx_free(void);
int ctx_named(const char *name); /* a place's number, or -1 */
int ctx_count(void);             /* the places there are: lulibre's, then the screens' */
int ctx_is_own(const char *name); /* one of lulibre's places? Any thread */
/* A screen's place, made (or made again) from Lua: its title, its
 * actions' names, default keys (separated by spaces) and what each does,
 * the actions its hint line shows, where its views go (a panel's side and
 * size; side 0 leaves it to the opener) and whether it is a tab of the
 * bar. Its number, or -1 and *err. */
int ctx_add(const char *name, const char *title, int n, const char *const *names, const char *const *keys,
            const char *const *abouts, int nhint, const char *const *hint, char side, float size, int tab,
            char **err);
void ctx_placement(int ctx, char *side, float *size);
/* The i-th screen that is a tab of the bar: its place, name and title; -1 past the last. */
int ctx_tab(int i, const char **name, const char **title);
const char *ctx_name(int ctx);
int ctx_is_tab(int ctx);
void ctx_drop_lua(void); /* the screens' places go (:restart-scripts) */
/* A place's or screen's title and hint line, changed (scrnman.set): title
 * NULL keeps it; nhint < 0 keeps the hint, 0 leaves none. */
int ctx_set(const char *name, const char *title, int nhint, const char *const *hint, char **err);
const char *ctx_action_name(int ctx, int action); /* NULL for none */
/* The hint line: the hint's actions with the keys now on them ("a accept   e
 * edit"); how many it has. */
int ctx_hint_line(int ctx, sbuf *out);
/* The same with only the actions keep says yes to. */
int ctx_hint_line_if(int ctx, sbuf *out, int (*keep)(int action, const void *ud), const void *ud);
/* Put a key (one, or two in a row) on an action; an empty action unbinds. */
int ctx_bind(const char *ctx, const char *spec, const char *action, const char *desc, int hidden, char **err);
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
 * nest: "math.number-theory" is under "math") with the books under it. */
struct ghead {
  char *path;        /* what it is known by: "math.number-theory" */
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

/* ---------------------------------------------------------------- marks.c */

/* Read the marks kept in the index (rows_init). */
void rows_marks_load(struct tui *t);
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
  /* a key for the focused view: 1 when it took it, 0 to let it go on to
   * the global keys (input.c); NULL: none of its own */
  int (*key)(struct tui *t, void *state, uint32_t key, const struct ncinput *ni);
  int modal; /* while it is up, every key is its own, and the mouse only selects */
};

#define TABS_MAX 10 /* the bar's tabs: library, sync folder, and the tab screens */

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
  /* a window above the others (wm_float), outside the tree: its share of
   * the windows' area, and how it is drawn (enum float_how) */
  float fsize;
  int floating, full;
  void *back; /* the state of the window focused before it, which gets the focus back */
};

enum float_how {
  FLOAT_BOX,  /* a framed box of its share of the area */
  FLOAT_FULL, /* all of the area, nothing under it showing */
  FLOAT_BARE, /* all of the area, given to the view to draw where it likes (an overlay) */
};

extern const struct view_class view_list, view_preview, view_panel, view_console, view_pager, view_picker;

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
/* A window above the others, outside the tree, for an existing view state,
 * drawn as how says (a box's size is its share of the windows' area). It
 * takes the focus; wm_undock closes it as it closes the others. */
struct node *wm_float(struct tui *t, const struct view_class *cls, void *state, float size, enum float_how how);
/* The floating window on top, or NULL. */
struct node *wm_top(struct tui *t);
/* A window beside the focused one (or the last window of the tree), which
 * is split for it; size is the new one's share. */
struct node *wm_tile(struct tui *t, const struct view_class *cls, void *state, float size);
void wm_undock(struct tui *t, void *state);
/* Give the docked window showing this state that share of the screen. */
void wm_set_size(struct tui *t, void *state, float size);
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
/* key is NULL when the panel has closed; value is a form's edited value
 * (with the key "edit"), else NULL */
typedef void panel_event_fn(struct panel *p, const char *key, int row, const char *value, void *ud);

/* side: 'b' along the bottom (size is a share of the height), 'l' down the
 * left (a share of the width). */
struct panel *panel_open(struct tui *t, float size, char side);
void panel_close(struct panel *p);  /* safe to call twice */
/* Take the panel off the screen without closing it, and put it back. A
 * script does this around a panel it opens on top of its own. */
void panel_hide(struct panel *p);
void panel_show(struct panel *p);
void panel_focus(struct panel *p);
void panel_set_size(struct panel *p, float size);
/* Keys the script handles (panel_set_own) and the global commands, by first
 * word and separated by spaces, that its other keys may reach
 * (panel_set_pass): "preview yank" lets P and yy through. */
void panel_set_own(struct panel *p, int n, const uint32_t *keys);
/* The panel is a screen's (ctxkeys.c's place): a key bound to one of its
 * actions reaches the script as the action's name, other keys not at all. */
void panel_set_place(struct panel *p, int place);
int panel_place(const struct panel *p); /* -1 for none */
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
/* What the preview shows while the panel is up, whatever row the cursor is
 * on: the book id, or (note not NULL) that note in place of a book; set 0
 * gives the preview back to the rows (or the list). */
void panel_set_preview(struct panel *p, int set, sqlite3_int64 id, const char *note);
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
/* A form: the panel's rows are a record's fields, and its keys are also
 * the place "form"'s (edit, drop, write). edit asks for the field's value
 * on the line, with its value as it stands. In a FORM_DIRECT form the value
 * typed goes to the event function as "edit", with the row and the value;
 * one that FORM_STAGED keeps it as the field's change (the rows show Now
 * and To be), drop takes a change back, and write is told as "write" for
 * the opener to read the changes (panel_field). */
enum { FORM_DIRECT = 1, FORM_STAGED };
void panel_set_form(struct panel *p, int kind);
int panel_form(const struct panel *p); /* 0 for a panel that is no form */
/* The fields, each a name, a label, its value and (a direct form; notes
 * may be NULL) a note in a column after it; a staged form keeps the
 * changes of the fields still there by name. */
void panel_set_fields(struct panel *p, int n, const char *const *names, const char *const *labels,
                      const char *const *values, const char *const *notes);
/* Field i's name, and its change in a staged form (NULL for none). */
const char *panel_field(const struct panel *p, int i, const char **change);
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
/* The open picker's ud, if accept is the function it was made with; else NULL. */
void *picker_ud_if(struct tui *t, picker_accept *accept);
void picker_key(struct tui *t, uint32_t key, const struct ncinput *ni);
void picker_draw(struct tui *t);

/* --------------------------------------------------------------- command.c */

typedef void command_fn(struct tui *t, const char *args);

/* What completes a command's arguments at the ':' prompt (complete.c). */
enum complete_kind {
  COMPLETE_NONE,
  COMPLETE_WORDS,   /* a fixed list */
  COMPLETE_FILTER,  /* the filter language */
  COMPLETE_SETTING, /* setting names, then name=choice */
  COMPLETE_COMMAND, /* command names */
  COMPLETE_LUA,     /* a Lua function, asked by message (lapi_complete) */
  COMPLETE_HELP,    /* the guides' tags (:help) */
};
struct completion {
  enum complete_kind kind;
  char *words; /* COMPLETE_WORDS: separated by newlines */
  int ref;     /* COMPLETE_LUA: the function, as its reference in the main lua_State */
};

void command_register(const char *name, command_fn *fn, const char *help);
/* What completes one of lulibre's commands: kind, and for COMPLETE_WORDS
 * the words, separated by spaces. */
void command_set_complete(const char *name, enum complete_kind kind, const char *words);
/* A command implemented in Lua: ref is a registry reference to the
 * function; comp (taken over, NULL for none) what completes it. */
void command_register_lua(const char *name, int ref, const char *help, struct completion *comp);
/* What completes the command a line starts with (its first len bytes name
 * it, as tui_exec finds it): its full name, and *comp; NULL for none. */
const char *command_completion(const char *line, size_t len, const struct completion **comp);
/* :edit and :undo (tui/edit.c) */
void edit_commands(void);
/* Removes a command defined in Lua: 0, or -1 when there is none. */
int command_remove_lua(const char *name);
/* Every command defined in Lua goes, with the lua_State (:restart-scripts). */
void commands_drop_lua(void);
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
  sqlite3_int64 posted_book; /* the book EV_CURSOR last said was under the cursor */
  int dirty, quit;

  unsigned mode;
  struct keymap *km; /* the global keymap */
  struct node *root, *focus;
  struct node *floats[8]; /* windows above the tree, the last on top (wm_float) */
  int nfloats;
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
  /* a Lua function's last answer, and the comp_ctx it was asked for */
  char *comp_got_ctx;
  char **comp_got, **comp_got_detail;
  int ncomp_got;
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
  char *preview_note;   /* shown by the preview in place of any book (panel_set_preview) */
  int tab_x[TABS_MAX + 1]; /* where the bar's tabs were drawn: columns of their edges */
  int tab_n;               /* how many tabs it has: library, [sync folder,] the tab screens */
  struct panel *screen_tab; /* the panel that is the bar's Configuration tab, while it is open */
  /* the views last focused among the windows and among the panels, so that
   * Tab and Esc go back to them (wm_focus_panel, wm_focus_back); found again
   * by wm_leaf_of, so one that has closed is simply not found */
  void *last_window, *last_panel;
  /* a terminal paste in progress (input.c): keys held while they might be one
   * of its markers, and the text between the markers */
  struct ncinput held[6];
  int nheld, pasting;
  uv_timer_t held_timer;
  sbuf paste;

  char *msg;
  int msg_error;

  int indexing; /* a run is going, on the background thread (work.h) */
  int ix_done, ix_total, ix_failed;
  int mirroring; /* calibre's database is being read again (tui_mirror) */
};

/* Between tui.c and the files split from it: prompt.c, input.c, render.c. */
void suggest_clear(struct tui *t);
void suggest_rematch(struct tui *t);
void suggest_accept(struct tui *t);
void draw_suggestions(struct tui *t, int bottom_y, int x);
void history_load(struct tui *t);
void prompt_changed(struct tui *t);
void prompt_paste(struct tui *t);
void prompt_key(struct tui *t, uint32_t key, const struct ncinput *ni);
void input_read_cb(uv_poll_t *h, int status, int events);
void bracketed_paste(int on);
void terminal_release(struct tui *t);
void log_arrived(void *ud);
const char *tab_command(const struct tui *t, int i, char *buf, size_t size);
void render_prepare_cb(uv_prepare_t *h);

int tui_run(struct app *app);
/* Hand the terminal to an editor ($VISUAL, $EDITOR, else vim, else vi) on
 * path, and take it back when it exits. Returns the editor's exit status,
 * or -1 when none could be run. */
int tui_edit_file(struct tui *t, const char *path);
int tui_in_terminal(struct tui *t, char *const argv[]);
void tui_dirty(struct tui *t);
void tui_msg(struct tui *t, int error, const char *fmt, ...) PRINTF(3, 4);
void tui_prompt(struct tui *t, enum prompt_kind kind, const char *initial);
/* Ask for a line of text; cb gets the answer, or NULL if cancelled. */
void tui_input(struct tui *t, const char *label, const char *initial, input_fn *cb, void *ud);
void tui_input_cancel(struct tui *t); /* as if the user pressed Esc */
/* The open question's ud, if cb is the function it answers; else NULL. */
void *tui_input_ud_if(struct tui *t, input_fn *cb);
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
/* A Lua function's completions for ctx, all of it taken over (malloc'd). */
void complete_answered(struct tui *t, char *ctx, int n, char **text, char **detail);
const char *command_at(int i, const char **help); /* the i-th command's name; NULL past the last */
void tui_progress(struct tui *t, const char *text); /* NULL clears */
/* A badge in the status line under a name of the script's choosing: set again
 * to change it, with NULL text to take it away. color is a theme colour. */
void tui_badge(struct tui *t, const char *name, const char *text, int color);
struct rich;
enum { PAGER_WIDTH = 76 }; /* the pager's text at its widest */
/* Show text in a scrollable overlay. */
void tui_pager(struct tui *t, const char *title, const char *text);
void tui_pager_end(struct tui *t); /* the open pager shows its end */
/* The same, with the first `open` sections open and the others as they
 * were left the last time a text of that title was shown, else closed;
 * open < 0: every section open. */
void tui_pager_folded(struct tui *t, const char *title, const char *text, int open);
void tui_pager_forget(void); /* what was opened and closed (at the end) */
/* The same with a text of styles and links (rich.c), taken over; where is
 * the file it is, which relative links start from (NULL: none). */
void tui_pager_rich(struct tui *t, const char *title, struct rich *text, int open, const char *where);
void tui_pager_at(struct tui *t, int line); /* the cursor to the line, shown at the top */

/* ------------------------------------------------------------------ rich.c */

/* A link in a text: its bytes, and what it names (a guide's file,
 * file#heading, file:line, a tag; guides_follow). */
struct pager_link {
  size_t off, len;
  char *target;
};
enum { RS_STRONG = 1, RS_EM = 2, RS_CODE = 4, RS_STRIKE = 8 };
struct rich_span {
  size_t off, len;
  unsigned style; /* RS_* */
};
struct rich_heading {
  int line, level;      /* the line from 0 */
  char *text, *anchor; /* as written; as GitHub makes it (NULL in plain text) */
};
struct rich_cell {
  size_t off, len;
};
struct rich_row { /* a table's row */
  int line, head;
  int ncells;
  struct rich_cell *cells;
};
/* Text with styles and links: lines, each ending in a newline, with the
 * column each line's wrapped rows start at (hang; -1 or past nlines: the
 * pager's guess) and, when made from a source, the line of the source it
 * comes from (src, from 1; NULL for plain text); spans of style; links;
 * headings, which the pager opens and closes; tables' rows. Offsets are in
 * text; all of it is the struct's. */
struct rich {
  sbuf text;
  int nlines, *hang, *src;
  struct rich_span *spans; /* in the order of their ends */
  struct pager_link *links; /* in the order of their offsets */
  struct rich_heading *heads;
  struct rich_row *rows;
  int nspans, nlinks, nheads, nrows;
  int hang_cap, spans_cap, links_cap, heads_cap, rows_cap;
};
/* Markdown (CommonMark with GitHub's tables, strikethrough, task lists and
 * links of bare addresses) as a text laid out for width columns (0: the
 * pager's); -1 when md4c gave up, with what it made so far. */
int md_render(const char *src, size_t n, int width, struct rich *out);
/* The lines and headings of r's text, as plain text: a line that does not
 * begin with a space is a heading. */
void rich_plain(struct rich *r);
void rich_link(struct rich *r, size_t off, size_t len, const char *target); /* target copied */
/* the first line of r made from line `src` of its source (else from the
 * nearest line before it) */
int rich_line_of(const struct rich *r, int src);
void rich_free(struct rich *r);

/* ---------------------------------------------------------------- guides.c */

/* The guides: the Markdown files in lulibre's docs/ and in docs/ under the
 * configuration and data folders, indexed by their headings and the
 * commands, keys and settings their tables name, as vim's help is by its
 * tags. */
int guides_help(struct tui *t, const char *topic); /* :help TOPIC; 0 when nothing is found (and said) */
/* A link: a tag, a file (relative to `from`, the file it is in), file#heading
 * or file:line, or several to try, separated by newlines; shown in the
 * pager. 0 when it leads nowhere (and said), the pager untouched. */
int guides_follow(struct tui *t, const char *target, const char *from);
/* The guides, a line each, with a link to each, at the end of text (for ?). */
void guides_list(struct tui *t, struct rich *text);
/* Every tag, for completing :help, separated by newlines; the caller's. */
char *guides_tags(struct tui *t);
void guides_forget(void); /* the index (at the end) */
/* Put text on the message line without logging it (tui_msg logs first). */
void tui_show_msg(struct tui *t, int error, const char *text);
/* The console window (view_console.c): its keys when focused, the wheel. */
int console_key(struct tui *t, void *state, uint32_t key);
void console_wheel(void *state, int delta);
void tui_start_index(struct tui *t, int force);
/* The background thread: where an index run is (phase -1 started, 0 going,
 * 1 ended; st NULL when it has no numbers), for the status line. */
struct index_stats;
void tui_post_indexing(struct app *app, const struct index_stats *st, int phase);
/* Read calibre's database again, on the Lua thread's connection so that the
 * interface draws on meanwhile; then refresh the list. told: say so when
 * done (the :reload command); otherwise a change starts the indexer. */
void tui_mirror(struct tui *t, int force, int told);

#endif
