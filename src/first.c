/* What nothing has said yet, asked on the terminal when lulibre starts
 * with no library set (only when stdin and stderr are terminals): the
 * library, when calibre's settings name the one it opened last; then, that
 * taken, calibre's content server, when one answers where calibre puts it
 * by default, with its user and password file when it asks for them. Each
 * answer, yes or no, is kept in lulibre's state folder (asked, beside the
 * saved settings) as a layer just over the defaults: init.lua, -o and the
 * saved state all lie over it, and it is asked once. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <curl/curl.h>

#include "app.h"
#include "core/util.h"
#include "library/library.h"

#define SERVER "http://127.0.0.1:8080" /* calibre-server's own default */

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
  ssize_t n = getline(&line, &cap, stdin);
  if (n < 0) {
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

/* the answer, as the setting from now on (lulibre's state folder, asked) */
static void remember(struct app *app, const char *name, const char *value) {
  char *err = NULL;
  if (settings_keep_answer(app->settings, app->answers_path, name, value, &err)) {
    warnf("%s", err);
    free(err);
  }
}

int first_library(struct app *app) {
  char *lib = calibre_library_path();
  if (!lib) return 0;
  int ok = 0;
  if (first_interactive()) {
    char *dir = calibre_config_dir();
    char *q = xasprintf("Library not set. Open %s, the library calibre opened last (from %s)? (y|N) ", lib, dir);
    if ((ok = yes(q))) remember(app, "path.library", lib);
    free(q);
    free(dir);
  } else {
    warnf("calibre opened %s last: lulibre -L '%s' opens it", lib, lib);
  }
  free(lib);
  return ok;
}

static size_t discard(char *p, size_t size, size_t n, void *ud) {
  (void)p;
  (void)ud;
  return size * n;
}

/* the HTTP status a server answers at url with, 0 for none */
static long probe(const char *url) {
  CURL *c = curl_easy_init();
  if (!c) return 0;
  curl_easy_setopt(c, CURLOPT_URL, url);
  curl_easy_setopt(c, CURLOPT_CONNECTTIMEOUT_MS, 500L);
  curl_easy_setopt(c, CURLOPT_TIMEOUT_MS, 1500L);
  curl_easy_setopt(c, CURLOPT_WRITEFUNCTION, discard);
  curl_easy_setopt(c, CURLOPT_NOSIGNAL, 1L);
  long status = 0;
  if (curl_easy_perform(c) == CURLE_OK) curl_easy_getinfo(c, CURLINFO_RESPONSE_CODE, &status);
  curl_easy_cleanup(c);
  return status;
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
  long status = probe(SERVER "/ajax/library-info");
  if (status != 200 && status != 401) return; /* none answers: changes go to the library folder */
  char *q = xasprintf("calibre's content server answers at %s%s. Send changes through it? (y|N) ", SERVER,
                      status == 401 ? " and asks for a password" : "");
  int use = yes(q);
  free(q);
  remember(app, "server", use ? SERVER : "");
  if (!use || status != 401) return;
  if (settings_origin(app->settings, S_USER) == FROM_DEFAULT) {
    const char *me = getenv("USER");
    char *q2 = xasprintf("user [%s]: ", me ? me : "");
    char *a = ask(q2);
    remember(app, "user", a && *a ? a : me ? me : "");
    free(a);
    free(q2);
  }
  if (settings_origin(app->settings, S_PASSWORD_FILE) == FROM_DEFAULT) {
    char *found = password_file(app);
    char *q3 = xasprintf("file holding its password%s%s%s: ", found ? " [" : "", found ? found : "", found ? "]" : "");
    char *a = ask(q3);
    const char *path = a && *a ? a : found;
    if (path) remember(app, "path.password", path);
    free(a);
    free(q3);
    free(found);
  }
}
