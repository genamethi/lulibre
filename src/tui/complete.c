/* Completion at the command line: what could come next where the cursor is.
 *
 *   :            command names
 *   :set         option names, then the values an option allows
 *   :run         scripts
 *   :sort :source :browse :pick :mark :sync :preview    their arguments
 *   :filter  &  /   the filter language: fields, then is: has: no: sort: in:
 *
 * The candidates go to the popup the edit form already uses for its
 * suggestions; Tab takes the highlighted one, <C-n> and <C-p> move through
 * them. Matching is by prefix, so the popup stays away while free text is
 * typed. */
#include <dirent.h>
#include <stdlib.h>
#include <string.h>

#include "app.h"
#include "core/util.h"
#include "db/query.h"
#include "lua/lapi.h"
#include "tui/tui.h"

struct list {
  const char **text, **detail;
  char **owned; /* strings made here, freed with the list */
  int n, cap, nowned;
};

static void add(struct list *l, const char *text, const char *detail) {
  if (l->n == l->cap) {
    l->cap = l->cap ? l->cap * 2 : 64;
    l->text = xrealloc(l->text, (size_t)l->cap * sizeof *l->text);
    l->detail = xrealloc(l->detail, (size_t)l->cap * sizeof *l->detail);
    l->owned = xrealloc(l->owned, (size_t)l->cap * 2 * sizeof *l->owned);
  }
  l->text[l->n] = text;
  l->detail[l->n++] = detail;
}

static void add_owned(struct list *l, char *text, const char *detail) {
  add(l, text, detail);
  l->owned[l->nowned++] = text;
}

static void add_words(struct list *l, const char *words) { /* "a b c" */
  for (const char *p = words; *p;) {
    size_t len = strcspn(p, " ");
    add_owned(l, xstrndup(p, len), NULL);
    p += len;
    while (*p == ' ') p++;
  }
}

static void filter_word(const char *word, void *ud) {
  add_owned(ud, xstrdup(word), NULL);
}

static void add_scripts(struct list *l, struct app *app) {
  char **dirs = lapi_script_dirs(app);
  for (char **d = dirs; *d; d++) {
    DIR *dir = opendir(*d);
    for (struct dirent *e; dir && (e = readdir(dir));) {
      size_t n = strlen(e->d_name);
      if (n > 4 && !strcmp(e->d_name + n - 4, ".lua")) add_owned(l, xstrndup(e->d_name, n - 4), NULL);
    }
    if (dir) closedir(dir);
    free(*d);
  }
  free(dirs);
}

static void add_options(struct list *l, const char *word) {
  const struct setting_def *o = setting_defs;
  const char *eq = strchr(word, '=');
  for (size_t i = 0; i < S_COUNT; i++) {
    if (o[i].flags & SETTING_CLI_ONLY) continue;
    if (eq && o[i].choices && strlen(o[i].name) == (size_t)(eq - word) &&
        !strncmp(o[i].name, word, (size_t)(eq - word))) {
      for (const char *p = o[i].choices; *p;) { /* name=choice for each allowed value */
        size_t len = strcspn(p, "|");
        add_owned(l, xasprintf("%s=%.*s", o[i].name, (int)len, p), NULL);
        p += len + (p[len] == '|');
      }
    } else if (!eq) {
      add_owned(l, xasprintf("%s=", o[i].name), o[i].help);
    }
  }
}

void complete_refresh(struct tui *t) {
  if (t->prompt == PROMPT_INPUT || t->prompt == PROMPT_NONE) return;
  const char *text = t->line.text.s ? t->line.text.s : "";
  const char *last = strrchr(text, ' ');
  last = last ? last + 1 : text;

  /* what kind of thing is being typed; the list is rebuilt only when that changes */
  char ctx[96];
  const char *args_of = NULL;
  if (t->prompt != PROMPT_COMMAND) {
    snprintf(ctx, sizeof ctx, "filter");
  } else if (!strchr(text, ' ')) {
    snprintf(ctx, sizeof ctx, "command");
  } else {
    size_t len = strcspn(text, " ");
    args_of = text;
    if (len == 3 && !strncmp(text, "set", 3))
      snprintf(ctx, sizeof ctx, "set %.*s", (int)(strchr(last, '=') ? strcspn(last, "=") + 1 : 0), last);
    else
      snprintf(ctx, sizeof ctx, "arg %.*s", (int)(len < 60 ? len : 60), text);
  }
  if (t->comp_ctx && !strcmp(t->comp_ctx, ctx)) return;
  free(t->comp_ctx);
  t->comp_ctx = xstrdup(ctx);

  struct list l = {0};
  const char *sep = " ";
  if (!strcmp(ctx, "filter")) {
    query_words(filter_word, &l);
  } else if (!strcmp(ctx, "command")) {
    sep = NULL;
    const char *help;
    for (int i = 0; command_at(i, &help); i++) add(&l, command_at(i, NULL), help);
  } else {
    size_t len = strcspn(args_of, " ");
#define IS(word) (len == strlen(word) && !strncmp(args_of, word, len))
    if (IS("set")) add_options(&l, last);
    else if (IS("run")) add_scripts(&l, t->app);
    else if (IS("filter") || IS("search")) query_words(filter_word, &l);
    else if (IS("sort")) add_words(&l, "id title author year series added modified -id -title -author -year -added -modified");
    else if (IS("source")) add_words(&l, "library sync");
    else if (IS("sync")) add_words(&l, "add move drop all");
    else if (IS("browse")) add_words(&l, "author subject series publisher year format");
    else if (IS("pick")) add_words(&l, "books authors subjects filters");
    else if (IS("mark")) add_words(&l, "toggle all none invert");
    else if (IS("yank")) add_words(&l, "bib key path title");
    else if (IS("preview")) add_words(&l, "graphic scroll page zoom pan");
    else if (IS("focus")) add_words(&l, "next prev h j k l panel back");
    else if (IS("console")) add_words(&l, "focus");
    else if (IS("index")) add_words(&l, "force");
#undef IS
  }
  /* a command's arguments are listed as soon as there is room for one */
  t->sugg_prefix = args_of ? 2 : 1;
  tui_input_suggest(t, l.n, l.text, l.detail, sep);
  for (int i = 0; i < l.nowned; i++) free(l.owned[i]);
  free(l.owned);
  free(l.text);
  free(l.detail);
}
