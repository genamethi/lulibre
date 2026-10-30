/* Completion at the command line: what could come next where the cursor is.
 *
 *   :            command names
 *   :NAME        what completes NAME's arguments, as its command says
 *                (command_completion): a fixed list, the filter language,
 *                settings (names, then the values one allows), command
 *                names, scripts, or a Lua function's answer
 *   &  /         the filter language: fields, then is: has: no: sort: in:
 *
 * The candidates go to the popup the edit form already uses for its
 * suggestions; Tab takes the highlighted one, <C-n> and <C-p> move through
 * them. Matching is by prefix, so the popup stays away while free text is
 * typed.
 *
 * A Lua function is not called here (design 34): it is asked by message,
 * once for each word the arguments reach, and its answer fills the popup
 * when it comes (complete_answered). */
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

static void add_words(struct list *l, const char *words) { /* "a\nb\nc" */
  for (const char *p = words; *p;) {
    size_t len = strcspn(p, "\n");
    if (len) add_owned(l, xstrndup(p, len), NULL);
    p += len;
    while (*p == '\n') p++;
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
  const char *name = NULL;
  const struct completion *comp = NULL;
  if (t->prompt != PROMPT_COMMAND) {
    snprintf(ctx, sizeof ctx, "filter");
  } else if (!strchr(text, ' ')) {
    snprintf(ctx, sizeof ctx, "command");
  } else {
    size_t len = strcspn(text, " ");
    name = command_completion(text, len, &comp);
    if (!name) snprintf(ctx, sizeof ctx, "none");
    else if (comp->kind == COMPLETE_SETTING)
      snprintf(ctx, sizeof ctx, "set %s %.*s", name, (int)(strchr(last, '=') ? strcspn(last, "=") + 1 : 0), last);
    else if (comp->kind == COMPLETE_LUA) { /* asked again for each word */
      int words = 0;
      for (const char *p = text + len; *p; p++) words += *p == ' ' && p[1] != ' ';
      snprintf(ctx, sizeof ctx, "lua %.60s %d", name, words);
    } else snprintf(ctx, sizeof ctx, "arg %.60s", name);
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
  } else if (comp) {
    switch (comp->kind) {
    case COMPLETE_WORDS: add_words(&l, comp->words); break;
    case COMPLETE_FILTER: query_words(filter_word, &l); break;
    case COMPLETE_SETTING: add_options(&l, last); break;
    case COMPLETE_SCRIPT: add_scripts(&l, t->app); break;
    case COMPLETE_COMMAND: {
      const char *help;
      for (int i = 0; command_at(i, &help); i++) add(&l, command_at(i, NULL), help);
      break;
    }
    case COMPLETE_LUA:
      if (t->comp_got_ctx && !strcmp(t->comp_got_ctx, ctx))
        for (int i = 0; i < t->ncomp_got; i++) add(&l, t->comp_got[i], t->comp_got_detail[i]);
      else lapi_complete(t->app, comp->ref, name, last, text, ctx);
      break;
    case COMPLETE_NONE: break;
    }
  }
  /* a command's arguments are listed as soon as there is room for one */
  t->sugg_prefix = name ? 2 : 1;
  tui_input_suggest(t, l.n, l.text, l.detail, sep);
  for (int i = 0; i < l.nowned; i++) free(l.owned[i]);
  free(l.owned);
  free(l.text);
  free(l.detail);
}

void complete_answered(struct tui *t, char *ctx, int n, char **text, char **detail) {
  free(t->comp_got_ctx);
  for (int i = 0; i < t->ncomp_got; i++) {
    free(t->comp_got[i]);
    free(t->comp_got_detail[i]);
  }
  free(t->comp_got);
  free(t->comp_got_detail);
  t->comp_got_ctx = ctx;
  t->comp_got = text;
  t->comp_got_detail = detail;
  t->ncomp_got = n;
  /* still where it was asked: shown now */
  if (t->mode == MODE_PROMPT && t->comp_ctx && !strcmp(t->comp_ctx, ctx)) {
    free(t->comp_ctx);
    t->comp_ctx = NULL;
    complete_refresh(t);
    tui_dirty(t);
  }
}
