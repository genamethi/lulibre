/* The guides, as vim's help: Markdown files in the folders of docs (each
 * searched with its subfolders), indexed by tags, read in the pager with
 * their links followed.
 *
 *   lulibre's docs/ (beside its Lua code, as installed or in a source tree)
 *   docs/ in the configuration folder (~/.config/lulibre/docs)
 *   docs/ in the data folder (~/.local/share/lulibre/docs)
 *
 * The tags of a file: its name ("keys", "keys.md"), each heading's text,
 * and what the first cell of a table's row names in `code`: a command as
 * :name in a table whose first column is "Command" (or whose second is, as
 * the key tables'), a setting as 'name' in one whose first is "Setting",
 * a key as it is written in one whose first is "Key", and the first word
 * of anything else (api.md's functions, filters.md's fields). A tag in an
 * earlier file of an earlier folder comes first; lulibre's are first, as
 * its modules are (design 6).
 *
 * :help TOPIC opens the file whose tag fits TOPIC best (the tag itself,
 * then the same without case, :TOPIC or 'TOPIC', a tag that begins with
 * it, one that holds it) at the tag's line; with no tag, the lines that
 * mention it, each a link. The index is made when first needed, and again
 * when a file has come, gone or changed. The interface thread's. */
#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include "app.h"
#include "core/util.h"
#include "match/fold.h"
#include "tui/tui.h"

struct gfile {
  char *path, *name, *title; /* name: from its folder, without .md */
  long long mtime;
};
struct gtag {
  char *tag, *folded;
  int file, line; /* the line from 1 */
};
static struct gfile *files;
static struct gtag *tags;
static int nfiles, ntags;

struct links {
  struct pager_link *v;
  int n, cap;
};

static void link_add(struct links *l, size_t off, size_t len, const char *target, size_t tlen) {
  if (!l) return;
  if (l->n == l->cap) {
    l->cap = l->cap ? l->cap * 2 : 16;
    l->v = xrealloc(l->v, (size_t)l->cap * sizeof *l->v);
  }
  l->v[l->n++] = (struct pager_link){off, len, xstrndup(target, tlen)};
}

static void links_free(struct links *l) {
  for (int i = 0; i < l->n; i++) free(l->v[i].target);
  free(l->v);
}

static char *slurp(const char *path) {
  FILE *f = fopen(path, "r");
  if (!f) return NULL;
  sbuf s = SBUF_INIT;
  char buf[8192];
  size_t n;
  while ((n = fread(buf, 1, sizeof buf, f)) > 0) sb_putn(&s, buf, n);
  fclose(f);
  return s.s ? sb_take(&s) : xstrdup("");
}

/* ---- Markdown, inline: `code`, **strong**, [text](target), <address> ---- */

static int is_punct(char c) {
  return c && strchr("\\`*_{}[]()#+-.!|<>~", c) != NULL;
}

/* s's text as shown, appended to out; each link's text, where it is in out,
 * is added to links (when not NULL) */
