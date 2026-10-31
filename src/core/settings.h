#ifndef LULIBRE_SETTINGS_H
#define LULIBRE_SETTINGS_H

/* The settings (design 2, 4, 44, 45).
 *
 * One store, owned by the main thread. The definitions are fixed at build
 * time. Each setting holds a value per layer: the default, the saved state,
 * the Lua API, the command line. The value in effect is the top layer that
 * has one: command line over API over state over default. The state layer
 * counts only while the persistence setting is true. What init.lua sets at
 * start lies under the command line; a change made later (settings_change)
 * replaces the command line's value.
 *
 * Every setting the API may set is live: a change in effect is reported to
 * the store's watcher, which passes it on (to the lua_State's copy, to the
 * part of C that acts on it). A C operation takes its values when created
 * (settings_get copies) and never reads the store again. */

enum setting_type { SETTING_STR, SETTING_INT, SETTING_BOOL, SETTING_NUM, SETTING_PATH };

/* FROM_ASKED: an answer given at the terminal when nothing was set (first.c),
 * kept in lulibre's state folder; it lies over the default alone */
enum setting_origin { FROM_DEFAULT, FROM_ASKED, FROM_STATE, FROM_API, FROM_CLI, ORIGINS };

enum setting_flags {
  SETTING_CLI_ONLY = 1 << 0, /* locates init.lua or the state: command line only, never saved */
  SETTING_PERSIST = 1 << 1,  /* the persistence setting (a bool): never saved */
};

struct setting_def {
  const char *name;
  enum setting_type type;
  unsigned flags;
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

struct settings;

/* Called for each setting whose value in effect changed. */
typedef void settings_watch_fn(struct settings *st, int def, void *ud);

/* Dies when a default is not a value of its own definition. */
struct settings *settings_new(const struct setting_def *defs, int ndefs);
void settings_free(struct settings *st);
void settings_watch(struct settings *st, settings_watch_fn *fn, void *ud);

/* The definition's index, or -1. */
int settings_find(const struct settings *st, const char *name);
int settings_count(const struct settings *st);
const struct setting_def *settings_def(const struct settings *st, int def);
/* The layer the value in effect comes from. */
enum setting_origin settings_origin(const struct settings *st, int def);
/* The value in effect, valid until the next change. */
const union setting_value *settings_value(const struct settings *st, int def);

/* All return 0 on success; on failure *err is a malloc'd message. */

/* Validates text and puts it in layer `from` (not FROM_DEFAULT). */
int settings_set(struct settings *st, const char *name, const char *text, enum setting_origin from, char **err);
/* Empties layer `from`: the layer below shows through. */
int settings_unset(struct settings *st, const char *name, enum setting_origin from, char **err);
/* A change made while lulibre runs: text in the API's layer, the command
 * line's emptied, so it takes effect; NULL empties both, and the state or
 * the default shows through. */
int settings_change(struct settings *st, const char *name, const char *text, char **err);

/* Checks text against a definition, from any thread; fills *out (the
 * caller frees out->s for a text). */
int settings_parse(const struct setting_def *d, const char *text, union setting_value *out, char **err);

/* A value as text, the way it would be typed; malloc'd. */
char *settings_format(const struct setting_def *d, const union setting_value *v);

/* A copy of the value in effect. The caller frees out->s. */
int settings_get(const struct settings *st, const char *name, union setting_value *out, char **err);

/* The saved state (~/.local/state/lulibre/settings): read at start into
 * the state layer, whether or not it counts. Written, while persistence is
 * on, with the API layer laid over the state layer. One `name=value` per
 * line; a setting the state names that no longer exists, or a value no
 * longer valid, is passed over with a warning. */
int settings_load_state(struct settings *st, const char *path, char **err);
int settings_save_state(const struct settings *st, const char *path, char **err);
/* The answers (asked, beside the saved state): read at start into the
 * asked layer, which always counts; settings_keep_answer puts one in that
 * layer and adds it to the file. */
int settings_load_answers(struct settings *st, const char *path, char **err);
int settings_keep_answer(struct settings *st, const char *path, const char *name, const char *value, char **err);

#endif
