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
 * when a file has come, gone or changed. A guide is shown as md_render lays
 * it out (rich.c), and its tags are read from that: its headings, and the
 * `code` in its tables' cells. The interface thread's. */
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
  int file, line; /* the line as shown, from 0 */
};
static struct gfile *files;
static struct gtag *tags;
static int nfiles, ntags;

static char *slurp(const char *path, size_t *len) {
  FILE *f = fopen(path, "r");
  if (!f) return NULL;
  sbuf s = SBUF_INIT;
  char buf[8192];
  size_t n;
  while ((n = fread(buf, 1, sizeof buf, f)) > 0) sb_putn(&s, buf, n);
  fclose(f);
  *len = s.len;
  return s.s ? sb_take(&s) : xstrdup("");
}

/* a guide as the pager shows it; 0 when it cannot be read */
static int render(const char *path, struct rich *r) {
  size_t len;
  char *text = slurp(path, &len);
  if (!text) return 0;
  md_render(text, len, PAGER_WIDTH, r);
  free(text);
  return 1;
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

/* the tags of the `code` in a table's cell: a command as :name, a setting
 * as 'name', a key as it is written, else the first word */
static void cell_tags(const struct rich *r, const struct rich_cell *c, const char *kind, int file, int line) {
  for (int i = 0; i < r->nspans; i++) {
    const struct rich_span *sp = &r->spans[i];
    if (!(sp->style & RS_CODE) || sp->off < c->off || sp->off + sp->len > c->off + c->len) continue;
    const char *s = r->text.s + sp->off;
    size_t word = strcspn(s, " (["), len = sp->len;
    if (word > len) word = len;
    char *tag = !strcmp(kind, "key") ? xstrndup(s, len)
                : !strcmp(kind, "command") ? xasprintf(":%.*s", (int)word, s)
                : !strcmp(kind, "setting") ? xasprintf("'%.*s'", (int)word, s)
                : xstrndup(s, word);
    add_tag(tag, file, line);
    free(tag);
  }
}

static void index_file(int file) {
  struct rich r;
  if (!render(files[file].path, &r)) return;
  add_tag(files[file].name, file, 0);
  char *md = xasprintf("%s.md", files[file].name);
  add_tag(md, file, 0);
  free(md);
  for (int i = 0; i < r.nheads; i++) {
    if (!files[file].title) files[file].title = xstrdup(r.heads[i].text);
    add_tag(r.heads[i].text, file, r.heads[i].line);
  }
  char head0[32] = "", head1[32] = "";
  for (int i = 0; i < r.nrows; i++) {
    const struct rich_row *row = &r.rows[i];
    if (row->head) { /* the head says what the first column names */
      const struct rich_cell *c = row->cells;
      snprintf(head0, sizeof head0, "%.*s", row->ncells > 0 ? (int)c[0].len : 0, row->ncells > 0 ? r.text.s + c[0].off : "");
      snprintf(head1, sizeof head1, "%.*s", row->ncells > 1 ? (int)c[1].len : 0, row->ncells > 1 ? r.text.s + c[1].off : "");
      for (char *p = head0; *p; p++) *p = (char)(*p >= 'A' && *p <= 'Z' ? *p - 'A' + 'a' : *p);
      continue;
    }
    if (row->ncells > 0) cell_tags(&r, &row->cells[0], head0, file, row->line);
    if (row->ncells > 1 && !strcmp(head1, "Command")) cell_tags(&r, &row->cells[1], "command", file, row->line);
  }
  rich_free(&r);
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

static int found_one(const char *path, const char *rel, const struct stat *st, void *ud) {
  struct found *f = ud;
  if (S_ISDIR(st->st_mode)) return 1;
  if (strcmp(path_ext(path), "md")) return 0;
  char real[4096];
  f->v = xrealloc(f->v, (size_t)(f->n + 1) * sizeof *f->v);
  f->v[f->n++] = (struct gfile){xstrdup(realpath(path, real) ? real : path), xstrndup(rel, strlen(rel) - 3), NULL,
                                (long long)st->st_mtim.tv_sec * 1000000000LL + st->st_mtim.tv_nsec};
  return 0;
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
    path_walk(dirs[i], 4, found_one, &f);
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

static const struct gfile *file_of(const char *path) {
  for (int i = 0; i < nfiles; i++)
    if (!strcmp(files[i].path, path)) return &files[i];
  return NULL;
}

/* The file in the pager, with its line `line` (from 0, as shown) at the
 * top. 0 when it cannot be read (and said). */
static int show(struct tui *t, const char *path, int line) {
  struct rich r;
  if (!render(path, &r)) {
    tui_msg(t, 1, "cannot read the guide %s", path);
    return 0;
  }
  const struct gfile *g = file_of(path);
  const char *slash = strrchr(path, '/');
  char *title = xasprintf("help: %s", g ? g->name : slash ? slash + 1 : path);
  tui_pager_rich(t, title, &r, -1, path);
  tui_pager_at(t, line);
  free(title);
  return 1;
}

/* the line, as shown, that line `src` of the file is in */
static int source_line(const char *path, int src) {
  struct rich r;
  if (!render(path, &r)) return 0;
  int line = rich_line_of(&r, src);
  rich_free(&r);
  return line;
}

/* the line of the heading whose anchor is `anchor`, or 0 */
static int anchor_line(const char *path, const char *anchor, size_t n) {
  struct rich r;
  if (!render(path, &r)) return 0;
  int found = 0;
  for (int i = 0; i < r.nheads && !found; i++)
    if (strlen(r.heads[i].anchor) == n && !strncmp(r.heads[i].anchor, anchor, n)) found = r.heads[i].line;
  rich_free(&r);
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
    else if (rest < end && *rest == ':') line = source_line(path, atoi(rest + 1));
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

/* the line of the source, from 1, that line i of r (made from it) has the
 * folded word q on: the first of those it comes from that holds it */
static int source_hit(const char *source, const struct rich *r, int i, const char *q) {
  int from = r->src[i], to = from + 1;
  for (int j = i + 1; j < r->nlines && to == from + 1; j++)
    if (r->src[j] > from) to = r->src[j];
  const char *p = source;
  for (int line = 1; *p && line < to; line++) {
    size_t len = strcspn(p, "\n");
    if (line >= from) {
      sbuf fl = SBUF_INIT;
      fold_utf8(&fl, p, len);
      int hit = fl.s && strstr(fl.s, q);
      sb_free(&fl);
      if (hit) return line;
    }
    p += len + (p[len] == '\n');
  }
  return from;
}

/* no tag fits: the lines of the guides, as shown, that mention the topic,
 * each a link to the file at its line (as grep has it: name:line) */
static int mentions(struct tui *t, const char *topic) {
  sbuf q = SBUF_INIT;
  struct rich out = {0};
  fold_utf8(&q, topic, strlen(topic));
  int found = 0;
  sb_printf(&out.text, "NO GUIDE HAS A TAG FOR '%s'; THESE LINES MENTION IT\n", topic);
  for (int f = 0; f < nfiles && found < 200; f++) {
    size_t n;
    char *source = slurp(files[f].path, &n);
    if (!source) continue;
    struct rich r;
    md_render(source, n, PAGER_WIDTH, &r);
    const char *p = r.text.s ? r.text.s : "";
    for (int i = 0; *p && found < 200; i++) {
      size_t len = strcspn(p, "\n");
      sbuf fl = SBUF_INIT;
      fold_utf8(&fl, p, len);
      if (fl.s && q.s && strstr(fl.s, q.s)) {
        int at = source_hit(source, &r, i, q.s);
        char *where = xasprintf("%s.md:%d", files[f].name, at), *target = xasprintf("%s:%d", files[f].path, at);
        sb_puts(&out.text, "  ");
        rich_link(&out, out.text.len, strlen(where), target);
        size_t skip = strspn(p, " ");
        sb_printf(&out.text, "%-18s %.*s\n", where, (int)(len - skip), p + skip);
        found++;
        free(where);
        free(target);
      }
      sb_free(&fl);
      p += len + (p[len] == '\n');
    }
    rich_free(&r);
    free(source);
  }
  if (found) {
    char *title = xasprintf("help: %s", topic);
    rich_plain(&out);
    tui_pager_rich(t, title, &out, -1, NULL);
    free(title);
  } else {
    rich_free(&out);
    tui_msg(t, 0, "the guides say nothing about '%s'", topic);
  }
  sb_free(&q);
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

void guides_list(struct tui *t, struct rich *text) {
  fresh(t);
  sb_puts(&text->text, "GUIDES   :help TOPIC; K follows a link, <C-t> goes back\n");
  for (int i = 0; i < nfiles; i++) {
    sb_puts(&text->text, "  ");
    rich_link(text, text->text.len, strlen(files[i].name), files[i].path);
    sb_printf(&text->text, "%-18s %s\n", files[i].name, files[i].title ? files[i].title : "");
  }
  if (!nfiles) sb_puts(&text->text, "  none are installed: lulibre's docs/ is not beside its Lua code\n");
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