static void inline_md(sbuf *out, const char *s, size_t n, struct links *links) {
  for (size_t i = 0; i < n;) {
    char c = s[i];
    if (c == '\\' && i + 1 < n && is_punct(s[i + 1])) {
      sb_putc(out, s[i + 1]);
      i += 2;
    } else if (c == '`') {
      size_t run = 0;
      while (i + run < n && s[i + run] == '`') run++;
      size_t j = i + run, end = 0;
      for (; j + run <= n; j++)
        if (!strncmp(s + j, s + i, run) && (j + run == n || s[j + run] != '`')) {
          end = j;
          break;
        }
      if (!end) {
        sb_putn(out, s + i, run);
        i += run;
        continue;
      }
      size_t from = i + run, to = end;
      if (to > from && s[from] == ' ' && s[to - 1] == ' ' && to - from > 1) from++, to--;
      sb_putn(out, s + from, to - from);
      i = end + run;
    } else if (c == '*' && i + 1 < n && s[i + 1] == '*') {
      i += 2;
    } else if ((c == '[' || (c == '!' && i + 1 < n && s[i + 1] == '[')) ) {
      size_t open = c == '!' ? i + 1 : i, depth = 0, close = 0;
      for (size_t j = open; j < n; j++) {
        if (s[j] == '`') { /* a bracket in code is the code's */
          const char *e = memchr(s + j + 1, '`', n - j - 1);
          if (e) j = (size_t)(e - s);
          continue;
        }
        if (s[j] == '[') depth++;
        if (s[j] == ']' && --depth == 0) {
          close = j;
          break;
        }
      }
      const char *paren = close && close + 1 < n && s[close + 1] == '(' ? memchr(s + close + 2, ')', n - close - 2) : NULL;
      if (!paren) {
        sb_putc(out, c);
        i++;
        continue;
      }
      size_t at = out->len;
      inline_md(out, s + open + 1, close - open - 1, NULL);
      const char *target = s + close + 2;
      size_t tlen = strcspn(target, " )");
      if (c == '[') link_add(links, at, out->len - at, target, tlen);
      i = (size_t)(paren - s) + 1;
    } else if (c == '<' && i + 8 < n && (!strncmp(s + i + 1, "http", 4) || !strncmp(s + i + 1, "mailto:", 7))) {
      const char *gt = memchr(s + i, '>', n - i);
      if (!gt) {
        sb_putc(out, c);
        i++;
        continue;
      }
      size_t at = out->len, len = (size_t)(gt - s) - i - 1;
      sb_putn(out, s + i + 1, len);
      link_add(links, at, len, s + i + 1, len);
      i = (size_t)(gt - s) + 1;
    } else {
      sb_putc(out, c);
      i++;
    }
  }
}

static char *plain(const char *s, size_t n) {
  sbuf out = SBUF_INIT;
  inline_md(&out, s, n, NULL);
  return out.s ? sb_take(&out) : xstrdup("");
}

/* A heading's anchor as GitHub makes it: lower case, punctuation gone,
 * spaces as dashes. */
static char *slug(const char *text) {
  sbuf out = SBUF_INIT;
  for (const unsigned char *p = (const unsigned char *)text; *p; p++) {
    if (*p >= 'A' && *p <= 'Z') sb_putc(&out, (char)(*p - 'A' + 'a'));
    else if (*p == ' ') sb_putc(&out, '-');
    else if (*p >= 0x80 || (*p >= 'a' && *p <= 'z') || (*p >= '0' && *p <= '9') || *p == '-' || *p == '_')
      sb_putc(&out, (char)*p);
  }
  return out.s ? sb_take(&out) : xstrdup("");
}

/* ---- the lines of a file ---- */

struct mdline {
  const char *s;
  size_t len;
};

static int split_lines(const char *text, struct mdline **out) {
  int n = 0, cap = 64;
  struct mdline *v = xcalloc((size_t)cap, sizeof *v);
  for (const char *p = text; *p;) {
    size_t len = strcspn(p, "\n");
    if (n == cap) v = xrealloc(v, (size_t)(cap *= 2) * sizeof *v);
    v[n++] = (struct mdline){p, len};
    p += len + (p[len] == '\n');
  }
  *out = v;
  return n;
}

static int fence(const struct mdline *l) {
  size_t i = 0;
  while (i < l->len && l->s[i] == ' ') i++;
  return l->len - i >= 3 && !strncmp(l->s + i, "```", 3);
}

/* a heading's level, and where its text starts; 0 for a line that is not one */
static int heading(const struct mdline *l, size_t *text) {
  size_t h = 0;
  while (h < l->len && l->s[h] == '#') h++;
  if (!h || h > 6 || h >= l->len || l->s[h] != ' ') return 0;
  *text = h + 1;
  return (int)h;
}

static int table_row(const struct mdline *l) {
  return l->len > 1 && l->s[0] == '|';
}

static int table_rule(const struct mdline *l) {
  return table_row(l) && strspn(l->s, "|:- ") == l->len;
}

/* the cells of a table's row, without their bars and outer spaces; a bar in
 * code or after a backslash is the cell's */
