/* Commands: everything the interface can do has a name here. Key bindings
 * and the ':' prompt both go through tui_exec, and Lua will register into
 * the same table. */
#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "core/log.h"
#include "lua/lapi.h"
#include "tui/tui.h"

static struct command {
  char *name;
  command_fn *fn; /* NULL for a command implemented in Lua */
  int lua_ref;
  char *help;
} *cmds;
static void command_help(struct tui *t);
static int ncmds, capcmds;

static void add(const char *name, command_fn *fn, int ref, const char *help) {
  for (int i = 0; i < ncmds; i++)
    if (!strcmp(cmds[i].name, name)) { /* redefining a command replaces it */
      cmds[i].fn = fn;
      cmds[i].lua_ref = ref;
      free(cmds[i].help);
      cmds[i].help = xstrdup(help ? help : "");
      return;
    }
  if (ncmds == capcmds) {
    capcmds = capcmds ? capcmds * 2 : 32;
    cmds = xrealloc(cmds, (size_t)capcmds * sizeof *cmds);
  }
  cmds[ncmds++] = (struct command){xstrdup(name), fn, ref, xstrdup(help ? help : "")};
}

void command_register(const char *name, command_fn *fn, const char *help) {
  add(name, fn, 0, help);
}

void command_register_lua(const char *name, int ref, const char *help) {
  add(name, NULL, ref, help);
}

void command_each(int (*fn)(const char *name, const char *help, void *ud), void *ud) {
  for (int i = 0; i < ncmds; i++)
    if (fn(cmds[i].name, cmds[i].help, ud)) return;
}

void commands_free(void) {
  for (int i = 0; i < ncmds; i++) {
    free(cmds[i].name);
    free(cmds[i].help);
  }
  free(cmds);
  cmds = NULL;
  ncmds = capcmds = 0;
}

static const struct { const char *alias, *name; } aliases[] = {
  {"q", "quit"}, {"f", "filter"}, {"s", "sort"}, {"h", "help"}, {"sp", "split"}, {"e", "echo"},
};

static struct command *find(const char *name, size_t len) {
  struct command *prefix = NULL;
  int nprefix = 0;
  for (int i = 0; i < ncmds; i++) {
    if (strlen(cmds[i].name) == len && !strncmp(cmds[i].name, name, len)) return &cmds[i];
    if (!strncmp(cmds[i].name, name, len)) {
      prefix = &cmds[i];
      nprefix++;
    }
  }
  for (size_t i = 0; i < ARRAY_LEN(aliases); i++)
    if (strlen(aliases[i].alias) == len && !strncmp(aliases[i].alias, name, len))
      return find(aliases[i].name, strlen(aliases[i].name));
  return nprefix == 1 ? prefix : NULL;
}

void tui_exec(struct tui *t, const char *line) {
  while (*line == ' ' || *line == ':') line++;
  if (!*line) return;
  const char *e = line;
  while (*e && *e != ' ') e++;
  struct command *c = find(line, (size_t)(e - line));
  if (!c) {
    tui_msg(t, 1, "no such command: %.*s", (int)(e - line), line);
    return;
  }
  while (*e == ' ') e++;
  log_debug("command: %s", line);
  if (c->fn) c->fn(t, e);
  else lapi_spawn_ref(t->app, c->lua_ref, c->name, e);
}

const char *command_at(int i, const char **help) {
  if (i < 0 || i >= ncmds) return NULL;
  if (help) *help = cmds[i].help;
  return cmds[i].name;
}

/* ---- helpers ---- */

static int arg_is(const char *args, const char *word) {
  size_t n = strlen(word);
  return !strncmp(args, word, n) && (args[n] == '\0' || args[n] == ' ');
}

static const char *arg_rest(const char *args) {
  while (*args && *args != ' ') args++;
  while (*args == ' ') args++;
  return args;
}

/* ---- commands ---- */

static void c_quit(struct tui *t, const char *args) {
  t->quit = 1;
  uv_stop(t->app->loop);
}

