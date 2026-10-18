#ifndef LULIBRE_UTIL_H
#define LULIBRE_UTIL_H

#include <stddef.h>

#define PRINTF(a, b) __attribute__((format(printf, a, b)))
#define ARRAY_LEN(a) (sizeof(a) / sizeof((a)[0]))

void *xmalloc(size_t n);
void *xcalloc(size_t n, size_t sz);
void *xrealloc(void *p, size_t n);
char *xstrdup(const char *s);
char *xstrndup(const char *s, size_t n);
char *xasprintf(const char *fmt, ...) PRINTF(1, 2);

/* strerror, safe on any thread: errstr(err) gives each call a buffer of
 * its own, which lives until the end of the statement or block. */
const char *errstr_in(char *buf, size_t size, int err);
#define errstr(err) errstr_in((char[128]){0}, 128, (err))

/* growable string; s is always NUL-terminated once anything is appended */
typedef struct sbuf {
  char *s;
  size_t len, cap;
} sbuf;
#define SBUF_INIT {0}

void sb_putn(sbuf *b, const char *s, size_t n);
void sb_puts(sbuf *b, const char *s);
void sb_putc(sbuf *b, char c);
void sb_printf(sbuf *b, const char *fmt, ...) PRINTF(2, 3);
void sb_reset(sbuf *b);
void sb_free(sbuf *b);
char *sb_take(sbuf *b); /* hands over the buffer; never returns NULL */

void die(const char *fmt, ...) PRINTF(1, 2) __attribute__((noreturn));
void warnf(const char *fmt, ...) PRINTF(1, 2);

double now_s(void);                 /* monotonic seconds */
int mkdir_p(const char *path);      /* 0 on success */
char *path_expand(const char *p);   /* leading ~ -> $HOME; malloc'd */
const char *path_ext(const char *p); /* extension without the dot, or "" */
unsigned long long hash_fnv1a(const char *s);

/* crash.c: on a fatal signal, append a backtrace to the crash log. Install
 * after anything else that handles those signals, so it runs first. */
void crash_install(void);
const char *crash_log_path(void);

#endif