static int cells(const struct mdline *l, const char **at, size_t *len, int max) {
  int n = 0, code = 0;
  size_t from = 1;
  for (size_t i = 1; i <= l->len && n < max; i++) {
    char c = i < l->len ? l->s[i] : '|';
    if (c == '`') code = !code;
    if (c == '\\' && i + 1 < l->len) {
      i++;
      continue;
    }
    if (c != '|' || code) continue;
    if (i == l->len && i == from) break; /* the bar that ends the row */
    size_t a = from, b = i;
    while (a < b && l->s[a] == ' ') a++;
    while (b > a && l->s[b - 1] == ' ') b--;
    at[n] = l->s + a;
    len[n++] = b - a;
    from = i + 1;
    if (i + 1 >= l->len) break;
  }
  return n;
}

/* ---- the index ---- */

static void add_tag(const char *tag, int file, int line) {
  if (!*tag) return;
  for (int i = 0; i < ntags; i++)
    if (!strcmp(tags[i].tag, tag)) return; /* the first file's */
  tags = xrealloc(tags, (size_t)(ntags + 1) * sizeof *tags);
  sbuf f = SBUF_INIT;
  fold_utf8(&f, tag, strlen(tag));
  tags[ntags++] = (struct gtag){xstrdup(tag), f.s ? sb_take(&f) : xstrdup(""), file, line};
}

/* the tags of the `code` in a table's first cell (and the second, when it
 * holds the commands of the keys in the first) */
static void cell_tags(const char *cell, size_t n, const char *kind, int file, int line) {
  for (const char *p = cell; p < cell + n;) {
    const char *open = memchr(p, '`', (size_t)(cell + n - p));
    if (!open) break;
    const char *close = memchr(open + 1, '`', (size_t)(cell + n - open - 1));
    if (!close) break;
    size_t len = (size_t)(close - open - 1), word = strcspn(open + 1, " ([");
    if (word > len) word = len;
    char *tag = !strcmp(kind, "key") ? xstrndup(open + 1, len)
                : !strcmp(kind, "command") ? xasprintf(":%.*s", (int)word, open + 1)
                : !strcmp(kind, "setting") ? xasprintf("'%.*s'", (int)word, open + 1)
                : xstrndup(open + 1, word);
    add_tag(tag, file, line);
    free(tag);
    p = close + 1;
  }
}

static void index_file(int file) {
  char *text = slurp(files[file].path);
  if (!text) return;
  struct mdline *l;
  int n = split_lines(text, &l), fenced = 0;
  add_tag(files[file].name, file, 1);
  char *md = xasprintf("%s.md", files[file].name);
  add_tag(md, file, 1);
  free(md);
  char head0[32] = "", head1[32] = "";
  for (int i = 0; i < n; i++) {
    if (fence(&l[i])) fenced = !fenced;
    if (fenced) continue;
    size_t at;
    if (heading(&l[i], &at)) {
      char *t = plain(l[i].s + at, l[i].len - at);
      if (!files[file].title) files[file].title = xstrdup(t);
      add_tag(t, file, i + 1);
      free(t);
    } else if (table_row(&l[i]) && i + 1 < n && table_rule(&l[i + 1])) { /* a table's head */
      const char *c[2];
      size_t len[2];
      int k = cells(&l[i], c, len, 2);
      snprintf(head0, sizeof head0, "%.*s", k > 0 ? (int)len[0] : 0, k > 0 ? c[0] : "");
      snprintf(head1, sizeof head1, "%.*s", k > 1 ? (int)len[1] : 0, k > 1 ? c[1] : "");
      for (char *p = head0; *p; p++) *p = (char)(*p >= 'A' && *p <= 'Z' ? *p - 'A' + 'a' : *p);
      i++;
    } else if (table_row(&l[i])) {
      const char *c[2];
      size_t len[2];
      int k = cells(&l[i], c, len, 2);
      if (k > 0) cell_tags(c[0], len[0], head0, file, i + 1);
      if (k > 1 && !strcmp(head1, "Command")) cell_tags(c[1], len[1], "command", file, i + 1);
    }
  }
  free(l);
  free(text);
}

static int doc_dirs(struct tui *t, char **dirs) {
  char *data = path_xdg("XDG_DATA_HOME", "~/.local/share/lulibre");
  dirs[0] = xasprintf("%s/../docs", lstate_runtime_modules());
  dirs[1] = xasprintf("%s/docs", t->app->config_dir);
  dirs[2] = xasprintf("%s/docs", data);
  free(data);
  return 3;
}