static void c_move(struct tui *t, const char *args) {
  int page = list_page_rows(t), on_preview = t->focus->cls == &view_preview;
  struct rows *r = &t->rows;
  int delta = 0, to = -1;
  if (arg_is(args, "top")) to = 0;
  else if (arg_is(args, "bottom")) to = r->n - 1;
  else if (arg_is(args, "half-down")) delta = page / 2 > 0 ? page / 2 : 1;
  else if (arg_is(args, "half-up")) delta = -(page / 2 > 0 ? page / 2 : 1);
  else if (arg_is(args, "page-down")) delta = page;
  else if (arg_is(args, "page-up")) delta = -page;
  else delta = atoi(args);

  if (on_preview) { /* with the preview focused, movement scrolls it */
    preview_scroll(t, to == 0 ? -1000000 : to > 0 ? 1000000 : delta);
    return;
  }
  rows_move(t, to >= 0 ? to : r->cur + delta);
}

static void c_filter(struct tui *t, const char *args) {
  rows_set_filter(t, args);
}

static void c_prompt(struct tui *t, const char *args) {
  if (arg_is(args, "filter")) tui_prompt(t, PROMPT_FILTER, t->rows.filter);
  else if (arg_is(args, "search")) tui_prompt(t, PROMPT_SEARCH, "");
  else tui_prompt(t, PROMPT_COMMAND, arg_rest(args));
}

static void c_search(struct tui *t, const char *args) {
  if (arg_is(args, "next")) rows_search_next(t, 1);
  else if (arg_is(args, "prev")) rows_search_next(t, -1);
  else if (arg_is(args, "clear") || !*args) rows_search(t, NULL);
  else {
    rows_search_begin(t);
    rows_search_end(t, args, 1);
  }
}

static void c_sort(struct tui *t, const char *args) {
  /* replace any sort: term in the current filter */
  sbuf f = SBUF_INIT;
  const char *p = t->rows.filter ? t->rows.filter : "";
  while (*p) {
    while (*p == ' ') p++;
    const char *e = p;
    while (*e && *e != ' ') e++;
    if (e > p && strncmp(p, "sort:", 5) != 0) {
      if (f.len) sb_putc(&f, ' ');
      sb_putn(&f, p, (size_t)(e - p));
    }
    p = e;
  }
  if (*args) sb_printf(&f, "%ssort:%s", f.len ? " " : "", args);
  rows_set_filter(t, f.s ? f.s : "");
  sb_free(&f);
}

static void c_visual(struct tui *t, const char *args) {
  if (t->mode == MODE_VISUAL) {
    t->mode = MODE_NORMAL;
    t->rows.anchor = -1;
  } else if (t->rows.n > 0) {
    t->mode = MODE_VISUAL;
    t->rows.anchor = t->rows.cur;
  }
  tui_dirty(t);
}

static void c_mark(struct tui *t, const char *args) {
  struct rows *r = &t->rows;
  if (arg_is(args, "all")) rows_mark_all(t, 1);
  else if (arg_is(args, "none")) rows_mark_all(t, 0);
  else if (arg_is(args, "invert")) rows_mark_all(t, -1);
  else if (t->mode == MODE_VISUAL && r->anchor >= 0) {
    /* a range: mark it all, unless it is all marked already */
    int n;
    sqlite3_int64 *ids = rows_selection(t, &n);
    int all = 1;
    for (int i = 0; i < n; i++) all = all && rows_marked(t, ids[i]);
    for (int i = 0; i < n; i++) rows_mark(t, ids[i], !all);
    free(ids);
    c_visual(t, "");
  } else if (rows_head(t, r->cur)) {
    /* a heading: every book under it, unless they all are already */
    const struct ghead *h = rows_head(t, r->cur);
    int all = 1;
    for (int i = 0; i < h->nbooks; i++) all = all && rows_marked(t, r->all[h->books[i]]);
    for (int i = 0; i < h->nbooks; i++) rows_mark(t, r->all[h->books[i]], !all);
    rows_move(t, r->cur + 1);
  } else if (rows_current(t)) {
    rows_mark(t, rows_current(t), -1);
    rows_move(t, r->cur + 1);
  }
  tui_msg(t, 0, "%d marked", r->nmarks);
}

static void c_focus(struct tui *t, const char *args) {
  if (arg_is(args, "next") || !*args) wm_focus_next(t, 1);
  else if (arg_is(args, "prev")) wm_focus_next(t, -1);
  else if (arg_is(args, "panel")) wm_focus_panel(t, arg_is(arg_rest(args), "prev") ? -1 : 1);
  else if (arg_is(args, "back")) wm_focus_back(t);
  else wm_focus_dir(t, args[0]);
}

