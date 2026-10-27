#include "core/settings.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "core/log.h"
#include "core/util.h"

struct entry {
  union setting_value v;
  enum setting_origin from;
  char *keep; /* the text saved: from the Lua API or the state; NULL = none */
};

struct settings {
  const struct setting_def *defs;
  int n;
  struct entry *e;
};

static int is_text(enum setting_type t) {
  return t == SETTING_STR || t == SETTING_PATH;
}

static int in_choices(const char *choices, const char *text) {
  size_t len = strlen(text);
  for (const char *c = choices; *c;) {
    const char *bar = strchr(c, '|');
    size_t n = bar ? (size_t)(bar - c) : strlen(c);
    if (n == len && !strncmp(c, text, n)) return 1;
    if (!bar) break;
    c = bar + 1;
  }
  return 0;
}

static int parse_bool(const char *t) {
  static const char *yes[] = {"true", "on", "yes", "1"}, *no[] = {"false", "off", "no", "0"};
  for (int i = 0; i < 4; i++) {
    if (!strcmp(t, yes[i])) return 1;
    if (!strcmp(t, no[i])) return 0;
  }
  return -1;
}

static int parse(const struct setting_def *d, const char *text, union setting_value *out, char **err) {
  if (d->choices && !in_choices(d->choices, text)) {
    *err = xasprintf("%s: %s is not one of %s", d->name, text, d->choices);
    return -1;
  }
  char *end;
  switch (d->type) {
  case SETTING_STR:
    out->s = xstrdup(text);
    return 0;
  case SETTING_PATH:
    out->s = path_expand(text);
    return 0;
  case SETTING_INT:
    errno = 0;
    out->i = strtoll(text, &end, 10);
    if (!*text || *end || errno) break;
    return 0;
  case SETTING_NUM:
    errno = 0;
    out->n = strtod(text, &end);
    if (!*text || *end || errno) break;
    return 0;
  case SETTING_BOOL:
    out->b = parse_bool(text);
    if (out->b < 0) break;
    return 0;
  }
  static const char *what[] = {[SETTING_INT] = "a whole number", [SETTING_NUM] = "a number",
                               [SETTING_BOOL] = "true or false"};
  *err = xasprintf("%s: %s is not %s", d->name, text, what[d->type]);
  return -1;
}

static void drop(const struct setting_def *d, union setting_value *v) {
  if (is_text(d->type)) free(v->s);
}

struct settings *settings_new(const struct setting_def *defs, int ndefs) {
  struct settings *st = xcalloc(1, sizeof *st);
  st->defs = defs;
  st->n = ndefs;
  st->e = xcalloc(ndefs, sizeof *st->e);
  for (int i = 0; i < ndefs; i++) {
    char *err = NULL;
    if (parse(&defs[i], defs[i].dflt, &st->e[i].v, &err)) die("the default of %s", err);
  }
  return st;
}

void settings_free(struct settings *st) {
  if (!st) return;
  for (int i = 0; i < st->n; i++) {
    drop(&st->defs[i], &st->e[i].v);
    free(st->e[i].keep);
  }
  free(st->e);
  free(st);
}

int settings_find(const struct settings *st, const char *name) {
  for (int i = 0; i < st->n; i++)
    if (!strcmp(st->defs[i].name, name)) return i;
  return -1;
}

const struct setting_def *settings_def(const struct settings *st, int def) {
  return &st->defs[def];
}

enum setting_origin settings_origin(const struct settings *st, int def) {
  return st->e[def].from;
}

/* The change, already valid, to this copy. */
static void change(struct settings *st, int i, enum setting_origin from, const char *text) {
  const struct setting_def *d = &st->defs[i];
  struct entry *e = &st->e[i];
  if (from == FROM_API || from == FROM_STATE) {
    free(e->keep);
    e->keep = xstrdup(text);
  }
  if (from == FROM_API && d->when == SETTING_AT_START) return;
  union setting_value v;
  char *err = NULL;
  if (parse(d, text, &v, &err)) { /* valid where it was made; this build agrees */
    free(err);
    return;
  }
  drop(d, &e->v);
  e->v = v;
  e->from = from;
}

