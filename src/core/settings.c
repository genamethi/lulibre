#include "core/settings.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "core/log.h"
#include "core/util.h"

struct entry {
  char *layer[ORIGINS]; /* the text per layer, as typed; NULL = none */
  enum setting_origin from;
  union setting_value v;
};

struct held { /* a value for a name no setting has yet */
  char *name, *text;
  enum setting_origin from;
};

struct settings {
  struct setting_def *defs; /* lulibre's, then those made at run time */
  int n, cap;
  struct held *held;
  int nheld;
  struct entry *e;
  int persist; /* the persistence setting's index, or -1 */
  settings_watch_fn *watch;
  void *ud;
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

int settings_parse(const struct setting_def *d, const char *text, union setting_value *out, char **err) {
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

static int persistent(const struct settings *st) {
  return st->persist >= 0 && st->e[st->persist].v.b;
}

/* The layer that is in effect for setting i. */
static enum setting_origin top(const struct settings *st, int i) {
  const struct entry *e = &st->e[i];
  for (int o = ORIGINS - 1; o > FROM_DEFAULT; o--) {
    if (o == FROM_STATE && !persistent(st)) continue;
    if (e->layer[o]) return o;
  }
  return FROM_DEFAULT;
}

static int same(enum setting_type t, const union setting_value *a, const union setting_value *b) {
  switch (t) {
  case SETTING_STR:
  case SETTING_PATH:
    return !strcmp(a->s, b->s);
  case SETTING_INT:
    return a->i == b->i;
  case SETTING_BOOL:
    return a->b == b->b;
  case SETTING_NUM:
    return a->n == b->n;
  }
  return 0;
}

/* Brings setting i's value in effect up to date with its layers; 1 when it
 * changed. */
static int settle(struct settings *st, int i) {
  const struct setting_def *d = &st->defs[i];
  struct entry *e = &st->e[i];
  enum setting_origin o = top(st, i);
  union setting_value v;
  char *err = NULL;
  if (settings_parse(d, e->layer[o], &v, &err)) die("%s", err); /* each layer was checked when set */
  int changed = !same(d->type, &v, &e->v);
  if (is_text(d->type)) free(e->v.s);
  e->v = v;
  e->from = o;
  return changed;
}

static void settle_all(struct settings *st) {
  int was = persistent(st);
  for (int i = 0; i < st->n; i++)
    if (settle(st, i) && st->watch) st->watch(st, i, st->ud);
  /* the persistence setting decides which layers count for the others */
  if (persistent(st) != was) settle_all(st);
}

struct settings *settings_new(const struct setting_def *defs, int ndefs) {
  struct settings *st = xcalloc(1, sizeof *st);
  st->defs = xcalloc((size_t)ndefs, sizeof *st->defs);
  memcpy(st->defs, defs, (size_t)ndefs * sizeof *defs);
  st->n = st->cap = ndefs;
  st->e = xcalloc(ndefs, sizeof *st->e);
  st->persist = -1;
  for (int i = 0; i < ndefs; i++) {
    char *err = NULL;
    if (settings_parse(&defs[i], defs[i].dflt, &st->e[i].v, &err)) die("the default of %s", err);
    st->e[i].layer[FROM_DEFAULT] = xstrdup(defs[i].dflt);
    if (defs[i].flags & SETTING_PERSIST) st->persist = i;
  }
  return st;
}

static void def_free(struct setting_def *d) {
  if (!(d->flags & SETTING_MADE)) return;
  free((char *)d->name);
  free((char *)d->dflt);
  free((char *)d->choices);
  free((char *)d->help);
}

void settings_free(struct settings *st) {
  if (!st) return;
  for (int i = 0; i < st->n; i++) {
    if (is_text(st->defs[i].type)) free(st->e[i].v.s);
    for (int o = 0; o < ORIGINS; o++) free(st->e[i].layer[o]);
    def_free(&st->defs[i]);
  }
  for (int i = 0; i < st->nheld; i++) {
    free(st->held[i].name);
    free(st->held[i].text);
  }
  free(st->held);
  free(st->defs);
  free(st->e);
  free(st);
}

void settings_watch(struct settings *st, settings_watch_fn *fn, void *ud) {
  st->watch = fn;
  st->ud = ud;
}

int settings_find(const struct settings *st, const char *name) {
  for (int i = 0; i < st->n; i++)
    if (!strcmp(st->defs[i].name, name)) return i;
  return -1;
}

int settings_count(const struct settings *st) {
  return st->n;
}

const struct setting_def *settings_def(const struct settings *st, int def) {
  return &st->defs[def];
}

enum setting_origin settings_origin(const struct settings *st, int def) {
  return st->e[def].from;
}

const union setting_value *settings_value(const struct settings *st, int def) {
  return &st->e[def].v;
}

/* The setting called name, if layer `from` may hold a value of it. */
static int layer_for(const struct settings *st, const char *name, enum setting_origin from, char **err) {
  int i = settings_find(st, name);
  if (i < 0) {
    *err = xasprintf("no setting is called %s", name);
    return -1;
  }
  unsigned flags = st->defs[i].flags;
  if (from != FROM_CLI && flags & SETTING_CLI_ONLY) {
    *err = xasprintf("%s is set only on the command line", name);
    return -1;
  }
  if (from == FROM_STATE && flags & SETTING_PERSIST) {
    *err = xasprintf("%s is not kept in the saved state", name);
    return -1;
  }
  if (from == FROM_DEFAULT) {
    *err = xasprintf("%s: a default is fixed", name);
    return -1;
  }
  return i;
}

int settings_set(struct settings *st, const char *name, const char *text, enum setting_origin from, char **err) {
  if ((from == FROM_CLI || from == FROM_STATE) && settings_find(st, name) < 0) {
    for (int k = 0; k < st->nheld; k++) /* a later value of the same name and layer replaces it */
      if (st->held[k].from == from && !strcmp(st->held[k].name, name)) {
        free(st->held[k].text);
        st->held[k].text = xstrdup(text);
        return 0;
      }
    st->held = xrealloc(st->held, (size_t)(st->nheld + 1) * sizeof *st->held);
    st->held[st->nheld++] = (struct held){xstrdup(name), xstrdup(text), from};
    return 0;
  }
  int i = layer_for(st, name, from, err);
  if (i < 0) return -1;
  union setting_value v;
  if (settings_parse(&st->defs[i], text, &v, err)) return -1;
  if (is_text(st->defs[i].type)) free(v.s);
  free(st->e[i].layer[from]);
  st->e[i].layer[from] = xstrdup(text);
  settle_all(st);
  return 0;
}

int settings_unset(struct settings *st, const char *name, enum setting_origin from, char **err) {
  int i = layer_for(st, name, from, err);
  if (i < 0) return -1;
  free(st->e[i].layer[from]);
  st->e[i].layer[from] = NULL;
  settle_all(st);
  return 0;
}

int settings_change(struct settings *st, const char *name, const char *text, char **err) {
  int i = layer_for(st, name, FROM_API, err);
  if (i < 0) return -1;
  if (text) {
    union setting_value v;
    if (settings_parse(&st->defs[i], text, &v, err)) return -1;
    if (is_text(st->defs[i].type)) free(v.s);
  }
  for (enum setting_origin o = FROM_API; o <= FROM_CLI; o++) {
    free(st->e[i].layer[o]);
    st->e[i].layer[o] = NULL;
  }
  if (text) st->e[i].layer[FROM_API] = xstrdup(text);
  settle_all(st);
  return 0;
}

int settings_define(struct settings *st, const struct setting_def *d, char **err) {
  union setting_value v;
  struct setting_def made = {xstrdup(d->name), d->type, SETTING_MADE, xstrdup(d->dflt ? d->dflt : ""),
                             d->choices ? xstrdup(d->choices) : NULL, xstrdup(d->help ? d->help : "")};
  if (settings_parse(&made, made.dflt, &v, err)) {
    def_free(&made);
    return -1;
  }
  int i = settings_find(st, d->name);
  if (i >= 0 && !(st->defs[i].flags & SETTING_MADE)) {
    def_free(&made);
    if (is_text(d->type)) free(v.s);
    *err = xasprintf("%s is one of lulibre's own settings", d->name);
    return -1;
  }
  if (i < 0) {
    if (st->n == st->cap) {
      st->cap *= 2;
      st->defs = xrealloc(st->defs, (size_t)st->cap * sizeof *st->defs);
      st->e = xrealloc(st->e, (size_t)st->cap * sizeof *st->e);
    }
    i = st->n++;
    memset(&st->e[i], 0, sizeof st->e[i]);
    st->e[i].v = v;
  } else { /* made again: the layers that are still values of it stay */
    if (is_text(st->defs[i].type)) free(st->e[i].v.s);
    st->e[i].v = v;
    def_free(&st->defs[i]);
  }
  st->defs[i] = made;
  free(st->e[i].layer[FROM_DEFAULT]);
  st->e[i].layer[FROM_DEFAULT] = xstrdup(made.dflt);
  for (int o = FROM_DEFAULT + 1; o < ORIGINS; o++) {
    union setting_value w;
    char *bad = NULL;
    if (!st->e[i].layer[o] || !settings_parse(&made, st->e[i].layer[o], &w, &bad)) {
      if (st->e[i].layer[o] && is_text(made.type)) free(w.s);
      continue;
    }
    log_warn("%s: passed over: %s", d->name, bad);
    free(bad);
    free(st->e[i].layer[o]);
    st->e[i].layer[o] = NULL;
  }
  for (int k = 0; k < st->nheld;) { /* given before it was made */
    struct held h = st->held[k];
    if (strcmp(h.name, d->name)) {
      k++;
      continue;
    }
    st->held[k] = st->held[--st->nheld];
    char *bad = NULL;
    if (settings_set(st, h.name, h.text, h.from, &bad)) {
      log_warn("%s=%s: passed over: %s", h.name, h.text, bad);
      free(bad);
    }
    free(h.name);
    free(h.text);
  }
  settle_all(st);
  return i;
}

int settings_held(const struct settings *st, int k, const char **name, const char **text, enum setting_origin *from) {
  if (k < 0 || k >= st->nheld) return 0;
  *name = st->held[k].name;
  *text = st->held[k].text;
  *from = st->held[k].from;
  return 1;
}

char *settings_unmade(struct settings *st) {
  if (!st->nheld) return NULL;
  sbuf out = SBUF_INIT;
  for (int k = 0; k < st->nheld; k++) {
    sb_printf(&out, "%s%s=%s (%s): no setting is called %s", k ? "\n" : "", st->held[k].name, st->held[k].text,
              st->held[k].from == FROM_CLI ? "the command line" : "the saved state", st->held[k].name);
    free(st->held[k].name);
    free(st->held[k].text);
  }
  st->nheld = 0;
  return sb_take(&out);
}

char *settings_format(const struct setting_def *d, const union setting_value *v) {
  switch (d->type) {
  case SETTING_INT:
    return xasprintf("%lld", v->i);
  case SETTING_NUM:
    return xasprintf("%g", v->n);
  case SETTING_BOOL:
    return xstrdup(v->b ? "true" : "false");
  default:
    return xstrdup(v->s);
  }
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
    *err = xasprintf("%s: %s", path, errstr(errno));
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
    char *e = NULL;
    if (settings_set(st, line, eq + 1, FROM_STATE, &e)) {
      log_warn("%s: passed over: %s", path, e);
      free(e);
    }
  }
  free(line);
  fclose(f);
  return 0;
}

int settings_save_state(const struct settings *st, const char *path, char **err) {
  if (!persistent(st)) return 0;
  char *dir = xstrdup(path), *slash = strrchr(dir, '/');
  if (slash && slash != dir) {
    *slash = '\0';
    mkdir_p(dir);
  }
  free(dir);
  char *tmp = xasprintf("%s.new", path);
  FILE *f = fopen(tmp, "w");
  if (!f) {
    *err = xasprintf("%s: %s", tmp, errstr(errno));
    free(tmp);
    return -1;
  }
  for (int i = 0; i < st->n; i++) {
    if (st->defs[i].flags & (SETTING_CLI_ONLY | SETTING_PERSIST)) continue;
    const char *t = st->e[i].layer[FROM_API] ? st->e[i].layer[FROM_API] : st->e[i].layer[FROM_STATE];
    if (!t) continue;
    fprintf(f, "%s=", st->defs[i].name);
    put_escaped(f, t);
    fputc('\n', f);
  }
  int bad = ferror(f) | fclose(f);
  if (bad || rename(tmp, path)) {
    *err = xasprintf("%s: %s", path, errstr(errno));
    remove(tmp);
    free(tmp);
    return -1;
  }
  free(tmp);
  return 0;
}
