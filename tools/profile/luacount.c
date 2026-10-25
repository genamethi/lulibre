/* Counts the calls Lua code makes while lulibre runs: for each calling Lua
 * function and each function it calls (a C function, or another Lua
 * function), how many calls, and how many bytes of strings and how many
 * tables went in as arguments. Loaded with LD_PRELOAD into any lulibre
 * build; nothing in lulibre changes.
 *
 *   LUACOUNT_OUT=FILE LD_PRELOAD=build/profile-cache/luacount.so lulibre ...
 *
 * The scheduler gives every task a count hook (sched.c); this library's
 * lua_sethook adds call events to that hook and passes the count events on,
 * so time slices and cancelling work as before. Code that runs outside a
 * task (init.lua, luv's callbacks on the main state) has no hook and is not
 * counted. The hook runs on the Lua thread only, so the table has no lock.
 *
 * FILE gets one line per edge, tab-separated:
 *   caller_source caller_line callee_kind callee calls string_bytes tables
 * callee_kind is "C" (callee: object file and offset, named afterwards with
 * nm) or "Lua" (callee: source:line). */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <lua.h>

struct edge {
  char *key;
  unsigned long long calls, bytes, tables;
};

static struct edge *edges;
static size_t cap, used;
static lua_Hook passed_on;
static int passed_mask;

static uint64_t hash(const char *s) {
  uint64_t h = 1469598103934665603ULL;
  for (; *s; s++) h = (h ^ (unsigned char)*s) * 1099511628211ULL;
  return h;
}

static struct edge *slot(const char *key) {
  if (used * 2 >= cap) {
    size_t ncap = cap ? cap * 2 : 1 << 16;
    struct edge *n = calloc(ncap, sizeof *n);
    for (size_t i = 0; i < cap; i++)
      if (edges[i].key) {
        size_t j = hash(edges[i].key) & (ncap - 1);
        while (n[j].key) j = (j + 1) & (ncap - 1);
        n[j] = edges[i];
      }
    free(edges);
    edges = n, cap = ncap;
  }
  size_t i = hash(key) & (cap - 1);
  while (edges[i].key && strcmp(edges[i].key, key)) i = (i + 1) & (cap - 1);
  if (!edges[i].key) edges[i].key = strdup(key), used++;
  return &edges[i];
}

static void on_call(lua_State *L, lua_Debug *ar) {
  char callee[4096], caller[4096], key[8300];
  if (!lua_getinfo(L, "Sf", ar)) return;
  int is_c = ar->what[0] == 'C';
  if (is_c) {
    lua_CFunction f = lua_tocfunction(L, -1);
    Dl_info d;
    if (f && dladdr((void *)f, &d) && d.dli_fname)
      snprintf(callee, sizeof callee, "C\t%s+0x%lx", d.dli_fname, (unsigned long)((char *)f - (char *)d.dli_fbase));
    else
      snprintf(callee, sizeof callee, "C\t?%p", (void *)f);
  } else {
    snprintf(callee, sizeof callee, "Lua\t%s:%d", ar->source, ar->linedefined);
  }
  lua_pop(L, 1);
  lua_Debug up;
  if (lua_getstack(L, 1, &up) && lua_getinfo(L, "S", &up))
    snprintf(caller, sizeof caller, "%s\t%d", up.what[0] == 'C' ? "=[C]" : up.source, up.linedefined);
  else
    snprintf(caller, sizeof caller, "=[top]\t0");
  snprintf(key, sizeof key, "%s\t%s", caller, callee);
  struct edge *e = slot(key);
  e->calls++;
  if (is_c) /* the arguments, as the C function will find them */
    for (int i = 1;; i++) {
      const char *name = lua_getlocal(L, ar, i);
      if (!name) break;
      if (lua_type(L, -1) == LUA_TSTRING) e->bytes += lua_rawlen(L, -1);
      else if (lua_type(L, -1) == LUA_TTABLE) e->tables++;
      lua_pop(L, 1);
    }
}

static void hook(lua_State *L, lua_Debug *ar) {
  if (ar->event == LUA_HOOKCALL || ar->event == LUA_HOOKTAILCALL) on_call(L, ar);
  else if (passed_on && ar->event == LUA_HOOKCOUNT && (passed_mask & LUA_MASKCOUNT)) passed_on(L, ar);
}

void lua_sethook(lua_State *L, lua_Hook f, int mask, int count) {
  static void (*real)(lua_State *, lua_Hook, int, int);
  if (!real) real = (void (*)(lua_State *, lua_Hook, int, int))dlsym(RTLD_NEXT, "lua_sethook");
  if (!f || !mask) { /* the hook taken off: the calls are still counted */
    real(L, hook, LUA_MASKCALL, 0);
    return;
  }
  passed_on = f, passed_mask = mask;
  real(L, hook, mask | LUA_MASKCALL, count);
}

/* the programs lulibre runs are not counted, and would write over FILE */
__attribute__((constructor)) static void start(void) { unsetenv("LD_PRELOAD"); }

__attribute__((destructor)) static void dump(void) {
  const char *path = getenv("LUACOUNT_OUT");
  FILE *f = path && used ? fopen(path, "w") : NULL;
  if (!f) return;
  for (size_t i = 0; i < cap; i++)
    if (edges[i].key)
      fprintf(f, "%s\t%llu\t%llu\t%llu\n", edges[i].key, edges[i].calls, edges[i].bytes, edges[i].tables);
  fclose(f);
}
