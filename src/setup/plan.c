/* The plan: setup.conf, a file of shell assignments install.sh sources.
 *
 *   LEVEL='user'
 *   opt 'pages' '8'
 *
 * Every value is written in single quotes (a quote inside as '\''), so
 * sourcing the file runs nothing but the assignments and `opt`, which
 * install.sh defines. Reading takes the same two forms back. */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "core/util.h"
#include "setup/setup.h"

static void put_quoted(FILE *f, const char *s) {
  fputc('\'', f);
  for (; *s; s++) {
    if (*s == '\'') fputs("'\\''", f);
    else fputc(*s, f);
  }
  fputc('\'', f);
}

int plan_save(const char *path, const struct item *items, int n, char **err) {
  char *tmp = xasprintf("%s.new", path);
  FILE *f = fopen(tmp, "w");
  if (!f) {
    *err = xasprintf("cannot write %s: %s", tmp, errstr(errno));
    free(tmp);
    return -1;
  }
  fputs("# lulibre-setup's plan: the choices made so far, kept between runs.\n"
        "# setup/install.sh carries it out: sh setup/install.sh [-n] setup.conf\n",
        f);
  for (int i = 0; i < n; i++) {
    const struct item *it = &items[i];
    if (!it->value || it->opt) continue;
    fprintf(f, "%s=", it->key);
    put_quoted(f, it->value);
    fputc('\n', f);
  }
  for (int i = 0; i < n; i++) {
    const struct item *it = &items[i];
    if (!it->value || !it->opt) continue;
    fputs("opt ", f);
    put_quoted(f, it->key);
    fputc(' ', f);
    put_quoted(f, it->value);
    fputc('\n', f);
  }
  int bad = ferror(f);
  if (fclose(f) != 0 || bad || rename(tmp, path) != 0) {
    *err = xasprintf("cannot write %s: %s", path, errstr(errno));
    remove(tmp);
    free(tmp);
    return -1;
  }
  free(tmp);
  return 0;
}

/* One word as the shell reads it: quoted parts ('...'), a backslash and the
 * character after it, and plain characters, up to a blank. Returns 1 and
 * the word in *out, or 0 at the end of the line. */
static int word(const char **p, sbuf *out) {
  const char *s = *p;
  while (*s == ' ' || *s == '\t') s++;
  if (!*s || *s == '\n' || *s == '#') {
    *p = s;
    return 0;
  }
  sb_reset(out);
  sb_puts(out, "");
  while (*s && *s != ' ' && *s != '\t' && *s != '\n') {
    if (*s == '\'') {
      const char *end = strchr(s + 1, '\'');
      if (!end) end = s + strlen(s);
      sb_putn(out, s + 1, (size_t)(end - s - 1));
      s = *end ? end + 1 : end;
    } else if (*s == '\\' && s[1]) {
      sb_putc(out, s[1]);
      s += 2;
    } else {
      sb_putc(out, *s++);
    }
  }
  *p = s;
  return 1;
}

static struct item *find(struct item *items, int n, const char *key, int opt) {
  for (int i = 0; i < n; i++)
    if (items[i].kind != K_HEAD && items[i].key && !strcmp(items[i].key, key) && !!items[i].opt == opt) return &items[i];
  return NULL;
}

int plan_load(const char *path, struct item *items, int n, char **err) {
  FILE *f = fopen(path, "r");
  if (!f) {
    if (errno == ENOENT) return 0;
    *err = xasprintf("cannot read %s: %s", path, errstr(errno));
    return -1;
  }
  char *line = NULL;
  size_t cap = 0;
  sbuf a = SBUF_INIT, b = SBUF_INIT;
  while (getline(&line, &cap, f) > 0) {
    const char *p = line;
    while (*p == ' ' || *p == '\t') p++;
    if (!strncmp(p, "opt ", 4)) {
      p += 4;
      if (!word(&p, &a) || !word(&p, &b)) continue;
      struct item *it = find(items, n, a.s, 1);
      if (it) {
        free(it->value);
        it->value = xstrdup(b.s);
      }
      continue;
    }
    const char *eq = strchr(p, '=');
    if (!eq || eq == p) continue;
    char *key = xstrndup(p, (size_t)(eq - p));
    const char *q = eq + 1;
    struct item *it = find(items, n, key, 0);
    if (it && word(&q, &a)) {
      free(it->value);
      it->value = xstrdup(a.s);
    }
    free(key);
  }
  free(line);
  sb_free(&a);
  sb_free(&b);
  fclose(f);
  return 0;
}
