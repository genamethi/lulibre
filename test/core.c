/* Tests for the 0.3 runtime: settings, events, the registry. Built and run
 * by `make unit`. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "core/queue.h"
#include "core/settings.h"
#include "core/util.h"

static int checks, fails;

static void ok(int cond, const char *what) {
  checks++;
  if (!cond) {
    fails++;
    printf("FAIL  %s\n", what);
  }
}

static void eq(const char *got, const char *want, const char *what) {
  checks++;
  if (!got || strcmp(got, want)) {
    fails++;
    printf("FAIL  %s\n      got  %s\n      want %s\n", what, got ? got : "(null)", want);
  }
}

static char *tmpdir;

/* ---- settings ---- */

static const struct setting_def defs[] = {
  {"name", SETTING_STR, SETTING_LIVE, "x", NULL, "a text"},
  {"mode", SETTING_STR, SETTING_LIVE, "a", "a|b|c", "one of three"},
  {"count", SETTING_INT, SETTING_LIVE, "3", NULL, "a whole number"},
  {"weight", SETTING_NUM, SETTING_LIVE, "0.45", NULL, "a number"},
  {"flag", SETTING_BOOL, SETTING_LIVE, "false", NULL, "true or false"},
  {"dir", SETTING_PATH, SETTING_AT_START, "~/d", NULL, "read before Lua runs"},
};
#define NDEFS ((int)(sizeof defs / sizeof defs[0]))

static long long get_i(struct settings *st, const char *name) {
  union setting_value v;
  char *err = NULL;
  if (settings_get(st, name, &v, &err)) {
    free(err);
    return -1;
  }
  return v.i;
}

/* settings_get's copy of a text, kept for eq and freed on the next call,
 * or by get_s_done. */
static char *last;

static void get_s_done(void) {
  free(last);
  last = NULL;
}

static const char *get_s(struct settings *st, const char *name) {
  free(last);
  last = NULL;
  union setting_value v;
  char *err = NULL;
  if (settings_get(st, name, &v, &err)) {
    free(err);
    return NULL;
  }
  return last = v.s;
}

static int set(struct settings *st, const char *name, const char *text, enum setting_origin from,
               struct setting_change *ch) {
  char *err = NULL;
  struct setting_change mine;
  int r = settings_set(st, name, text, from, ch ? ch : &mine, &err);
  free(err);
  if (!ch) free(mine.text);
  return r;
}

static void test_settings_values(void) {
  struct settings *st = settings_new(defs, NDEFS);
  union setting_value v;
  char *err = NULL;
  eq(get_s(st, "name"), "x", "a default");
  ok(get_i(st, "count") == 3, "a number's default");
  ok(settings_get(st, "weight", &v, &err) == 0 && v.n == 0.45, "a fraction's default");
  ok(settings_get(st, "flag", &v, &err) == 0 && v.b == 0, "a flag's default");
  ok(get_s(st, "dir")[0] == '/', "a path's default is expanded");

  ok(set(st, "count", "9", FROM_API, NULL) == 0 && get_i(st, "count") == 9, "set a number");
  ok(set(st, "count", "nine", FROM_API, NULL) != 0 && get_i(st, "count") == 9,
     "text is refused for a number, and the value stays");
  ok(set(st, "count", "", FROM_API, NULL) != 0, "so is nothing");
  ok(set(st, "weight", "0.5x", FROM_API, NULL) != 0, "and a number with more after it");
  ok(set(st, "mode", "d", FROM_API, NULL) != 0, "a value outside the choices is refused");
  ok(settings_set(st, "mode", "d", FROM_API, &(struct setting_change){0}, &err) != 0 && err &&
         strstr(err, "a|b|c"),
     "and the message names the choices");
  free(err);
  err = NULL;
  ok(set(st, "flag", "on", FROM_API, NULL) == 0 && settings_get(st, "flag", &v, &err) == 0 && v.b == 1,
     "a flag takes on");
  ok(set(st, "flag", "maybe", FROM_API, NULL) != 0, "but not maybe");
  ok(set(st, "nothing", "1", FROM_API, NULL) != 0, "an unknown setting is refused");
  ok(settings_get(st, "nothing", &v, &err) != 0, "and has no value");
  free(err);

  /* a copy, not a view: a change after the get leaves the copy as it was */
  union setting_value held;
  err = NULL;
  settings_get(st, "name", &held, &err);
  set(st, "name", "y", FROM_API, NULL);
  eq(held.s, "x", "a value taken once does not change under its holder");
  eq(get_s(st, "name"), "y", "a later get returns the current value");
  free(held.s);
  get_s_done();
  settings_free(st);
}