static void c_split(struct tui *t, const char *args) {
  char dir = arg_is(args, "h") ? 'h' : 'v';
  const char *view = (arg_is(args, "h") || arg_is(args, "v")) ? arg_rest(args) : args;
  if (!wm_split(t, dir, view)) return;
  if (*view) tui_msg(t, 1, "no such view: %s (views: list, preview)", view);
  else tui_msg(t, 1, "a panel is not split: :split list, or :split preview");
}

static void c_close(struct tui *t, const char *args) { wm_close(t); }
static void c_only(struct tui *t, const char *args) { wm_only(t); }
static void c_resize(struct tui *t, const char *args) {
  static const struct { const char *word; char dir; int cells; } dirs[] = {
    {"left", 'h', 2}, {"right", 'l', 2}, {"up", 'k', 1}, {"down", 'j', 1},
  };
  for (size_t i = 0; i < ARRAY_LEN(dirs); i++)
    if (arg_is(args, dirs[i].word)) {
      int n = atoi(arg_rest(args));
      wm_resize_dir(t, dirs[i].dir, n > 0 ? n : dirs[i].cells);
      return;
    }
  wm_resize(t, atoi(args));
}

static void c_preview(struct tui *t, const char *args) {
  if (arg_is(args, "scroll")) preview_scroll(t, atoi(arg_rest(args)));
  else if (arg_is(args, "page")) preview_page(t, atoi(arg_rest(args)));
  else if (arg_is(args, "graphic")) preview_toggle_graphic(t);
  else if (arg_is(args, "pan")) preview_pan(t, atoi(arg_rest(args)));
  else if (arg_is(args, "zoom")) preview_zoom(t, atoi(arg_rest(args)));
  else if (arg_is(args, "select")) preview_select(t);
  else if (arg_is(args, "add")) {
    /* read the file as far as the page being looked at */
    sqlite3_int64 book;
    int page, indexed;
    if (!preview_position(t, &book, &page, &indexed)) tui_msg(t, 1, "there is no file in the preview");
    else if (page <= indexed) tui_msg(t, 0, "page %d is read already: the first %d pages of this file are", page, indexed);
    else {
      char *line = xasprintf("addpages %lld %d", (long long)book, page);
      tui_exec(t, line);
      free(line);
    }
  } else tui_msg(t, 1, "preview scroll N | page N | graphic | zoom N | pan N | select | add");
}

static void c_index(struct tui *t, const char *args) {
  tui_start_index(t, arg_is(args, "force"));
}

static void c_reload(struct tui *t, const char *args) {
  char *err = NULL;
  if (t->ix) {
    tui_msg(t, 1, "indexing is running; try again when it finishes");
    return;
  }
  if (db_mirror(&t->app->db, t->app->cfg.library, 1, &err) < 0) {
    tui_msg(t, 1, "%s", err);
    free(err);
    return;
  }
  rows_reload(t);
  tui_msg(t, 0, "reloaded from calibre");
}

static void c_set(struct tui *t, const char *args) {
  const char *eq = strchr(args, '=');
  char *err = NULL;
  if (!eq) {
    const struct opt_def *o = config_find(args);
    if (!o) tui_msg(t, 1, "unknown option '%s'", args);
    else if (o->type == OPT_INT) tui_msg(t, 0, "%s=%d", o->name, config_int(&t->app->cfg, o));
    else tui_msg(t, 0, "%s=%s", o->name, config_str(&t->app->cfg, o));
    return;
  }
  char *name = xstrndup(args, (size_t)(eq - args));
  if (config_set(&t->app->cfg, name, eq + 1, &err)) {
    tui_msg(t, 1, "%s", err);
    free(err);
  } else {
    tui_msg(t, 0, "%s", args);
  }
  free(name);
}

static void c_echo(struct tui *t, const char *args) {
  tui_msg(t, 0, "%s", args);
}

static void c_help(struct tui *t, const char *args) {
  command_help(t);
}

static void c_source(struct tui *t, const char *args) {
  int to = arg_is(args, "sync") ? 1 : arg_is(args, "library") ? 0 : !t->rows.source;
  if (to && !t->app->cfg.sync_dir[0]) {
    tui_msg(t, 1, "no sync folder is set: lulibre.o.sync_dir = \"~/some/folder\" in init.lua, or :set sync_dir=DIR");
    return;
  }
  rows_set_source(t, to);
  preview_book_changed(t);
}