struct found {
  struct gfile *v;
  int n;
};

static int cmp_name(const void *a, const void *b) {
  return strcmp(*(char *const *)a, *(char *const *)b);
}

static void scan(const char *dir, const char *rel, struct found *f, int depth) {
  DIR *d = opendir(dir);
  if (!d || depth > 4) {
    if (d) closedir(d);
    return;
  }
  char **names = NULL;
  int n = 0;
  for (struct dirent *e; (e = readdir(d));)
    if (e->d_name[0] != '.') {
      names = xrealloc(names, (size_t)(n + 1) * sizeof *names);
      names[n++] = xstrdup(e->d_name);
    }
  closedir(d);
  qsort(names, (size_t)n, sizeof *names, cmp_name);
  for (int i = 0; i < n; i++) {
    char *path = xasprintf("%s/%s", dir, names[i]);
    char *name = *rel ? xasprintf("%s/%s", rel, names[i]) : xstrdup(names[i]);
    struct stat st;
    if (stat(path, &st) == 0 && S_ISDIR(st.st_mode)) {
      scan(path, name, f, depth + 1);
    } else if (stat(path, &st) == 0 && !strcmp(path_ext(path), "md")) {
      char real[4096];
      f->v = xrealloc(f->v, (size_t)(f->n + 1) * sizeof *f->v);
      name[strlen(name) - 3] = '\0';
      f->v[f->n++] = (struct gfile){xstrdup(realpath(path, real) ? real : path), xstrdup(name), NULL,
                                    (long long)st.st_mtim.tv_sec * 1000000000LL + st.st_mtim.tv_nsec};
    }
    free(path);
    free(name);
    free(names[i]);
  }
  free(names);
}

static void forget(void) {
  for (int i = 0; i < nfiles; i++) {
    free(files[i].path);
    free(files[i].name);
    free(files[i].title);
  }
  for (int i = 0; i < ntags; i++) {
    free(tags[i].tag);
    free(tags[i].folded);
  }
  free(files);
  free(tags);
  files = NULL;
  tags = NULL;
  nfiles = ntags = 0;
}

/* The index, made again when the files are not those it was made from. */
static void fresh(struct tui *t) {
  char *dirs[3];
  int nd = doc_dirs(t, dirs);
  struct found f = {0};
  for (int i = 0; i < nd; i++) {
    scan(dirs[i], "", &f, 0);
    free(dirs[i]);
  }
  int same = f.n == nfiles;
  for (int i = 0; same && i < f.n; i++) same = !strcmp(f.v[i].path, files[i].path) && f.v[i].mtime == files[i].mtime;
  if (same) {
    for (int i = 0; i < f.n; i++) {
      free(f.v[i].path);
      free(f.v[i].name);
    }
    free(f.v);
    return;
  }
  forget();
  files = f.v;
  nfiles = f.n;
  for (int i = 0; i < nfiles; i++) index_file(i);
}

void guides_forget(void) {
  forget();
}

/* the best tag for a topic, or -1; *also: how many others fit it */
static int lookup(const char *topic, int *also) {
  sbuf f = SBUF_INIT;
  fold_utf8(&f, topic, strlen(topic));
  const char *q = f.s ? f.s : "";
  size_t ql = strlen(q);
  int best = -1, best_rank = 99;
  *also = 0;
  for (int i = 0; i < ntags && ql; i++) {
    const char *tag = tags[i].tag, *ft = tags[i].folded;
    size_t tl = strlen(ft);
    int r = !strcmp(tag, topic) ? 0
            : !strcmp(ft, q) ? 1
            : (tl == ql + 1 && ft[0] == ':' && !strcmp(ft + 1, q)) ||
                      (tl == ql + 2 && ft[0] == '\'' && ft[tl - 1] == '\'' && !strncmp(ft + 1, q, ql)) ? 2
            : !strncmp(ft, q, ql) ? 3
            : strstr(ft, q) ? 4
            : -1;
    if (r < 0) continue;
    if (best >= 0) (*also)++;
    if (r < best_rank || (r == best_rank && strlen(tag) < strlen(tags[best].tag))) {
      best = i;
      best_rank = r;
    }
  }
  sb_free(&f);
  return best;
}

