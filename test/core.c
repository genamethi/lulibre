/* Tests for the 0.3 runtime: settings, events, the registry. Built and run
 * by `make unit`. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <lauxlib.h>
#include <lua.h>

#include "app.h"
#include "core/events.h"
#include "core/queue.h"
#include "core/settings.h"
#include "core/util.h"
#include "db/db.h"
#include "doc/doc.h"
#include "doc/reading.h"
#include "lua/sched.h"

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
  {"name", SETTING_STR, 0, "x", NULL, "a text"},
  {"mode", SETTING_STR, 0, "a", "a|b|c", "one of three"},
  {"count", SETTING_INT, 0, "3", NULL, "a whole number"},
  {"weight", SETTING_NUM, 0, "0.45", NULL, "a number"},
  {"flag", SETTING_BOOL, 0, "false", NULL, "true or false"},
  {"dir", SETTING_PATH, SETTING_CLI_ONLY, "~/d", NULL, "where things are"},
  {"persistent", SETTING_BOOL, SETTING_PERSIST, "false", NULL, "keep the settings"},
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

static int set(struct settings *st, const char *name, const char *text, enum setting_origin from) {
  char *err = NULL;
  int r = settings_set(st, name, text, from, &err);
  free(err);
  return r;
}

static int unset(struct settings *st, const char *name, enum setting_origin from) {
  char *err = NULL;
  int r = settings_unset(st, name, from, &err);
  free(err);
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

  ok(set(st, "count", "9", FROM_API) == 0 && get_i(st, "count") == 9, "set a number");
  ok(set(st, "count", "nine", FROM_API) != 0 && get_i(st, "count") == 9,
     "text is refused for a number, and the value stays");
  ok(set(st, "count", "", FROM_API) != 0, "so is nothing");
  ok(set(st, "weight", "0.5x", FROM_API) != 0, "and a number with more after it");
  ok(set(st, "mode", "d", FROM_API) != 0, "a value outside the choices is refused");
  ok(settings_set(st, "mode", "d", FROM_API, &err) != 0 && err && strstr(err, "a|b|c"),
     "and the message names the choices");
  free(err);
  err = NULL;
  ok(set(st, "flag", "on", FROM_API) == 0 && settings_get(st, "flag", &v, &err) == 0 && v.b == 1,
     "a flag takes on");
  ok(set(st, "flag", "maybe", FROM_API) != 0, "but not maybe");
  ok(set(st, "nothing", "1", FROM_API) != 0, "an unknown setting is refused");
  ok(settings_get(st, "nothing", &v, &err) != 0, "and has no value");
  free(err);
  ok(set(st, "dir", "/x", FROM_API) != 0, "a command line setting is refused from the API");
  ok(set(st, "dir", "/x", FROM_CLI) == 0, "and taken from the command line");

  /* a copy, not a view: a change after the get leaves the copy as it was */
  union setting_value held;
  err = NULL;
  settings_get(st, "name", &held, &err);
  set(st, "name", "y", FROM_API);
  eq(held.s, "x", "a value taken once does not change under its holder");
  eq(get_s(st, "name"), "y", "a later get returns the value in effect");
  free(held.s);
  get_s_done();
  settings_free(st);
}

static int watched[NDEFS];

static void watch(struct settings *st, int def, void *ud) {
  watched[def]++;
}

static void test_settings_layers(void) {
  struct settings *st = settings_new(defs, NDEFS);
  int count = settings_find(st, "count");
  settings_watch(st, watch, NULL);
  set(st, "count", "4", FROM_STATE);
  ok(get_i(st, "count") == 3 && watched[count] == 0, "the state does not count while persistence is off");
  set(st, "persistent", "true", FROM_API);
  ok(get_i(st, "count") == 4 && watched[count] == 1, "it does once persistence is on, and the change is reported");
  set(st, "count", "5", FROM_CLI);
  ok(get_i(st, "count") == 5, "the command line over the state");
  set(st, "count", "7", FROM_API);
  ok(get_i(st, "count") == 7 && settings_origin(st, count) == FROM_API, "the Lua API over the command line");
  set(st, "count", "8", FROM_CLI);
  ok(get_i(st, "count") == 7, "the command line under the Lua API changes nothing in effect");
  unset(st, "count", FROM_API);
  ok(get_i(st, "count") == 8, "unset, the layer below shows through");
  int before = watched[count];
  set(st, "count", "8", FROM_API);
  ok(watched[count] == before, "a value equal to the one in effect is no change");
  unset(st, "count", FROM_API);
  unset(st, "count", FROM_CLI);
  set(st, "persistent", "false", FROM_API);
  ok(get_i(st, "count") == 3, "persistence off again: down to the default");
  ok(set(st, "persistent", "true", FROM_STATE) != 0, "persistence is not taken from the state");
  settings_free(st);
}