static void test_settings_precedence(void) {
  struct settings *st = settings_new(defs, NDEFS);
  struct setting_change ch;
  set(st, "count", "4", FROM_STATE, NULL);
  set(st, "count", "5", FROM_CLI, NULL);
  ok(get_i(st, "count") == 5, "the command line over the state");
  ok(set(st, "count", "6", FROM_STATE, &ch) == 0 && ch.def < 0 && get_i(st, "count") == 5,
     "the state under the command line changes nothing, and makes no message");
  set(st, "count", "7", FROM_API, NULL);
  ok(get_i(st, "count") == 7, "the Lua API over the command line");
  set(st, "count", "8", FROM_CLI, NULL);
  ok(get_i(st, "count") == 7, "and the command line under the Lua API");
  ok(settings_origin(st, settings_find(st, "count")) == FROM_API, "the origin is the API's");
  set(st, "count", "9", FROM_API, NULL);
  ok(get_i(st, "count") == 9, "the API over its own earlier value");
  settings_free(st);
}

static void test_settings_threads(void) {
  /* two copies, as two threads have: the interface's (ui) and Lua's */
  struct settings *ui = settings_new(defs, NDEFS), *lua = settings_new(defs, NDEFS);
  struct setting_change from_lua, from_ui;
  set(lua, "count", "1", FROM_API, &from_lua);
  ok(get_i(lua, "count") == 1, "a set is seen at once on the thread that made it");
  set(ui, "count", "2", FROM_API, &from_ui);
  /* the interface thread applies in the order it receives, then sends each
   * change to every copy: its own (2), then Lua's (1) */
  settings_apply(ui, &from_lua);
  settings_apply(lua, &from_ui);
  settings_apply(lua, &from_lua);
  ok(get_i(ui, "count") == 1 && get_i(lua, "count") == 1, "both copies end on the same value");
  free(from_lua.text);
  free(from_ui.text);

  struct setting_change bad = {.def = 99, .from = FROM_API, .text = "1"};
  settings_apply(ui, &bad);
  ok(get_i(ui, "count") == 1, "a change for a setting this build lacks is ignored");
  settings_free(ui);
  settings_free(lua);
}

static void test_settings_state(void) {
  char *path = xasprintf("%s/state/settings", tmpdir);
  char *err = NULL;
  struct settings *st = settings_new(defs, NDEFS);
  set(st, "name", "two\nlines \\ here", FROM_API, NULL);
  set(st, "count", "5", FROM_CLI, NULL);
  set(st, "dir", "/new", FROM_API, NULL);
  char *was = path_expand("~/d");
  eq(get_s(st, "dir"), was, "a setting read before Lua runs keeps its value when Lua sets it");
  free(was);
  ok(settings_save_state(st, path, &err) == 0, "the state is saved, its folder made");
  settings_free(st);

  st = settings_new(defs, NDEFS);
  ok(settings_load_state(st, path, &err) == 0, "and read back");
  eq(get_s(st, "name"), "two\nlines \\ here", "a value with a line break and a backslash");
  ok(get_i(st, "count") == 3, "a command line value is not saved");
  eq(get_s(st, "dir"), "/new", "Lua's value for a setting read before Lua runs, at the next start");
  ok(settings_origin(st, settings_find(st, "name")) == FROM_STATE, "the origin is the state");
  set(st, "count", "6", FROM_CLI, NULL);
  ok(settings_save_state(st, path, &err) == 0, "saved again");
  settings_free(st);
  st = settings_new(defs, NDEFS);
  settings_load_state(st, path, &err);
  eq(get_s(st, "name"), "two\nlines \\ here", "a value read from the state is saved again");
  settings_free(st);

  FILE *f = fopen(path, "w");
  fputs("# a comment\ngone=1\ncount=many\nmode=b\n", f);
  fclose(f);
  st = settings_new(defs, NDEFS);
  ok(settings_load_state(st, path, &err) == 0, "a state with an unknown setting and a bad value loads");
  ok(get_i(st, "count") == 3, "the bad value is passed over");
  eq(get_s(st, "mode"), "b", "the good one is read");
  settings_free(st);

  char *none = xasprintf("%s/none", tmpdir);
  st = settings_new(defs, NDEFS);
  ok(settings_load_state(st, none, &err) == 0, "no state yet is no error");
  settings_free(st);
  free(none);
  free(path);
  get_s_done();
}

