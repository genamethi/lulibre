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

/* A change, as a message between threads. The interface thread applies
 * every change in the order it receives them and sends each on to every
 * thread, the one that made it too, so all copies end on the same value. */
struct setting_change {
  int def;                  /* index into the definitions */
  enum setting_origin from;
  char *text;               /* the value as typed; freed by the receiver */
};

struct settings;

/* Dies when a default is not a value of its own definition. */
struct settings *settings_new(const struct setting_def *defs, int ndefs);
void settings_free(struct settings *st);

/* The definition's index, or -1. */
int settings_find(const struct settings *st, const char *name);
const struct setting_def *settings_def(const struct settings *st, int def);
enum setting_origin settings_origin(const struct settings *st, int def);

/* All return 0 on success; on failure *err is a malloc'd message. */

/* Validates text, changes this thread's copy, and fills *out with the
 * message for the interface thread. A value of lower precedence than the
 * one held changes nothing and returns 0 with out->def = -1. A value set
 * through the Lua API for a SETTING_AT_START setting is kept for saving
 * and leaves the value in effect as it is. */
int settings_set(struct settings *st, const char *name, const char *text, enum setting_origin from,
                 struct setting_change *out, char **err);
/* Applies a change another thread made; ch->text stays the caller's. */
void settings_apply(struct settings *st, const struct setting_change *ch);

/* A copy of the current value: an operation takes its values when created
 * and never reads the store again. The caller frees out->s. */
int settings_get(const struct settings *st, const char *name, union setting_value *out, char **err);

/* The saved state (~/.local/state/lulibre): read once at start; written on
 * command, on call and at shutdown. Saved are the values set through the
 * Lua API and those read from the state; a command line value holds for
 * its run. One `name=value` per line; a setting the state names that no
 * longer exists, or a value no longer valid, is passed over with a
 * warning. */
int settings_load_state(struct settings *st, const char *path, char **err);
int settings_save_state(const struct settings *st, const char *path, char **err);

#endif
