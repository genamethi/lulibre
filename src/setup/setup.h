#ifndef LULIBRE_SETUP_H
#define LULIBRE_SETUP_H

/* lulibre-setup: the choices of a setup, made in a TUI and kept in a plan
 * (setup.conf, in the folder lulibre-setup runs from), which
 * setup/install.sh carries out in the terminal.
 *
 * Built from the same tree as lulibre, and drawn with lulibre's own
 * drawing (tui/draw.c: the theme, bars, text), so it looks as lulibre does.
 * Nothing here installs anything: install.sh does, in plain view. */
#include <stdint.h>

#include <notcurses/notcurses.h>

#include "core/setdefs.h"

enum kind {
  K_HEAD,   /* a heading: the items under it open and close */
  K_CHOICE, /* one of a few values, `choices` */
  K_TEXT,   /* typed */
  K_DIR,    /* a folder, browsed for or typed */
  K_FILE,   /* a file, browsed for or typed */
  K_CHECK,  /* Enter runs a check; its result is the note */
  K_ACTION, /* Enter does something: install, quit */
};

struct item {
  enum kind kind;
  const char *key;           /* its name in the plan; for lulibre's settings, the setting's */
  const char *label;
  const char *help;
  const char *choices;       /* "a|b|c" */
  const struct setting_def *opt; /* one of lulibre's settings: `opt 'NAME' 'VALUE'` in the plan */
  int depth;
  int head;                  /* the heading it is under, -1 for none */
  int open;                  /* a heading's: are the items under it shown */
  int (*shown)(void);        /* NULL: shown whenever its heading is open */
  char *value;               /* NULL: not set */
  char *note;                /* said after the value: a check's result, the state of a file */
  int note_color;
};

/* ---- keys (line.c) ---- */

#define KEY_CTRL (1u << 30)
#define KEY_ALT (1u << 29)
/* A key as typed: Enter and Backspace in one form whatever the terminal
 * sends, KEY_CTRL with a lower-case letter for Ctrl. 0 for a key released. */
uint32_t key_of(const struct ncinput *ni);

/* ---- typing a line, on the screen's last row (line.c) ---- */

/* Returns what was typed (malloc'd), or NULL when Esc was pressed. With
 * paths, Tab completes a path and ~ stands for the home folder. */
char *line_edit(struct notcurses *nc, const char *prompt, const char *initial, int paths);

/* ---- browsing for a folder or a file (browse.c) ---- */

/* Returns the path chosen (malloc'd), or NULL when the browser was left
 * without choosing. want_dir: a folder is chosen, else a file. start: the
 * folder to begin in, or a file in it; NULL for the home folder. */
char *browse(struct notcurses *nc, const char *title, const char *start, int want_dir);

/* ---- the plan (plan.c) ---- */

/* Reads the plan into the items' values; a missing file is no error.
 * Returns 0, or -1 with a message in *err (malloc'd). */
int plan_load(const char *path, struct item *items, int n, char **err);
/* Writes every value set: a variable for each of setup's own items, `opt`
 * for each of lulibre's options. Written whole to a new file and renamed
 * over the old, so the plan is never half written. */
int plan_save(const char *path, const struct item *items, int n, char **err);

#endif