/* ---- a file, as the pager shows it ---- */

struct render {
  sbuf out;
  struct links links;
  int line;      /* lines in out so far */
  int *at;       /* for each line of the file (from 1), the line of out it is on */
  int nlines;    /* the file's */
  sbuf para;     /* a paragraph or a list item, joined into one line */
  char lead[16]; /* what goes before it */
};

static void put_line(struct render *r, const char *s, size_t n) {
  sb_putn(&r->out, s, n);
  sb_putc(&r->out, '\n');
  r->line++;
}

static int last_blank(const struct render *r) {
  return r->out.len == 0 || (r->out.len >= 2 && r->out.s[r->out.len - 2] == '\n');
}

static void flush(struct render *r) {
  if (!r->para.len) return;
  sb_puts(&r->out, r->lead);
  inline_md(&r->out, r->para.s, r->para.len, &r->links);
  sb_putc(&r->out, '\n');
  r->line++;
  sb_reset(&r->para);
}

/* A table: its cells side by side, each column as wide as its widest cell,
 * the last one wrapping under itself. When the columns before the last
 * would take more than TABLE_BUDGET of the width a guide is shown in (80
 * less its margins), the widest of them narrows; a cell wider than its
 * column goes on, and the row's next cell starts a line of its own below,
 * in its column. */
#define CELLS_MAX 8
#define TABLE_BUDGET 44

static int render_table(struct render *r, const struct mdline *l, int i, int n) {
  int end = i;
  while (end < n && table_row(&l[end])) end++;
  int rows = end - i, nc[64] = {0}, width[CELLS_MAX] = {0}, ncols = 0;
  if (rows > 64) rows = 64, end = i + 64;
  sbuf text[64][CELLS_MAX];
  struct links lk[64][CELLS_MAX];
  memset(text, 0, sizeof text);
  memset(lk, 0, sizeof lk);
  for (int k = 0; k < rows; k++) {
    if (table_rule(&l[i + k])) continue;
    const char *c[CELLS_MAX];
    size_t len[CELLS_MAX];
    nc[k] = cells(&l[i + k], c, len, CELLS_MAX);
    for (int j = 0; j < nc[k]; j++) {
      inline_md(&text[k][j], c[j], len[j], &lk[k][j]);
      int w = text[k][j].s ? dr_width(text[k][j].s, text[k][j].len) : 0;
      if (w > width[j]) width[j] = w;
    }
    if (nc[k] > ncols) ncols = nc[k];
  }
  for (;;) {
    int sum = 0, widest = 0;
    for (int j = 0; j < ncols - 1; j++) {
      sum += width[j] + 3;
      if (width[j] > width[widest]) widest = j;
    }
    if (sum <= TABLE_BUDGET || width[widest] <= 8) break;
    width[widest]--;
  }
  for (int k = 0; k < rows; k++) {
    r->at[i + k + 1] = r->line;
    if (table_rule(&l[i + k])) continue;
    int last = nc[k] - 1;
    while (last > 0 && !text[k][last].len) last--; /* nothing after the last cell with something in it */
    sb_puts(&r->out, "  ");
    for (int j = 0, col = 2; j <= last && nc[k]; j++) {
      size_t base = r->out.len;
      if (text[k][j].len) sb_putn(&r->out, text[k][j].s, text[k][j].len);
      for (int m = 0; m < lk[k][j].n; m++)
        link_add(&r->links, base + lk[k][j].v[m].off, lk[k][j].v[m].len, lk[k][j].v[m].target, strlen(lk[k][j].v[m].target));
      if (j == last) break;
      int w = text[k][j].s ? dr_width(text[k][j].s, text[k][j].len) : 0, pad = width[j] - w + 3;
      col += width[j] + 3;
      if (w > width[j]) { /* the next cell, below in its column */
        sb_putc(&r->out, '\n');
        r->line++;
        pad = col;
      }
      for (int p = 0; p < pad; p++) sb_putc(&r->out, ' ');
    }
    sb_putc(&r->out, '\n');
    r->line++;
  }
  for (int k = 0; k < rows; k++)
    for (int j = 0; j < CELLS_MAX; j++) {
      sb_free(&text[k][j]);
      links_free(&lk[k][j]);
    }
  return end;
}