static void test_settings_state(void) {
  char *path = xasprintf("%s/state/settings", tmpdir);
  char *err = NULL;
  struct settings *st = settings_new(defs, NDEFS);
  set(st, "name", "two\nlines \\ here", FROM_API);
  set(st, "dir", "/new", FROM_CLI);
  set(st, "count", "5", FROM_CLI);
  ok(settings_save_state(st, path, &err) == 0 && access(path, F_OK) != 0, "persistence off: nothing is written");
  set(st, "persistent", "true", FROM_API);
  ok(settings_save_state(st, path, &err) == 0, "persistence on: the state is saved, its folder made");
  settings_free(st);

  st = settings_new(defs, NDEFS);
  ok(settings_load_state(st, path, &err) == 0, "and read back");
  eq(get_s(st, "name"), "x", "the state waits for persistence");
  set(st, "persistent", "true", FROM_CLI);
  eq(get_s(st, "name"), "two\nlines \\ here", "a value with a line break and a backslash");
  ok(get_i(st, "count") == 3, "a command line value is not saved");
  ok(get_s(st, "dir")[0] == '/' && strcmp(get_s(st, "dir"), "/new"), "nor a command line setting");
  ok(settings_origin(st, settings_find(st, "name")) == FROM_STATE, "the origin is the state");
  set(st, "count", "6", FROM_API);
  ok(settings_save_state(st, path, &err) == 0, "saved again");
  settings_free(st);
  st = settings_new(defs, NDEFS);
  settings_load_state(st, path, &err);
  set(st, "persistent", "true", FROM_CLI);
  eq(get_s(st, "name"), "two\nlines \\ here", "a value read from the state is saved again");
  ok(get_i(st, "count") == 6, "with the API's laid over it");
  settings_free(st);

  FILE *f = fopen(path, "w");
  fputs("# a comment\ngone=1\ncount=many\nmode=b\npersistent=true\n", f);
  fclose(f);
  st = settings_new(defs, NDEFS);
  ok(settings_load_state(st, path, &err) == 0, "a state with an unknown setting and a bad value loads");
  set(st, "persistent", "true", FROM_API);
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

/* An inbox alone does not keep its loop running; in the program other
 * handles do, here this one. */
static uv_async_t keep;

static void keep_open(uv_loop_t *loop) {
  uv_async_init(loop, &keep, NULL);
}

static void keep_close(void) {
  uv_close((uv_handle_t *)&keep, NULL);
}

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
  keep_open(&loop);
  queue_post(LOOP_UI, note, (void *)7L);
  queue_open(NULL, LOOP_UI, &loop);
  queue_open(NULL, LOOP_LUA, &loop); /* headless: both inboxes on one loop */
  uv_run(&loop, UV_RUN_NOWAIT);
  ok(norder == 1 && order[0] == 7, "a message posted before the inbox opened runs once it does");
  uv_unref((uv_handle_t *)&keep);
  ok(uv_run(&loop, UV_RUN_DEFAULT) == 0, "the inboxes alone do not keep the loop running");
  uv_ref((uv_handle_t *)&keep);

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
  keep_close();
  uv_run(&loop, UV_RUN_NOWAIT);
  queue_post(LOOP_UI, note, (void *)5L);
  queue_drain(LOOP_UI);
  ok(norder == 1 && order[0] == 5, "drain runs what waits, when the loop is gone");
  ok(uv_loop_close(&loop) == 0, "the inboxes leave no handle open");
}

/* ---- events ---- */

struct seen {
  int calls;
  long long first_id;
};

static void on_event(const struct event *ev, void *ud) {
  struct seen *s = ud;
  s->calls++;
  s->first_id = ev->nids ? ev->ids[0] : -1;
}

static void remove_self(const struct event *ev, void *ud) {
  struct seen *s = ud;
  s->calls++;
  events_unlisten(LOOP_LUA, ev->kind, remove_self, ud);
}

static struct event *records_changed(long long id) {
  struct event *ev = xcalloc(1, sizeof *ev);
  ev->kind = EV_RECORDS_CHANGED;
  ev->ids = xmalloc(sizeof *ev->ids);
  ev->ids[0] = id;
  ev->nids = 1;
  ev->fields = xmalloc(sizeof *ev->fields);
  ev->fields[0] = xstrdup("title");
  ev->nfields = 1;
  return ev;
}

