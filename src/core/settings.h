#ifndef LULIBRE_SETTINGS_H
#define LULIBRE_SETTINGS_H

/* The settings (design 2, 4, 44, 45).
 *
 * The definitions are fixed at build time and shared by every thread. Each
 * thread that reads settings keeps its own copy of the values, so a read
 * never waits on another thread. The interface thread holds the copy that
 * counts and is saved; a change made on one thread reaches the others as a
 * message carrying the new value.
 *
 * A value's origin decides precedence: a value the Lua API set over the
 * command line, the command line over the saved state, the saved state over
 * the default. */

enum setting_type { SETTING_STR, SETTING_INT, SETTING_BOOL, SETTING_NUM, SETTING_PATH };

enum setting_origin { FROM_DEFAULT, FROM_STATE, FROM_CLI, FROM_API };

/* SETTING_LIVE: a change takes effect at once. SETTING_AT_START: C reads the
 * value before Lua runs (directories, jobs, mouse, the log file); a change
 * from Lua is saved and takes effect at the next start. */
enum setting_when { SETTING_LIVE, SETTING_AT_START };

struct setting_def {
  const char *name;
  enum setting_type type;
  enum setting_when when;
  const char *dflt;
  const char *choices; /* "a|b|c", or NULL for any value of the type */
  const char *help;
};

union setting_value {
  char *s;
  long long i;
  int b;
  double n;
};

/* A change, as a message between threads. */
struct setting_change {
  int def;                  /* index into the definitions */
  enum setting_origin from;
  char *text;               /* the value as typed; freed by the receiver */
};

struct settings;

struct settings *settings_new(const struct setting_def *defs, int ndefs);
void settings_free(struct settings *st);

/* All return 0 on success; on failure *err is a malloc'd message. */

/* Validates text, changes this thread's copy, and fills *out with the
 * message for the other threads. A value of lower precedence than the one
 * held changes nothing and returns 0 with out->def = -1. */
int settings_set(struct settings *st, const char *name, const char *text, enum setting_origin from,
                 struct setting_change *out, char **err);
/* Applies a change another thread made. */
void settings_apply(struct settings *st, const struct setting_change *ch);

/* A copy of the current value: an operation takes its values when created
 * and never reads the store again. The caller frees out->s. */
int settings_get(const struct settings *st, const char *name, union setting_value *out, char **err);

/* The saved state (~/.local/state/lulibre): read once at start; written on
 * command, on call and at shutdown. Only values set through the Lua API or
 * the command line are saved. */
int settings_load_state(struct settings *st, const char *path, char **err);
int settings_save_state(const struct settings *st, const char *path, char **err);

#endif