/* the list item a line starts, if it does: its marker's end */
static size_t list_item(const struct mdline *l, size_t *indent) {
  size_t i = 0;
  while (i < l->len && l->s[i] == ' ') i++;
  *indent = i;
  if (i + 1 < l->len && strchr("-*+", l->s[i]) && l->s[i + 1] == ' ') return i + 2;
  size_t d = i;
  while (d < l->len && l->s[d] >= '0' && l->s[d] <= '9') d++;
  if (d > i && d + 1 < l->len && (l->s[d] == '.' || l->s[d] == ')') && l->s[d + 1] == ' ') return d + 2;
  return 0;
}

static void render(const char *text, struct render *r) {
  struct mdline *l;
  int n = split_lines(text, &l), fenced = 0, comment = 0;
  r->at = xcalloc((size_t)n + 2, sizeof *r->at);
  r->nlines = n;
  for (int i = 0; i < n;) {
    const struct mdline *ln = &l[i];
    r->at[i + 1] = r->line;
    size_t at, indent, item;
    int level;
    if (comment || (ln->len >= 4 && !strncmp(ln->s, "<!--", 4))) {
      comment = !(ln->len >= 3 && !strncmp(ln->s + ln->len - 3, "-->", 3));
      i++;
    } else if (fence(ln)) {
      flush(r);
      fenced = !fenced;
      i++;
    } else if (fenced) {
      sb_puts(&r->out, "    ");
      put_line(r, ln->s, ln->len);
      i++;
    } else if (strspn(ln->s, " ") >= ln->len) {
      flush(r);
      if (!last_blank(r)) put_line(r, "", 0);
      i++;
    } else if ((level = heading(ln, &at))) {
      flush(r);
      if (!last_blank(r)) put_line(r, "", 0);
      r->at[i + 1] = r->line;
      size_t from = r->out.len;
      inline_md(&r->out, ln->s + at, ln->len - at, &r->links);
      if (level <= 2)
        for (size_t k = from; k < r->out.len; k++)
          if (r->out.s[k] >= 'a' && r->out.s[k] <= 'z') r->out.s[k] = (char)(r->out.s[k] - 'a' + 'A');
      sb_putc(&r->out, '\n');
      r->line++;
      i++;
    } else if (table_row(ln)) {
      flush(r);
      i = render_table(r, l, i, n);
    } else if ((item = list_item(ln, &indent))) {
      flush(r);
      snprintf(r->lead, sizeof r->lead, "%*s- ", (int)(indent < 8 ? indent + 2 : 10), "");
      sb_putn(&r->para, ln->s + item, ln->len - item);
      i++;
    } else {
      size_t skip = strspn(ln->s, " >");
      if (skip > ln->len) skip = ln->len;
      if (!r->para.len) snprintf(r->lead, sizeof r->lead, "  ");
      else sb_putc(&r->para, ' ');
      sb_putn(&r->para, ln->s + skip, ln->len - skip);
      i++;
    }
  }
  flush(r);
  r->at[n + 1] = r->line;
  free(l);
}

static const struct gfile *file_of(const char *path) {
  for (int i = 0; i < nfiles; i++)
    if (!strcmp(files[i].path, path)) return &files[i];
  return NULL;
}

/* The file in the pager, with line `line` of it (from 1; 0: the top) at the
 * top. 0 when it cannot be read (and said). */
static int show(struct tui *t, const char *path, int line) {
  char *text = slurp(path);
  if (!text) {
    tui_msg(t, 1, "cannot read the guide %s", path);
    return 0;
  }
  struct render r = {0};
  render(text, &r);
  const struct gfile *g = file_of(path);
  const char *slash = strrchr(path, '/');
  char *title = xasprintf("help: %s", g ? g->name : slash ? slash + 1 : path);
  tui_pager_folded(t, title, r.out.s ? r.out.s : "", -1);
  tui_pager_links(t, r.links.v, r.links.n, path);
  if (line > 0) tui_pager_at(t, r.at[line <= r.nlines + 1 ? line : r.nlines + 1]);
  free(title);
  free(r.at);
  sb_free(&r.out);
  sb_free(&r.para);
  free(text);
  return 1;
}