int settings_set(struct settings *st, const char *name, const char *text, enum setting_origin from,
                 struct setting_change *out, char **err) {
  out->def = -1;
  out->text = NULL;
  int i = settings_find(st, name);
  if (i < 0) {
    *err = xasprintf("no setting is called %s", name);
    return -1;
  }
  union setting_value v;
  if (parse(&st->defs[i], text, &v, err)) return -1;
  drop(&st->defs[i], &v);
  if (from < st->e[i].from) return 0;
  change(st, i, from, text);
  out->def = i;
  out->from = from;
  out->text = xstrdup(text);
  return 0;
}

void settings_apply(struct settings *st, const struct setting_change *ch) {
  if (ch->def < 0 || ch->def >= st->n || ch->from < st->e[ch->def].from) return;
  change(st, ch->def, ch->from, ch->text);
}

int settings_get(const struct settings *st, const char *name, union setting_value *out, char **err) {
  int i = settings_find(st, name);
  if (i < 0) {
    *err = xasprintf("no setting is called %s", name);
    return -1;
  }
  *out = st->e[i].v;
  if (is_text(st->defs[i].type)) out->s = xstrdup(out->s);
  return 0;
}

/* ---- the saved state ---- */

static void put_escaped(FILE *f, const char *s) {
  for (; *s; s++) {
    if (*s == '\\') fputs("\\\\", f);
    else if (*s == '\n') fputs("\\n", f);
    else fputc(*s, f);
  }
}

static void unescape(char *s) {
  char *w = s;
  for (; *s; s++) {
    if (*s == '\\' && s[1]) {
      s++;
      *w++ = *s == 'n' ? '\n' : *s;
    } else {
      *w++ = *s;
    }
  }
  *w = '\0';
}

int settings_load_state(struct settings *st, const char *path, char **err) {
  FILE *f = fopen(path, "r");
  if (!f) {
    if (errno == ENOENT) return 0;
    *err = xasprintf("%s: %s", path, strerror(errno));
    return -1;
  }
  char *line = NULL;
  size_t cap = 0;
  ssize_t len;
  while ((len = getline(&line, &cap, f)) >= 0) {
    if (len > 0 && line[len - 1] == '\n') line[--len] = '\0';
    char *eq = strchr(line, '=');
    if (!line[0] || line[0] == '#' || !eq) continue;
    *eq = '\0';
    unescape(eq + 1);
    struct setting_change ch;
    char *e = NULL;
    if (settings_set(st, line, eq + 1, FROM_STATE, &ch, &e)) {
      log_warn("%s: passed over: %s", path, e);
      free(e);
    }
    free(ch.text);
  }
  free(line);
  fclose(f);
  return 0;
}

int settings_save_state(const struct settings *st, const char *path, char **err) {
  char *dir = xstrdup(path), *slash = strrchr(dir, '/');
  if (slash && slash != dir) {
    *slash = '\0';
    mkdir_p(dir);
  }
  free(dir);
  char *tmp = xasprintf("%s.new", path);
  FILE *f = fopen(tmp, "w");
  if (!f) {
    *err = xasprintf("%s: %s", tmp, strerror(errno));
    free(tmp);
    return -1;
  }
  for (int i = 0; i < st->n; i++) {
    if (!st->e[i].keep) continue;
    fprintf(f, "%s=", st->defs[i].name);
    put_escaped(f, st->e[i].keep);
    fputc('\n', f);
  }
  int bad = ferror(f) | fclose(f);
  if (bad || rename(tmp, path)) {
    *err = xasprintf("%s: %s", path, strerror(errno));
    remove(tmp);
    free(tmp);
    return -1;
  }
  free(tmp);
  return 0;
}
