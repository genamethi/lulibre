/* Browsing the file system for a folder or a file, over the whole screen.
 * Folders come first, then files; names that begin with a dot come after
 * the others, dimmed, and `.` hides them. */
#include <dirent.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "core/util.h"
#include "setup/setup.h"
#include "tui/tui.h"

struct entry {
  char *name;
  int dir, hidden;
};

struct browser {
  char *dir;
  struct entry *e;
  int n, cap;
  int cur, top;
  int want_dir, show_hidden;
  char *msg;
};

static int cmp(const void *a, const void *b) {
  const struct entry *x = a, *y = b;
  if (x->dir != y->dir) return y->dir - x->dir;
  if (x->hidden != y->hidden) return x->hidden - y->hidden;
  return strcoll(x->name, y->name);
}

static void clear(struct browser *b) {
  for (int i = 0; i < b->n; i++) free(b->e[i].name);
  b->n = 0;
}

static void add(struct browser *b, const char *name, int dir, int hidden) {
  if (b->n == b->cap) {
    b->cap = b->cap ? b->cap * 2 : 64;
    b->e = xrealloc(b->e, (size_t)b->cap * sizeof *b->e);
  }
  b->e[b->n++] = (struct entry){xstrdup(name), dir, hidden};
}

/* Reads b->dir. The first rows: "choose this folder" when a folder is
 * wanted, and ".." below the root. The cursor goes to `select` if named. */
static void load(struct browser *b, const char *select) {
  clear(b);
  if (b->want_dir) add(b, "", 1, 0); /* the row that chooses this folder */
  if (strcmp(b->dir, "/")) add(b, "..", 1, 0);
  int fixed = b->n;
  DIR *d = opendir(b->dir);
  if (!d) {
    free(b->msg);
    b->msg = xasprintf("cannot read %s", b->dir);
  } else {
    struct dirent *de;
    while ((de = readdir(d))) {
      if (!strcmp(de->d_name, ".") || !strcmp(de->d_name, "..")) continue;
      int hidden = de->d_name[0] == '.';
      if (hidden && !b->show_hidden) continue;
      char *p = xasprintf("%s/%s", strcmp(b->dir, "/") ? b->dir : "", de->d_name);
      struct stat st;
      int dir = stat(p, &st) == 0 && S_ISDIR(st.st_mode);
      free(p);
      if (b->want_dir && !dir) continue;
      add(b, de->d_name, dir, hidden);
    }
    closedir(d);
  }
  qsort(b->e + fixed, (size_t)(b->n - fixed), sizeof *b->e, cmp);
  b->cur = b->top = 0;
  if (b->n > fixed) b->cur = fixed;
  for (int i = 0; select && i < b->n; i++)
    if (!strcmp(b->e[i].name, select)) b->cur = i;
}

static void go(struct browser *b, const char *path, const char *select) {
  char real[PATH_MAX];
  if (!realpath(path, real)) {
    free(b->msg);
    b->msg = xasprintf("no folder %s", path);
    return;
  }
  free(b->dir);
  b->dir = xstrdup(real);
  load(b, select);
}

static void up(struct browser *b) {
  if (!strcmp(b->dir, "/")) return;
  char *slash = strrchr(b->dir, '/');
  char *name = xstrdup(slash + 1);
  char *parent = slash == b->dir ? xstrdup("/") : xstrndup(b->dir, (size_t)(slash - b->dir));
  go(b, parent, name);
  free(parent);
  free(name);
}

static char *path_of(const struct browser *b, const char *name) {
  return xasprintf("%s/%s", strcmp(b->dir, "/") ? b->dir : "", name);
}

static void draw(struct notcurses *nc, struct browser *b, const char *title) {
  struct ncplane *n = notcurses_stdplane(nc);
  unsigned rows, cols;
  ncplane_dim_yx(n, &rows, &cols);
  int w = (int)cols, list = (int)rows - 3;
  if (list < 1) list = 1;
  ncplane_erase(n);
  dr_bar(n, (struct rect){0, 0, 1, w}, 1);
  int x = dr_text(n, 0, 1, w - 2, title);
  dr_style(n, theme.on_accent, theme.accent, 0);
  dr_text(n, 0, x + 3, w - x - 4, b->dir);
  if (b->cur < b->top) b->top = b->cur;
  if (b->cur >= b->top + list) b->top = b->cur - list + 1;
  for (int r = 0; r < list && b->top + r < b->n; r++) {
    const struct entry *e = &b->e[b->top + r];
    int cursor = b->top + r == b->cur;
    int fg = e->hidden ? theme.dim : !e->name[0] ? theme.ok : e->dir ? theme.accent : C_DEFAULT;
    dr_style(n, fg, cursor ? theme.cursor_bg : C_DEFAULT, e->dir && !e->hidden ? A_BOLD : 0);
    dr_fill(n, 1 + r, 0, w);
    if (!e->name[0]) {
      dr_text(n, 1 + r, 2, w - 3, "[ choose this folder ]");
    } else {
      char *s = xasprintf("%s%s", e->name, e->dir ? "/" : "");
      dr_text(n, 1 + r, 2, w - 3, s);
      free(s);
    }
  }
  dr_style(n, b->msg ? theme.warn : theme.dim, C_DEFAULT, 0);
  dr_fill(n, (int)rows - 2, 0, w);
  if (b->msg) dr_text(n, (int)rows - 2, 1, w - 2, b->msg);
  dr_style(n, theme.dim, C_DEFAULT, 0);
  dr_fill(n, (int)rows - 1, 0, w);
  dr_text(n, (int)rows - 1, 1, w - 2,
          b->want_dir ? "Enter open   Space choose the folder under the cursor   h up   ~ home   / type a path   . dotfiles   Esc back"
                      : "Enter open or choose   h up   ~ home   / type a path   . dotfiles   Esc back");
  notcurses_render(nc);
}