static void test_events(void) {
  uv_loop_t loop;
  uv_loop_init(&loop);
  keep_open(&loop);
  queue_open(NULL, LOOP_UI, &loop);
  queue_open(NULL, LOOP_LUA, &loop);

  ok(!events_wanted(EV_RECORDS_CHANGED), "no callback: nothing wanted");
  events_post(records_changed(1)); /* freed at once: nobody listens */
  uv_run(&loop, UV_RUN_NOWAIT);

  struct seen ui = {0}, lua = {0}, bare = {0};
  events_listen(LOOP_UI, EV_RECORDS_CHANGED, on_event, &ui);
  ok(events_wanted(EV_RECORDS_CHANGED), "one callback: the kind is wanted");
  events_listen(LOOP_LUA, EV_RECORDS_CHANGED, on_event, &lua);
  events_listen(LOOP_LUA, EV_CURSOR, on_event, &bare);
  ok(!events_wanted(EV_MARKS), "another kind is not");

  events_post(records_changed(42));
  ok(ui.calls == 0 && lua.calls == 0, "posting runs no callback in the poster's stack");
  uv_run(&loop, UV_RUN_NOWAIT);
  ok(ui.calls == 1 && lua.calls == 1 && ui.first_id == 42, "each loop's callback is called once");
  ok(bare.calls == 0, "a callback of another kind is not");

  events_unlisten(LOOP_UI, EV_RECORDS_CHANGED, on_event, &ui);
  events_post(records_changed(43));
  uv_run(&loop, UV_RUN_NOWAIT);
  ok(ui.calls == 1 && lua.calls == 2, "a removed callback is not called; the other loop's is");

  struct seen once = {0};
  events_listen(LOOP_LUA, EV_RECORDS_CHANGED, remove_self, &once);
  events_post(records_changed(44));
  events_post(records_changed(45));
  uv_run(&loop, UV_RUN_NOWAIT);
  ok(once.calls == 1 && lua.calls == 4, "a callback may remove itself while called; the others go on");

  events_unlisten_all(LOOP_LUA, on_event);
  ok(!events_wanted(EV_RECORDS_CHANGED) && !events_wanted(EV_CURSOR), "every callback of one function, dropped at once");
  events_post(records_changed(46));
  uv_run(&loop, UV_RUN_NOWAIT);
  ok(lua.calls == 4, "and none is called after");

  queue_close(LOOP_UI);
  queue_close(LOOP_LUA);
  keep_close();
  uv_run(&loop, UV_RUN_NOWAIT);
  ok(uv_loop_close(&loop) == 0, "the loop closes");
}

/* ---- evman, in a lua_State ---- */

static void close_any(uv_handle_t *h, void *arg) {
  if (!uv_is_closing(h)) uv_close(h, NULL);
}

static void run_until_quiet(struct app *app, uv_loop_t *loop) {
  for (int i = 0; i < 50; i++) uv_run(loop, UV_RUN_NOWAIT);
}

static long long lua_int(lua_State *L, const char *expr) {
  char *code = xasprintf("return %s", expr);
  long long v = -1;
  if (luaL_dostring(L, code) == LUA_OK) v = lua_tointeger(L, -1);
  else printf("      %s\n", lua_tostring(L, -1));
  lua_pop(L, 1);
  free(code);
  return v;
}

static void test_evman(void) {
  uv_loop_t loop;
  uv_loop_init(&loop);
  keep_open(&loop);
  struct app app = {0};
  char *cfg = xasprintf("%s/config", tmpdir);
  app_settings(&app, cfg, NULL, NULL, 0);
  app.loop = app.lloop = &loop;
  queue_open(&app, LOOP_UI, &loop);
  queue_open(&app, LOOP_LUA, &loop);
  lstate_new(&app);
  lua_State *L = app.L;
  const char *setup =
    "seen, order, n = {}, {}, 0\n"
    "counter = 0\n"
    "local function per_event() counter = counter + 1; return counter end\n"
    "id1 = evman.add('records_changed', function(p, a, b, c)\n"
    "  seen.id, seen.field, seen.a, seen.b, seen.c = p.ids[1], p.fields[1], a, b, c\n"
    "  order[#order + 1] = 1\n"
    "end, 'fixed', per_event, function() return 'x', 'y' end)\n"
    "id2 = evman.add('records_changed', function(p) order[#order + 1] = 2; seen.at_start = counter end)\n"
    "id3 = evman.add('cursor', function(p) n = n + 1 end)\n";
  ok(luaL_dostring(L, setup) == LUA_OK, "evman.add registers callbacks");
  ok(events_wanted(EV_RECORDS_CHANGED) && events_wanted(EV_CURSOR), "the kinds Lua listens for are wanted");
  ok(!events_wanted(EV_MARKS), "and no other");

  events_post(records_changed(42));
  run_until_quiet(&app, &loop);
  ok(lua_int(L, "seen.id") == 42 && lua_int(L, "seen.field == 'title' and 1 or 0") == 1,
     "the callback gets the payload");
  ok(lua_int(L, "seen.a == 'fixed' and 1 or 0") == 1, "a value passed at registration");
  ok(lua_int(L, "seen.b") == 1, "a function's first result, taken as the event comes");
  ok(lua_int(L, "seen.c == 'x' and 1 or 0") == 1, "the last function's results, all of them");
  ok(lua_int(L, "#order") == 2 && lua_int(L, "order[1]") == 1 && lua_int(L, "order[2]") == 2,
     "callbacks run in the order they were added");
  ok(lua_int(L, "seen.at_start") == 1, "the functions are called before any callback runs");

  events_post(records_changed(43));
  run_until_quiet(&app, &loop);
  ok(lua_int(L, "seen.b") == 2, "and again for each event");

  ok(luaL_dostring(L, "evman.rm(id1); evman.rm(id2)") == LUA_OK, "evman.rm removes callbacks");
  ok(!events_wanted(EV_RECORDS_CHANGED), "the kind is no longer wanted once its last callback goes");
  ok(luaL_dostring(L, "evman.rm(id1)") != LUA_OK, "removing one twice is an error");
  lua_pop(L, 1);
  ok(luaL_dostring(L, "evman.add('nothing', print)") != LUA_OK, "an unknown event is an error");
  lua_pop(L, 1);

  queue_drain(LOOP_LUA);
  lstate_close(&app);
  ok(!events_wanted(EV_CURSOR), "closing the lua_State drops its callbacks");
  queue_close(LOOP_UI);
  queue_close(LOOP_LUA);
  keep_close();
  uv_walk(&loop, close_any, NULL); /* the scheduler's handle: the program leaves it to exit */
  uv_run(&loop, UV_RUN_NOWAIT);
  ok(uv_loop_close(&loop) == 0, "the loop closes");
  settings_free(app.settings);
  free(app.config_dir);
  free(app.state_path);
  free(cfg);
}

