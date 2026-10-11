#ifndef LULIBRE_LOG_H
#define LULIBRE_LOG_H

/* The log: what went wrong, what was reported, and in a debug build what was
 * done. One ring of recent entries for the whole program, written from any
 * thread; the interface shows it in its console window (`), `:messages`
 * pages through it, and it can be copied to a file as it grows.
 *
 * Errors, warnings and notices are recorded in every build. log_debug, the
 * trace of commands, queries, subprocesses and tasks, exists only in a
 * build configured with --debug and costs nothing otherwise. */

#include <stdint.h>

#include <config.h> /* the generated one at the top of the tree, not core/config.h */

#include "core/util.h"

enum { LOG_ERROR, LOG_WARN, LOG_INFO, LOG_DEBUG };

struct log_entry {
  uint64_t seq;  /* 1 for the first entry ever, counting on */
  double when;   /* seconds since the epoch */
  int level;
  const char *text;
};

void log_text(int level, const char *text);
void log_msg(int level, const char *fmt, ...) PRINTF(2, 3);
#define log_error(...) log_msg(LOG_ERROR, __VA_ARGS__)
#define log_warn(...) log_msg(LOG_WARN, __VA_ARGS__)
#define log_info(...) log_msg(LOG_INFO, __VA_ARGS__)
#if LULIBRE_DEBUG
#define log_debug(...) log_msg(LOG_DEBUG, __VA_ARGS__)
#else
#define log_debug(...) ((void)0)
#endif

const char *log_level_name(int level);
uint64_t log_seq(void);    /* entries written so far */
uint64_t log_errors(void); /* of them, errors */

/* Call fn for each entry still held, oldest first. The log is locked
 * meanwhile: fn must be quick and must not log. */
void log_each(void (*fn)(const struct log_entry *e, void *ud), void *ud);
void log_clear(void);

/* fn runs after each new entry, on whichever thread wrote it. */
void log_on_entry(void (*fn)(void *ud), void *ud);
/* Also append every entry to a file; NULL or "" stops. 0 on success. */
int log_to_file(const char *path);
/* Also print warnings and errors to stderr (on by default; the interface
 * turns it off while it owns the terminal). */
void log_to_stderr(int on);

#endif