/* ---- the queue ---- */

static int order[8], norder;

static void note(struct app *app, void *arg) {
  order[norder++] = (int)(long)arg;
}

static void post_inside(struct app *app, void *arg) {
  queue_post(LOOP_UI, note, (void *)2L);
  order[norder++] = 1; /* the message posted above has not run yet */
}

static int counted;

static void count(struct app *app, void *arg) {
  counted++;
}

static void post_counted(void *arg) {
  for (int i = 0; i < 1000; i++) queue_post(LOOP_UI, count, NULL);
}

static void stop_when_counted(uv_idle_t *h) {
  if (counted == 2000) uv_stop(h->loop);
}

static void test_queue(void) {
  uv_loop_t loop;
  uv_loop_init(&loop);
  queue_post(LOOP_UI, note, (void *)7L);
  queue_open(NULL, LOOP_UI, &loop);
  queue_open(NULL, LOOP_LUA, &loop); /* headless: both inboxes on one loop */
  uv_run(&loop, UV_RUN_NOWAIT);
  ok(norder == 1 && order[0] == 7, "a message posted before the inbox opened runs once it does");

  norder = 0;
  queue_post(LOOP_LUA, post_inside, NULL);
  uv_run(&loop, UV_RUN_NOWAIT);
  uv_run(&loop, UV_RUN_NOWAIT);
  ok(norder == 2 && order[0] == 1 && order[1] == 2,
     "a message posted from a message runs after it, never in its stack");

  norder = 0;
  queue_close(LOOP_LUA);
  queue_post(LOOP_LUA, note, (void *)3L);
  uv_run(&loop, UV_RUN_NOWAIT);
  ok(norder == 0, "a closed inbox's messages wait");
  queue_open(NULL, LOOP_LUA, &loop);
  uv_run(&loop, UV_RUN_NOWAIT);
  ok(norder == 1 && order[0] == 3, "and run when it opens again");

  /* two threads post at once; every message runs, once */
  uv_thread_t a, b;
  uv_idle_t idle;
  uv_idle_init(&loop, &idle);
  uv_idle_start(&idle, stop_when_counted);
  uv_thread_create(&a, post_counted, NULL);
  uv_thread_create(&b, post_counted, NULL);
  uv_run(&loop, UV_RUN_DEFAULT);
  uv_thread_join(&a);
  uv_thread_join(&b);
  ok(counted == 2000, "messages from two threads all run");
  uv_close((uv_handle_t *)&idle, NULL);

  norder = 0;
  queue_close(LOOP_UI);
  queue_close(LOOP_LUA);
  uv_run(&loop, UV_RUN_NOWAIT);
  queue_post(LOOP_UI, note, (void *)5L);
  queue_drain(LOOP_UI);
  ok(norder == 1 && order[0] == 5, "drain runs what waits, when the loop is gone");
  ok(uv_loop_close(&loop) == 0, "the inboxes leave no handle open");
}

int main(void) {
  const char *base = getenv("TMPDIR");
  char *t = xasprintf("%s/lulibre-core-XXXXXX", base ? base : "/tmp");
  tmpdir = mkdtemp(t);
  if (!tmpdir) {
    perror("mkdtemp");
    return 1;
  }
  test_settings_values();
  test_settings_precedence();
  test_settings_threads();
  test_settings_state();
  test_queue();
  printf("core tests: %d checks, %d failed\n", checks, fails);
  char *rm = xasprintf("rm -rf '%s'", tmpdir);
  if (system(rm)) printf("could not remove %s\n", tmpdir);
  free(rm);
  free(tmpdir);
  return fails ? 1 : 0;
}