char *browse(struct notcurses *nc, const char *title, const char *start, int want_dir) {
  struct browser b = {0};
  b.want_dir = want_dir;
  b.show_hidden = 1;
  char *from = path_expand(start && start[0] ? start : "~");
  struct stat st;
  char *select = NULL;
  if (stat(from, &st) != 0 || !S_ISDIR(st.st_mode)) {
    /* a file, or a path that is not there: begin in the folder above it */
    char *slash = strrchr(from, '/');
    if (slash) {
      select = xstrdup(slash + 1);
      *slash = '\0';
      if (!from[0]) strcpy(from, "/");
    }
  }
  go(&b, from, select);
  if (!b.dir) {
    char *home = path_expand("~");
    go(&b, home, NULL);
    free(home);
  }
  free(from);
  free(select);
  char *out = NULL;
  int list = 1;
  while (b.dir) {
    draw(nc, &b, title);
    unsigned rows, cols;
    ncplane_dim_yx(notcurses_stdplane(nc), &rows, &cols);
    list = (int)rows - 3 > 0 ? (int)rows - 3 : 1;
    struct ncinput ni;
    if (notcurses_get_blocking(nc, &ni) == (uint32_t)-1) break;
    uint32_t k = key_of(&ni);
    if (!k || k == NCKEY_RESIZE) continue;
    free(b.msg);
    b.msg = NULL;
    if (k == NCKEY_ESC || k == 'q' || k == (KEY_CTRL | 'c')) break;
    if (k == 'j' || k == NCKEY_DOWN) b.cur += b.cur + 1 < b.n;
    else if (k == 'k' || k == NCKEY_UP) b.cur -= b.cur > 0;
    else if (k == 'g' || k == NCKEY_HOME) b.cur = 0;
    else if (k == 'G' || k == NCKEY_END) b.cur = b.n - 1;
    else if (k == (KEY_CTRL | 'd') || k == NCKEY_PGDOWN) b.cur = b.cur + list / 2 < b.n ? b.cur + list / 2 : b.n - 1;
    else if (k == (KEY_CTRL | 'u') || k == NCKEY_PGUP) b.cur = b.cur - list / 2 > 0 ? b.cur - list / 2 : 0;
    else if (k == 'h' || k == NCKEY_LEFT || k == NCKEY_BACKSPACE || k == '-') up(&b);
    else if (k == '~') {
      char *home = path_expand("~");
      go(&b, home, NULL);
      free(home);
    } else if (k == '.') {
      b.show_hidden = !b.show_hidden;
      char *keep = b.n ? xstrdup(b.e[b.cur].name) : NULL;
      load(&b, keep);
      free(keep);
    } else if (k == '/') {
      char *start_at = xasprintf("%s/", strcmp(b.dir, "/") ? b.dir : "");
      char *typed = line_edit(nc, want_dir ? "folder: " : "file: ", start_at, 1);
      free(start_at);
      if (typed && typed[0]) {
        char *p = path_expand(typed);
        if (stat(p, &st) == 0 && S_ISDIR(st.st_mode)) {
          go(&b, p, NULL);
        } else if (!want_dir && stat(p, &st) == 0) {
          out = p;
          p = NULL;
        } else {
          b.msg = xasprintf("no %s %s", want_dir ? "folder" : "file", p);
        }
        free(p);
      }
      free(typed);
      if (out) break;
    } else if (k == ' ' && want_dir && b.n && strcmp(b.e[b.cur].name, "..")) {
      out = b.e[b.cur].name[0] ? path_of(&b, b.e[b.cur].name) : xstrdup(b.dir);
      break;
    } else if ((k == NCKEY_ENTER || k == 'l' || k == NCKEY_RIGHT) && b.n) {
      const struct entry *e = &b.e[b.cur];
      if (!e->name[0]) {
        if (k == NCKEY_ENTER) {
          out = xstrdup(b.dir);
          break;
        }
      } else if (!strcmp(e->name, "..")) {
        up(&b);
      } else if (e->dir) {
        char *p = path_of(&b, e->name);
        go(&b, p, NULL);
        free(p);
      } else if (k == NCKEY_ENTER) {
        out = path_of(&b, e->name);
        break;
      }
    }
  }
  clear(&b);
  free(b.e);
  free(b.dir);
  free(b.msg);
  return out;
}
