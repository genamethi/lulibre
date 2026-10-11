#include "core/log.h"

#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define RING 2000

static struct {
  pthread_mutex_t mu;
  struct log_entry ring[RING];
  uint64_t seq, errors;
  void (*notify)(void *);
  void *notify_ud;
  FILE *file;
  int to_stderr;
} G = {.mu = PTHREAD_MUTEX_INITIALIZER, .to_stderr = 1};

const char *log_level_name(int level) {
  static const char *const names[] = {"error", "warn", "info", "debug"};
  return level >= 0 && level <= LOG_DEBUG ? names[level] : "?";
}

void log_text(int level, const char *text) {
  if (!text) text = "";
  struct timespec ts;
  clock_gettime(CLOCK_REALTIME, &ts);
  size_t len = strlen(text);
  while (len && (text[len - 1] == '\n' || text[len - 1] == ' ')) len--;
  char *copy = xstrndup(text, len);

  pthread_mutex_lock(&G.mu);
  struct log_entry *e = &G.ring[G.seq % RING];
  free((char *)e->text);
  e->seq = ++G.seq;
  e->when = (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
  e->level = level;
  e->text = copy;
  if (level == LOG_ERROR) G.errors++;
  if (G.file) {
    struct tm tm;
    char stamp[32];
    localtime_r(&ts.tv_sec, &tm);
    strftime(stamp, sizeof stamp, "%Y-%m-%d %H:%M:%S", &tm);
    fprintf(G.file, "%s.%03ld %-5s %s\n", stamp, ts.tv_nsec / 1000000, log_level_name(level), copy);
    fflush(G.file);
  }
  int echo = G.to_stderr && level <= LOG_WARN;
  void (*notify)(void *) = G.notify;
  void *ud = G.notify_ud;
  if (echo) fprintf(stderr, "lulibre: %s\n", copy); /* while locked: copy may be recycled after */
  pthread_mutex_unlock(&G.mu);
  if (notify) notify(ud);
}

void log_msg(int level, const char *fmt, ...) {
  va_list ap;
  char *s = NULL;
  va_start(ap, fmt);
  if (vasprintf(&s, fmt, ap) < 0) s = NULL;
  va_end(ap);
  log_text(level, s ? s : fmt);
  free(s);
}

uint64_t log_seq(void) {
  pthread_mutex_lock(&G.mu);
  uint64_t n = G.seq;
  pthread_mutex_unlock(&G.mu);
  return n;
}

uint64_t log_errors(void) {
  pthread_mutex_lock(&G.mu);
  uint64_t n = G.errors;
  pthread_mutex_unlock(&G.mu);
  return n;
}

void log_each(void (*fn)(const struct log_entry *e, void *ud), void *ud) {
  pthread_mutex_lock(&G.mu);
  uint64_t first = G.seq > RING ? G.seq - RING : 0;
  for (uint64_t i = first; i < G.seq; i++) {
    const struct log_entry *e = &G.ring[i % RING];
    if (e->text) fn(e, ud);
  }
  pthread_mutex_unlock(&G.mu);
}

void log_clear(void) {
  pthread_mutex_lock(&G.mu);
  for (int i = 0; i < RING; i++) {
    free((char *)G.ring[i].text);
    G.ring[i].text = NULL;
  }
  pthread_mutex_unlock(&G.mu);
}

void log_on_entry(void (*fn)(void *ud), void *ud) {
  pthread_mutex_lock(&G.mu);
  G.notify = fn;
  G.notify_ud = ud;
  pthread_mutex_unlock(&G.mu);
}

int log_to_file(const char *path) {
  FILE *f = path && *path ? fopen(path, "a") : NULL;
  pthread_mutex_lock(&G.mu);
  if (G.file) fclose(G.file);
  G.file = f;
  pthread_mutex_unlock(&G.mu);
  return path && *path && !f ? -1 : 0;
}

void log_to_stderr(int on) {
  pthread_mutex_lock(&G.mu);
  G.to_stderr = on;
  pthread_mutex_unlock(&G.mu);
}