/* ---- pickers ---- */

/* ---- the list as a tree ---- */

static void group_save(struct tui *t) {
  const struct rows *r = &t->rows;
  sqlite3_stmt *st;
  if (sqlite3_prepare_v2(t->app->db.h, "INSERT OR REPLACE INTO kv(key, value) VALUES('list:group', ?)", -1, &st, NULL) != SQLITE_OK)
    return;
  char *v = xasprintf("%s%s", r->group ? r->group : "none", r->group_by_count ? " count" : "");
  sqlite3_bind_text(st, 1, v, -1, SQLITE_TRANSIENT);
  sqlite3_step(st);
  sqlite3_finalize(st);
  free(v);
}

static void c_pick(struct tui *t, const char *args);

static void c_group(struct tui *t, const char *args) {
  struct rows *r = &t->rows;
  if (!*args) {
    c_pick(t, "group");
    return;
  }
  char by[32] = "", order[32] = "";
  sscanf(args, "%31s %31s", by, order);
  int by_count = r->group_by_count;
  /* ":group count" and ":group name" change the order of the headings alone */
  if (!strcmp(by, "count") || !strcmp(by, "name")) {
    snprintf(order, sizeof order, "%s", by);
    snprintf(by, sizeof by, "%s", r->group ? r->group : "none");
  }
  if (*order) by_count = !strcmp(order, "count");
  if (rows_set_group(t, by, by_count)) {
    tui_msg(t, 1, "group: there is no grouping '%s' (author, subject, series, publisher, year, format, folder, none)", by);
    return;
  }
  group_save(t);
  if (r->source) tui_msg(t, 0, "the library will be grouped by %s; the sync folder is listed plainly", r->group ? r->group : "nothing");
  else if (r->group)
    tui_msg(t, 0, "grouped by %s, %s: %s opens a heading, %s all of them; %s changes the grouping", r->group,
            r->group_by_count ? "the largest first" : "by name", key_hint("enter"), key_hint("fold all"), key_hint("pick group"));
  else tui_msg(t, 0, "the plain list");
}

static void c_fold(struct tui *t, const char *args) {
  if (!t->rows.head_of) {
    if (!t->rows.group) tui_msg(t, 0, "the list is not grouped: %s groups it", key_hint("pick group"));
    return;
  }
  rows_fold(t, arg_is(args, "open") ? 'o' : arg_is(args, "close") ? 'c' : arg_is(args, "all") ? 'O' : arg_is(args, "none") ? 'C' : 't');
}

/* Enter: a heading opens or closes; a book goes to the edit form. */
static void c_enter(struct tui *t, const char *args) {
  if (rows_head(t, t->rows.cur)) rows_fold(t, 't');
  else if (rows_current(t)) tui_exec(t, "edit");
}

static void accept_word(struct tui *t, sqlite3_int64 id, const char *text, void *ud) {
  /* ud: the command; the choice's first word is what it is given */
  char word[32] = "";
  sscanf(text, "%31s", word);
  char *line = xasprintf("%s %s", (const char *)ud, !strcmp(word, "(none)") ? "" : word);
  tui_exec(t, line);
  free(line);
}

static void accept_book(struct tui *t, sqlite3_int64 id, const char *text, void *ud) {
  if (rows_reveal(t, id)) {
    preview_book_changed(t);
    return;
  }
  t->rows.want_id = id; /* not in the current list: show everything, land on it */
  rows_set_filter(t, "");
}

static void accept_filter(struct tui *t, sqlite3_int64 id, const char *text, void *ud) {
  /* ud is the field; the value is quoted so spaces and quotes survive */
  const char *field = ud;
  sbuf f = SBUF_INIT;
  if (field) {
    sb_printf(&f, "%s\"", field);
    for (const char *p = text; *p; p++) {
      if (*p == '"') sb_putc(&f, '\\');
      sb_putc(&f, *p);
    }
    sb_putc(&f, '"');
  } else {
    const char *arrow = strstr(text, "  →  ");
    sb_puts(&f, arrow ? arrow + strlen("  →  ") : text);
  }
  rows_set_filter(t, f.s);
  sb_free(&f);
}