/* the line (from 1) of the heading whose anchor is `anchor`, or 0 */
static int anchor_line(const char *path, const char *anchor, size_t n) {
  char *text = slurp(path);
  if (!text) return 0;
  struct mdline *l;
  int nl = split_lines(text, &l), found = 0, fenced = 0;
  for (int i = 0; i < nl && !found; i++) {
    if (fence(&l[i])) fenced = !fenced;
    size_t at;
    if (fenced || !heading(&l[i], &at)) continue;
    char *t = plain(l[i].s + at, l[i].len - at), *s = slug(t);
    if (strlen(s) == n && !strncmp(s, anchor, n)) found = i + 1;
    free(t);
    free(s);
  }
  free(l);
  free(text);
  return found;
}

/* One link: 1 when it was shown, 0 when it names nothing, -1 when it was
 * said why it is not followed. */
static int follow_one(struct tui *t, const char *target, size_t n, const char *from) {
  if ((n > 7 && !strncmp(target, "http://", 7)) || (n > 8 && !strncmp(target, "https://", 8)) ||
      (n > 7 && !strncmp(target, "mailto:", 7))) {
    tui_msg(t, 0, "outside lulibre: %.*s", (int)n, target);
    return -1;
  }
  const char *hash = memchr(target, '#', n), *md = NULL;
  for (const char *p = target; p + 3 <= target + n; p++)
    if (!strncmp(p, ".md", 3) && (p + 3 == target + n || p[3] == '#' || p[3] == ':')) md = p + 3;
  if (md || (hash == target && from)) {
    char *path;
    size_t flen = md ? (size_t)(md - target) : 0;
    if (!md) path = xstrdup(from);
    else if (target[0] == '/') path = xstrndup(target, flen);
    else {
      /* beside the file it is in; else a guide of that name, in any folder */
      const char *slash = from ? strrchr(from, '/') : NULL;
      path = slash ? xasprintf("%.*s/%.*s", (int)(slash - from), from, (int)flen, target) : xstrndup(target, flen);
      struct stat st;
      for (int i = 0; i < nfiles && stat(path, &st) != 0; i++)
        if (strlen(files[i].name) + 3 == flen && !strncmp(files[i].name, target, flen - 3)) {
          free(path);
          path = xstrdup(files[i].path);
        }
    }
    char real[4096];
    if (realpath(path, real)) {
      free(path);
      path = xstrdup(real);
    }
    const char *rest = target + flen, *end = target + n;
    int line = 0;
    if (rest < end && *rest == '#') line = anchor_line(path, rest + 1, (size_t)(end - rest - 1));
    else if (rest < end && *rest == ':') line = atoi(rest + 1);
    struct stat st;
    int ok = stat(path, &st) == 0 && show(t, path, line);
    free(path);
    return ok ? 1 : -1;
  }
  if (n > 5 && strchr(target, '.') && !memchr(target, ' ', n) && memchr(target, '/', n)) {
    tui_msg(t, 0, "not a guide: %.*s", (int)n, target);
    return -1;
  }
  char *topic = xstrndup(target, n);
  int also, best = lookup(topic, &also);
  free(topic);
  return best >= 0 && show(t, files[tags[best].file].path, tags[best].line) ? 1 : 0;
}

int guides_follow(struct tui *t, const char *target, const char *from) {
  fresh(t);
  for (const char *p = target; *p;) {
    size_t n = strcspn(p, "\n");
    int r = n ? follow_one(t, p, n, from) : 0;
    if (r) return r > 0;
    p += n + (p[n] == '\n');
  }
  tui_msg(t, 0, "the guides have nothing under %.*s", (int)strcspn(target, "\n"), target);
  return 0;
}

