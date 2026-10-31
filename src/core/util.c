#include "core/util.h"

#include "core/log.h"

#include <dirent.h>
#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>

void *xmalloc(size_t n) {
  void *p = malloc(n ? n : 1);
  if (!p) die("out of memory");
  return p;
}

void *xcalloc(size_t n, size_t sz) {
  void *p = calloc(n ? n : 1, sz ? sz : 1);
  if (!p) die("out of memory");
  return p;
}

void *xrealloc(void *p, size_t n) {
  p = realloc(p, n ? n : 1);
  if (!p) die("out of memory");
  return p;
}

char *xstrdup(const char *s) {
  return xstrndup(s, strlen(s));
}

char *xstrndup(const char *s, size_t n) {
  char *p = xmalloc(n + 1);
  memcpy(p, s, n);
  p[n] = '\0';
  return p;
}

const char *errstr_in(char *buf, size_t size, int err) {
  /* the GNU strerror_r (_GNU_SOURCE): it returns the message, which is in
   * buf or a string of its own that nothing writes */
  return strerror_r(err, buf, size);
}

char *xasprintf(const char *fmt, ...) {
  va_list ap;
  char *p;
  va_start(ap, fmt);
  if (vasprintf(&p, fmt, ap) < 0) die("out of memory");
  va_end(ap);
  return p;
}

static void sb_grow(sbuf *b, size_t extra) {
  size_t need = b->len + extra + 1;
  if (need <= b->cap) return;
  size_t cap = b->cap ? b->cap * 2 : 64;
  while (cap < need) cap *= 2;
  b->s = xrealloc(b->s, cap);
  b->cap = cap;
}

void sb_putn(sbuf *b, const char *s, size_t n) {
  sb_grow(b, n);
  memcpy(b->s + b->len, s, n);
  b->len += n;
  b->s[b->len] = '\0';
}

void sb_puts(sbuf *b, const char *s) {
  sb_putn(b, s, strlen(s));
}

void sb_putc(sbuf *b, char c) {
  sb_putn(b, &c, 1);
}

void sb_printf(sbuf *b, const char *fmt, ...) {
  va_list ap, ap2;
  va_start(ap, fmt);
  va_copy(ap2, ap);
  int n = vsnprintf(NULL, 0, fmt, ap);
  va_end(ap);
  if (n > 0) {
    sb_grow(b, (size_t)n);
    vsnprintf(b->s + b->len, (size_t)n + 1, fmt, ap2);
    b->len += (size_t)n;
  }
  va_end(ap2);
}

void sb_reset(sbuf *b) {
  b->len = 0;
  if (b->s) b->s[0] = '\0';
}

void sb_free(sbuf *b) {
  free(b->s);
  b->s = NULL;
  b->len = b->cap = 0;
}

char *sb_take(sbuf *b) {
  char *s = b->s ? b->s : xstrdup("");
  b->s = NULL;
  b->len = b->cap = 0;
  return s;
}

void die(const char *fmt, ...) {
  va_list ap;
  fputs("lulibre: ", stderr);
  va_start(ap, fmt);
  vfprintf(stderr, fmt, ap);
  va_end(ap);
  fputc('\n', stderr);
  exit(1);
}

/* A warning: into the log, which also prints it unless the interface has
 * the terminal. */
void warnf(const char *fmt, ...) {
  va_list ap;
  char *s = NULL;
  va_start(ap, fmt);
  if (vasprintf(&s, fmt, ap) < 0) s = NULL;
  va_end(ap);
  log_text(LOG_WARN, s ? s : fmt);
  free(s);
}

double now_s(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

int mkdir_p(const char *path) {
  char *p = xstrdup(path);
  int rc = 0;
  for (char *s = p + 1; ; s++) {
    if (*s == '/' || *s == '\0') {
      char c = *s;
      *s = '\0';
      if (mkdir(p, 0755) != 0 && errno != EEXIST) { rc = -1; break; }
      *s = c;
      if (c == '\0') break;
    }
  }
  free(p);
  return rc;
}

char *path_expand(const char *p) {
  if (p[0] == '~' && (p[1] == '/' || p[1] == '\0')) {
    const char *home = getenv("HOME");
    if (home) return xasprintf("%s%s", home, p + 1);
  }
  return xstrdup(p);
}

char *path_xdg(const char *var, const char *fallback) {
  const char *v = getenv(var);
  return v && v[0] ? xasprintf("%s/lulibre", v) : path_expand(fallback);
}

static int visible(const struct dirent *e) {
  return e->d_name[0] != '.';
}

static int by_name(const struct dirent **a, const struct dirent **b) {
  return strcmp((*a)->d_name, (*b)->d_name);
}

static void walk(const char *dir, const char *rel, int depth, path_walk_fn *fn, void *ud) {
  struct dirent **e;
  int n = scandir(dir, &e, visible, by_name);
  for (int i = 0; i < n; i++) {
    char *path = xasprintf("%s/%s", dir, e[i]->d_name);
    char *name = *rel ? xasprintf("%s/%s", rel, e[i]->d_name) : xstrdup(e[i]->d_name);
    struct stat st;
    if (stat(path, &st) == 0 && fn(path, name, &st, ud) && S_ISDIR(st.st_mode) && depth > 0)
      walk(path, name, depth - 1, fn, ud);
    free(path);
    free(name);
    free(e[i]);
  }
  if (n >= 0) free(e);
}

void path_walk(const char *dir, int depth, path_walk_fn *fn, void *ud) {
  walk(dir, "", depth, fn, ud);
}

char *file_read(const char *path, size_t *len) {
  FILE *f = fopen(path, "r");
  if (!f) return NULL;
  sbuf s = SBUF_INIT;
  char buf[8192];
  size_t n;
  while ((n = fread(buf, 1, sizeof buf, f)) > 0) sb_putn(&s, buf, n);
  fclose(f);
  if (len) *len = s.len;
  return s.s ? sb_take(&s) : xstrdup("");
}

const char *path_ext(const char *p) {
  const char *slash = strrchr(p, '/');
  const char *dot = strrchr(slash ? slash : p, '.');
  return dot ? dot + 1 : "";
}

unsigned long long hash_fnv1a(const char *s) {
  unsigned long long h = 1469598103934665603ULL;
  for (; *s; s++) {
    h ^= (unsigned char)*s;
    h *= 1099511628211ULL;
  }
  return h;
}