static void c_pick(struct tui *t, const char *args) {
  sqlite3 *h = t->app->db.h;
  sqlite3_stmt *st;
  struct picker *p;
  if (arg_is(args, "authors")) {
    p = picker_new(t, "authors", accept_filter, "author:=");
    if (sqlite3_prepare_v2(h, "SELECT name, n_books FROM authors WHERE id > 0 ORDER BY n_books DESC, name", -1,
                           &st, NULL) == SQLITE_OK) {
      while (sqlite3_step(st) == SQLITE_ROW) {
        char d[32];
        snprintf(d, sizeof d, "%d", sqlite3_column_int(st, 1));
        picker_add(p, 0, (const char *)sqlite3_column_text(st, 0), d);
      }
      sqlite3_finalize(st);
    }
  } else if (arg_is(args, "subjects")) {
    p = picker_new(t, "subjects", accept_filter, "subject:");
    if (sqlite3_prepare_v2(h, "SELECT name, n_books FROM tags WHERE id > 0 ORDER BY n_books DESC, name", -1, &st,
                           NULL) == SQLITE_OK) {
      while (sqlite3_step(st) == SQLITE_ROW) {
        char d[32];
        snprintf(d, sizeof d, "%d", sqlite3_column_int(st, 1));
        picker_add(p, 0, (const char *)sqlite3_column_text(st, 0), d);
      }
      sqlite3_finalize(st);
    }
  } else if (arg_is(args, "group")) {
    static const char *const ways[][2] = {
      {"none", "the plain list"}, {"author", "under their authors"}, {"subject", "the tree of subjects"},
      {"series", "under their series"}, {"publisher", "under their publishers (and journals)"}, {"year", "by year, the newest first"},
      {"format", "pdf, djvu, epub ..."}, {"folder", "as the calibre library is filed on disk"},
      {"count", "order the headings by size"}, {"name", "order the headings by name"},
    };
    p = picker_new(t, "group the list by", accept_word, "group");
    for (size_t i = 0; i < ARRAY_LEN(ways); i++) picker_add(p, 0, ways[i][0], ways[i][1]);
  } else if (arg_is(args, "sort")) {
    static const char *const orders[][2] = {
      {"title", "by title"}, {"author", "by author"}, {"-year", "the newest first"}, {"year", "the oldest first"},
      {"-added", "the latest additions first"}, {"-modified", "the latest changes first"}, {"series", "by series and number"},
      {"id", "in calibre's own order"}, {"(none)", "as the filter gives them"},
    };
    p = picker_new(t, "sort the books by", accept_word, "sort");
    for (size_t i = 0; i < ARRAY_LEN(orders); i++) picker_add(p, 0, orders[i][0], orders[i][1]);
  } else if (arg_is(args, "filters")) {
    static const char *const presets[] = {
      "everything  →  ",
      "marked  →  is:marked",
      "unknown author  →  author:unknown",
      "author is a list  →  is:listauthor",
      "title looks like a filename  →  is:filetitle",
      "no subject  →  subject:none",
      "no identifiers  →  no:ids -is:noncatalog",
      "non-catalog works  →  is:noncatalog",
      "no date  →  no:date",
      "no publisher  →  no:publisher",
      "no usable text (OCR candidates)  →  is:needsocr",
      "could not be read  →  is:error",
      "file missing on disk  →  is:missing",
      "recently added  →  sort:-added",
    };
    p = picker_new(t, "filters", accept_filter, NULL);
    for (size_t i = 0; i < ARRAY_LEN(presets); i++) picker_add(p, 0, presets[i], NULL);
  } else {
    p = picker_new(t, "books", accept_book, NULL);
    if (sqlite3_prepare_v2(h,
                           t->rows.source
                             ? "SELECT id, title, CASE WHEN authors IN ('Unknown', '()') THEN NULL"
                               " ELSE authors END FROM books WHERE id < 0 ORDER BY id DESC"
                             : "SELECT id, title, CASE WHEN authors IN ('Unknown', '()') THEN NULL"
                               " ELSE authors END FROM books WHERE id > 0 ORDER BY id",
                           -1, &st, NULL) == SQLITE_OK) {
      while (sqlite3_step(st) == SQLITE_ROW) {
        const char *title = (const char *)sqlite3_column_text(st, 1);
        picker_add(p, sqlite3_column_int64(st, 0), title ? title : "",
                   (const char *)sqlite3_column_text(st, 2));
      }
      sqlite3_finalize(st);
    }
  }
  picker_open(t, p);
}