/* ---- a reading ---- */

static void test_reading(void) {
  char *path = xasprintf("%s/index.db", tmpdir), *err = NULL;
  struct db db = {0};
  ok(db_open(&db, path, &err) == 0, "an index opens");
  const char *rows =
    "INSERT INTO files(id, book, format, path, emb_title) VALUES (7, 1, 'PDF', '/x.pdf', 'Embedded');"
    "INSERT INTO lines(file, page, n, text, size, flags) VALUES"
    " (7, 1, 0, 'Title', 18, 32 | 1), (7, 1, 1, 'Author Name', 12, 0),"
    " (7, 1, 2, 'First paragraph', 10, 32), (7, 2, 0, 'Next page', 10, 32);";
  ok(db_exec(&db, rows, &err) == 0, "lines go in");
  struct reading *r = reading_load(&db, 7, &err);
  ok(r != NULL, "a reading loads");
  if (r) {
    eq(r->text, "Title\nAuthor Name\n\nFirst paragraph\fNext page",
       "lines joined: a line break, a blank line before a paragraph, a form feed between pages");
    ok(r->nlines == 4 && r->pages == 2, "four lines on two pages");
    eq(r->meta.title, "Embedded", "the file's own metadata comes with it");
    size_t at = (size_t)(strstr(r->text, "Name") - r->text);
    ok(reading_line_at(r, at) == 1, "a position maps to its line");
    ok(r->lines[1].size == 12 && r->lines[0].flags & 1, "and the line has its size and flags");
    ok(reading_line_at(r, r->lines[1].start + r->lines[1].len) == 1, "a line break counts as the line before's");
    ok(reading_line_at(r, (size_t)(strchr(r->text, '\f') - r->text)) == -1, "a page break is no line's");
    ok(reading_line_at(r, r->len) == -1, "nor is the end");
    ok(reading_line_at(r, 0) == 0, "the first position is the first line's");
    reading_hold(r);
    reading_release(r);
    eq(r->text, "Title\nAuthor Name\n\nFirst paragraph\fNext page", "a second holder keeps it");
    reading_release(r);
  }
  ok(reading_load(&db, 99, &err) == NULL && err, "a file the index lacks is an error");
  free(err);
  db_close(&db);
  free(path);
}

int main(void) {
  const char *base = getenv("TMPDIR");
  char *t = xasprintf("%s/lulibre-core-XXXXXX", base ? base : "/tmp");
  tmpdir = mkdtemp(t);
  /* the tree's Lua runtime, not an installed one (make unit runs from the tree) */
  char *rt = realpath("lua", NULL);
  if (rt) setenv("LULIBRE_RUNTIME", rt, 1);
  free(rt);
  if (!tmpdir) {
    perror("mkdtemp");
    return 1;
  }
  test_settings_values();
  test_settings_layers();
  test_settings_state();
  test_queue();
  test_events();
  test_evman();
  test_reading();
  printf("core tests: %d checks, %d failed\n", checks, fails);
  char *rm = xasprintf("rm -rf '%s'", tmpdir);
  if (system(rm)) printf("could not remove %s\n", tmpdir);
  free(rm);
  free(tmpdir);
  return fails ? 1 : 0;
}
