/* What nothing has said, asked on the terminal when lulibre starts with no
 * library set (only when stdin and stderr are terminals): the library,
 * when calibre's settings name the one it opened last; then, that taken,
 * calibre's content server, when one is running, with its user and
 * password file when it asks for them. An answer holds for this run, as a
 * setting changed in the interface does: :config's w writes it to options.lua
 * (lulib._options). Otherwise it is asked again the next time nothing is set. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "app.h"
#include "core/util.h"
#include "library/library.h"

int first_interactive(void) {
  return isatty(STDIN_FILENO) && isatty(STDERR_FILENO);
}

/* the line typed after the question, without its newline; NULL at the end
 * of input */
static char *ask(const char *question) {
  fputs(question, stderr);
  fflush(stderr);
  char *line = NULL;
  size_t cap = 0;
  if (getline(&line, &cap, stdin) < 0) {
    free(line);
    fputc('\n', stderr);
    return NULL;
  }
  line[strcspn(line, "\r\n")] = '\0';
  return line;
}

static int yes(const char *question) {
  char *a = ask(question);
  int y = a && (a[0] == 'y' || a[0] == 'Y');
  free(a);
  return y;
}

/* the answer, for this run */
static void take(struct app *app, const char *name, const char *value) {
  char *err = NULL;
  if (settings_set(app->settings, name, value, FROM_API, &err)) {
    warnf("%s", err);
    free(err);
  }
  app->answered = 1;
}

int first_library(struct app *app) {
  char *lib = calibre_library_path();
  if (!lib) return 0;
  int ok = 0;
  if (first_interactive()) {
    char *dir = calibre_config_dir();
    char *q = xasprintf("Library not set. Open %s, the library calibre opened last (from %s)? (y|N) ", lib, dir);
    if ((ok = yes(q))) take(app, "path.library", lib);
    free(q);
    free(dir);
  } else {
    warnf("calibre opened %s last: lulibre -L '%s' opens it", lib, lib);
  }
  free(lib);
  return ok;
}

/* a file that is there: the first of the candidates, else NULL */
static char *password_file(struct app *app) {
  char *calibre = calibre_config_dir();
  char *cand[] = {xasprintf("%s/password-file", app->config_dir), xasprintf("%s/password-file", calibre)};
  free(calibre);
  char *found = NULL;
  for (size_t i = 0; i < ARRAY_LEN(cand); i++) {
    if (!found && access(cand[i], R_OK) == 0) found = cand[i];
    else free(cand[i]);
  }
  return found;
}

void first_server(struct app *app) {
  if (!first_interactive() || settings_origin(app->settings, S_SERVER) != FROM_DEFAULT) return;
  char *url = NULL, *lib = realpath(app_str(app, S_LIBRARY), NULL);
  int auth = 0, pid = calibre_server_find(lib, &url, &auth);
  free(lib);
  if (!pid) return; /* none runs: changes go to the library folder */
  char *q = xasprintf("calibre's content server is running (process %d, %s%s). Send changes through it? (y|N) ", pid,
                      url, auth ? ", asking for a password" : "");
  int use = yes(q);
  free(q);
  if (use) take(app, "server", url);
  free(url);
  if (!use || !auth) return;
  if (settings_origin(app->settings, S_USER) == FROM_DEFAULT) {
    const char *me = getenv("USER");
    char *q2 = xasprintf("user [%s]: ", me ? me : "");
    char *a = ask(q2);
    take(app, "user", a && *a ? a : me ? me : "");
    free(a);
    free(q2);
  }
  if (settings_origin(app->settings, S_PASSWORD_FILE) == FROM_DEFAULT) {
    char *found = password_file(app);
    char *q3 = xasprintf("file holding its password%s%s%s: ", found ? " [" : "", found ? found : "", found ? "]" : "");
    char *a = ask(q3);
    const char *path = a && *a ? a : found;
    if (path) take(app, "path.password", path);
    free(a);
    free(q3);
    free(found);
  }
}