void commands_builtin(void) {
  command_register("quit", c_quit, "leave lulibre");
  command_register("move", c_move, "+N | -N | top | bottom | half-down | half-up | page-down | page-up");
  command_register("filter", c_filter, "[filter]  show only matching books; no argument shows all");
  command_register("search", c_search,
                   "next | prev | clear | <filter>  jump between matching books without narrowing");
  command_register("prompt", c_prompt, "command | search | filter  open the bottom line for typing");
  command_register("sort", c_sort, "[-]id | title | author | year | series | added | modified");
  command_register("group", c_group,
                   "[author | subject | series | publisher | year | format | folder | none] [name | count]  the list as a tree");
  command_register("fold", c_fold, "toggle | open | close | all | none  open and close the headings of a grouped list");
  command_register("enter", c_enter, "open or close the heading under the cursor; on a book, edit it");
  command_register("mark", c_mark, "toggle | all | none | invert");
  command_register("visual", c_visual, "start or end a range selection");
  command_register("focus", c_focus,
                   "next | prev | h | j | k | l: the windows (list, previews, console) · panel [prev]: the panels · back: from a panel to its window");
  command_register("split", c_split, "[v|h] [list|preview]  open another window");
  command_register("close", c_close, "close the focused window");
  command_register("only", c_only, "close every window but the focused one");
  command_register("resize", c_resize,
                   "left | right | up | down [N]  move the line beside the focused window;  +N | -N  grow or shrink it");
  command_register("preview", c_preview,
                   "scroll N | page N | graphic | zoom +1|-1|0 | pan N  (zoom and pan: image only)");
  command_register("pick", c_pick, "books | authors | subjects | filters  fuzzy finder");
  command_register("index", c_index, "[force]  extract text from new or changed files");
  command_register("reload", c_reload, "re-read calibre's metadata now");
  command_register("source", c_source,
                   "[library | sync]  what the list shows: the calibre library or the sync folder");
  command_register("set", c_set, "name[=value]  show or change an option");
  command_register("echo", c_echo, "text  show a message");
  command_register("help", c_help, "this screen");
  command_register("help-plain", c_help, "keys and commands as one long page");
}

static void command_help(struct tui *t) {
  sbuf h = SBUF_INIT;
  sb_puts(&h, "KEYS\n");
  for (int i = 0; i < t->km->n; i++) {
    const struct binding *b = &t->km->b[i];
    if (!(b->modes & (MODE_NORMAL | MODE_VISUAL)) || b->hidden) continue;
    sbuf k = SBUF_INIT;
    key_format(&k, b->keys, b->nkeys);
    sb_printf(&h, "  %-12s %s%s\n", k.s, b->about ? b->about : b->command,
              b->modes == MODE_VISUAL ? "   (while selecting)" : "");
    sb_free(&k);
  }
  for (int c = 0; c < KC_N; c++) {
    sb_putc(&h, '\n');
    ctx_describe(c, &h, 1);
  }
  sb_puts(&h, "\nCOMMANDS   type : then the name; a unique prefix is enough\n");
  for (int i = 0; i < ncmds; i++) sb_printf(&h, "  %-10s %s\n", cmds[i].name, cmds[i].help);
  sb_puts(&h,
          "\nSEARCH AND FILTER   / jumps to matches (n and N step through them);\n"
          "                    & narrows the list to them. Both take the same terms:\n"
          "  word  \"a phrase\"        in title, authors or subject\n"
          "  author:erdos  subject:number-theory  year:>1990  fmt:djvu\n"
          "  title:~^%d+%.%d+        ~ takes a Lua pattern;  = exact;  ^ prefix\n"
          "  text:\"class field\"      full text of the indexed pages\n"
          "  author:unknown  subject:none  no:ids  is:filetitle  is:marked\n"
          "  -term negates;  or  starts an alternative;  sort:-added orders\n"
          "\nA command acts on the range being selected, else on the marked books in\n"
          "the list, else on the book under the cursor.\n"
          "\nEvery key here can be changed in init.lua with lulibre.map: a command line for\n"
          "the keys at the top, an action name for the places listed after them.\n");
  tui_pager(t, "help", h.s);
  sb_free(&h);
}
