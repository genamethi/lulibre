#ifndef LULIBRE_CONFIG_H
#define LULIBRE_CONFIG_H

#include <stddef.h>

/* Every option is reachable three ways: `-o name=value` on the command line,
 * `lulibre.o.name = value` in init.lua, and (later) `:set` in the TUI. */
struct config {
  char *library;       /* calibre library directory (holds metadata.db) */
  char *index;         /* lulibre's own sqlite file; empty = derived default */
  int pages;           /* first N pages of each file to extract as text */
  int layout_pages;    /* of those, pages kept as tagged lines */
  int jobs;            /* worker threads; 0 = one per core */
  char *ocr;           /* never | auto | always */
  int ocr_pages;       /* pages per file the OCR pass reads */
  char *ocr_lang;      /* tesseract language(s), e.g. eng or eng+fra */
  int write_jobs;      /* calibredb processes at once when writing */
  char *blitter;       /* image preview: auto | pixel | sextant | quadrant | half */
  char *preview;       /* what the preview shows first: text | image */
  int mouse;           /* 1: clicks and the wheel are ours; 0: left to the terminal */
  int review_open;     /* 1: the review screen starts with every book opened up */
  char *leader;        /* the key <Leader> stands for in key bindings */
  char *review_sort;   /* confidence | id: the order of books in review */
  char *title_case;    /* auto | never: give titles proposed in capitals title case */
  char *propose_over;  /* gaps | sure | any: propose for a field that already has a value? */
  char *server;        /* calibre content server URL, used for writes */
  char *user;
  char *password_file;
  /* things lulibre may do on its own: auto | ask | never */
  char *auto_index;     /* index new or changed files when the interface starts */
  char *repair_links;   /* fix symlinks a change left pointing at a renamed folder */
  char *carry_metadata; /* keep what a record being removed knew, as proposals */
  char *sync_propose;   /* propose metadata for files new to the sync folder */
  char *sync_dir;       /* a folder of files waiting to be added to the library */
  char *orphans_dir;    /* where stray files are set aside; empty = XDG data dir */
  char *write_via;      /* auto | server | direct: how changes reach calibre */
  char *log_file;       /* every log entry is also appended here; empty = no file */
  char *config_dir;     /* where init.lua, scripts/ and lua/ are; empty = the XDG default */
};

enum opt_type { OPT_STR, OPT_PATH, OPT_INT };

struct opt_def {
  const char *name;
  enum opt_type type;
  size_t off;
  const char *def;     /* default, as it would be typed */
  const char *choices; /* "a|b|c" when only those values are allowed, else NULL */
  const char *help;
  const char *group;   /* heading in a generated config file; NULL = same as the one before */
};

const struct opt_def *config_opts(size_t *n);
const struct opt_def *config_find(const char *name);

void config_init(struct config *c);
void config_free(struct config *c);
/* 0 on success; on failure *err is a malloc'd message */
int config_set(struct config *c, const char *name, const char *val, char **err);
const char *config_str(const struct config *c, const struct opt_def *o);
int config_int(const struct config *c, const struct opt_def *o);

/* The configuration directory in effect: the option if set, else
 * $XDG_CONFIG_HOME/lulibre, else ~/.config/lulibre. malloc'd. */
char *config_dir_path(const struct config *c);
/* index path: the option if set, else $XDG_DATA_HOME/lulibre/<name>-<hash>.db */
char *config_index_path(const struct config *c);

#endif