/* no tag fits: the lines of the guides that mention the topic, each a link */
static int mentions(struct tui *t, const char *topic) {
  sbuf q = SBUF_INIT, out = SBUF_INIT;
  struct links lk = {0};
  fold_utf8(&q, topic, strlen(topic));
  int found = 0;
  sb_printf(&out, "NO GUIDE HAS A TAG FOR '%s'; THESE LINES MENTION IT\n", topic);
  for (int f = 0; f < nfiles && found < 200; f++) {
    char *text = slurp(files[f].path);
    struct mdline *l = NULL;
    int n = text ? split_lines(text, &l) : 0;
    for (int i = 0; i < n && found < 200; i++) {
      sbuf fl = SBUF_INIT;
      fold_utf8(&fl, l[i].s, l[i].len);
      int hit = fl.s && q.s && strstr(fl.s, q.s);
      sb_free(&fl);
      if (!hit) continue;
      char *where = xasprintf("%s:%d", files[f].name, i + 1), *target = xasprintf("%s:%d", files[f].path, i + 1);
      sb_puts(&out, "  ");
      link_add(&lk, out.len, strlen(where), target, strlen(target));
      sb_printf(&out, "%-18s ", where);
      if (table_row(&l[i])) { /* a table's row: its cells, apart */
        const char *c[CELLS_MAX];
        size_t len[CELLS_MAX];
        int nc = cells(&l[i], c, len, CELLS_MAX);
        for (int j = 0; j < nc; j++) {
          if (j && len[j]) sb_puts(&out, "   ");
          inline_md(&out, c[j], len[j], NULL);
        }
      } else {
        size_t skip = strspn(l[i].s, " #>-");
        inline_md(&out, l[i].s + skip, l[i].len - skip, NULL);
      }
      sb_putc(&out, '\n');
      found++;
      free(where);
      free(target);
    }
    free(l);
    free(text);
  }
  if (found) {
    char *title = xasprintf("help: %s", topic);
    tui_pager_folded(t, title, out.s, -1);
    tui_pager_links(t, lk.v, lk.n, NULL);
    free(title);
  } else {
    links_free(&lk);
    tui_msg(t, 0, "the guides say nothing about '%s'", topic);
  }
  sb_free(&q);
  sb_free(&out);
  return found > 0;
}

static int help_topic(struct tui *t, const char *topic) {
  if (!nfiles) {
    tui_msg(t, 1, "no guides are installed: lulibre's docs/ is not beside its Lua code");
    return 0;
  }
  int also, best = lookup(topic, &also);
  if (best < 0) return mentions(t, topic);
  if (!show(t, files[tags[best].file].path, tags[best].line)) return 0;
  if (also) tui_msg(t, 0, "%s: the best of %d tags that fit '%s'", tags[best].tag, also + 1, topic);
  return 1;
}

int guides_help(struct tui *t, const char *args) {
  fresh(t);
  char *topic = xstrdup(args);
  for (size_t n = strlen(topic); n && topic[n - 1] == ' ';) topic[--n] = '\0';
  int shown = help_topic(t, topic);
  free(topic);
  return shown;
}

void guides_list(struct tui *t, sbuf *text, struct pager_link **links, int *nlinks) {
  fresh(t);
  struct links lk = {*links, *nlinks, *nlinks};
  sb_puts(text, "GUIDES   :help TOPIC; K follows a link, <C-t> goes back\n");
  for (int i = 0; i < nfiles; i++) {
    sb_puts(text, "  ");
    link_add(&lk, text->len, strlen(files[i].name), files[i].path, strlen(files[i].path));
    sb_printf(text, "%-18s %s\n", files[i].name, files[i].title ? files[i].title : "");
  }
  if (!nfiles) sb_puts(text, "  none are installed: lulibre's docs/ is not beside its Lua code\n");
  *links = lk.v;
  *nlinks = lk.n;
}

char *guides_tags(struct tui *t) {
  fresh(t);
  sbuf out = SBUF_INIT;
  for (int i = 0; i < ntags; i++) {
    if (strchr(tags[i].tag, '\n')) continue;
    sb_puts(&out, tags[i].tag);
    sb_putc(&out, '\n');
  }
  return out.s ? sb_take(&out) : xstrdup("");
}
