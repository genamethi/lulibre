/* calibre's own settings, as far as lulibre reads them: the library calibre
 * opened last (library_path in global.py.json, in calibre's configuration
 * folder: $CALIBRE_CONFIG_DIRECTORY, else calibre/ under $XDG_CONFIG_HOME
 * or ~/.config, as calibre finds it), parsed with mupdf's JSON reader; and
 * calibre's content server as it runs: its process among /proc's, the port
 * it listens on from its sockets (else its --port, else calibre's
 * server-config.txt, else 8080), and whether it asks for a password. */
#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <mupdf/fitz.h>

#include "core/util.h"
#include "library/library.h"

char *calibre_config_dir(void) {
  const char *dir = getenv("CALIBRE_CONFIG_DIRECTORY"), *xdg = getenv("XDG_CONFIG_HOME");
  if (dir && *dir) return xstrdup(dir);
  if (xdg && *xdg) return xasprintf("%s/calibre", xdg);
  return path_expand("~/.config/calibre");
}

char *calibre_library_path(void) {
  char *dir = calibre_config_dir(), *path = xasprintf("%s/global.py.json", dir);
  free(dir);
  char *text = file_read(path, NULL), *found = NULL;
  free(path);
  if (!text) return NULL;
  fz_context *ctx = fz_new_context(NULL, NULL, 8 << 20);
  fz_pool *pool = NULL;
  fz_var(pool);
  if (ctx) {
    fz_try(ctx) {
      pool = fz_new_pool(ctx);
      fz_json *lib = fz_json_object_get(ctx, fz_parse_json(ctx, pool, text), "library_path");
      if (lib && fz_json_is_string(ctx, lib)) found = xstrdup(fz_json_to_string(ctx, lib));
    }
    fz_always(ctx) fz_drop_pool(ctx, pool);
    fz_catch(ctx) fz_ignore_error(ctx);
    fz_drop_context(ctx);
  }
  free(text);
  if (found) { /* only a library that is there */
    char *db = xasprintf("%s/metadata.db", found);
    int there = access(db, R_OK) == 0;
    free(db);
    if (!there) {
      free(found);
      found = NULL;
    }
  }
  return found;
}

/* ---- calibre's content server, as it runs ---- */

/* process pid's arguments, NUL-separated, and their length; NULL when not
 * to be read */
static char *cmdline(int pid, size_t *len) {
  char path[64];
  snprintf(path, sizeof path, "/proc/%d/cmdline", pid);
  return file_read(path, len);
}

/* is calibre-server among the arguments (itself, or the script python runs) */
static int is_server(const char *args, size_t len) {
  for (const char *a = args; a < args + len; a += strlen(a) + 1) {
    const char *base = strrchr(a, '/');
    if (!strcmp(base ? base + 1 : a, "calibre-server")) return 1;
  }
  return 0;
}

/* the value after --name (or in --name=value), else NULL */
static const char *arg_value(const char *args, size_t len, const char *name) {
  size_t n = strlen(name);
  for (const char *a = args; a < args + len; a += strlen(a) + 1) {
    if (!strncmp(a, name, n) && a[n] == '=') return a + n + 1;
    if (!strcmp(a, name) && a + n + 1 < args + len) return a + n + 1;
  }
  return NULL;
}

static int has_arg(const char *args, size_t len, const char *name) {
  for (const char *a = args; a < args + len; a += strlen(a) + 1)
    if (!strcmp(a, name)) return 1;
  return 0;
}

/* the port a socket of process pid listens on over TCP (from its file
 * descriptors and /proc/net/tcp, tcp6), and the address: 0 for none */
static int listening(int pid, char *addr, size_t size) {
  char path[64], fd[340], link[64];
  unsigned long inos[64];
  int nino = 0;
  snprintf(path, sizeof path, "/proc/%d/fd", pid);
  DIR *fds = opendir(path); /* another user's process: not to be read */
  for (struct dirent *d; fds && nino < 64 && (d = readdir(fds));) {
    snprintf(fd, sizeof fd, "%s/%s", path, d->d_name);
    ssize_t n = readlink(fd, link, sizeof link - 1);
    if (n <= 0) continue;
    link[n] = '\0';
    if (!strncmp(link, "socket:[", 8)) inos[nino++] = strtoul(link + 8, NULL, 10);
  }
  if (fds) closedir(fds);
  static const char *const tables[] = {"/proc/net/tcp", "/proc/net/tcp6"};
  for (int t = 0; t < 2; t++) {
    FILE *f = fopen(tables[t], "r");
    char line[512];
    while (f && fgets(line, sizeof line, f)) {
      char local[64];
      unsigned st;
      unsigned long ino;
      if (sscanf(line, "%*d: %63s %*s %x %*s %*s %*s %*s %*s %lu", local, &st, &ino) != 3 || st != 0x0a) continue;
      for (int i = 0; i < nino; i++) {
        if (inos[i] != ino) continue;
        char *colon = strrchr(local, ':');
        int port = colon ? (int)strtol(colon + 1, NULL, 16) : 0;
        /* every address (0.0.0.0, ::) is reached here, else the one it is on */
        int any = colon && strspn(local, "0") == (size_t)(colon - local);
        if (any || t == 1) snprintf(addr, size, "%s", t == 1 && !any ? "[::1]" : "127.0.0.1");
        else {
          unsigned a = (unsigned)strtoul(local, NULL, 16);
          snprintf(addr, size, "%u.%u.%u.%u", a & 0xff, (a >> 8) & 0xff, (a >> 16) & 0xff, a >> 24);
        }
        fclose(f);
        return port;
      }
    }
    if (f) fclose(f);
  }
  return 0;
}

/* calibre's own settings for its server (server-config.txt): a value of
 * one, "port 8080", "auth True" */
static char *server_option(const char *name) {
  char *dir = calibre_config_dir(), *path = xasprintf("%s/server-config.txt", dir);
  char *text = file_read(path, NULL), *found = NULL;
  free(dir);
  free(path);
  size_t n = strlen(name);
  for (char *p = text; p && *p && !found; p += strcspn(p, "\n") + (p[strcspn(p, "\n")] == '\n')) {
    size_t len = strcspn(p, "\n");
    if (len > n && !strncmp(p, name, n) && p[n] == ' ') found = xstrndup(p + n + 1, len - n - 1);
  }
  free(text);
  return found;
}

int calibre_server_find(const char *library, char **url, int *auth) {
  DIR *proc = opendir("/proc");
  if (!proc) return 0;
  int best = 0, best_ours = 0;
  for (struct dirent *e; (e = readdir(proc));) {
    if (e->d_name[0] < '1' || e->d_name[0] > '9') continue;
    size_t len;
    char *args = cmdline(atoi(e->d_name), &len);
    if (args && is_server(args, len)) {
      int ours = 0; /* one with this library among its arguments comes first */
      for (const char *a = args; library && a < args + len; a += strlen(a) + 1) {
        char *real = a[0] == '/' ? realpath(a, NULL) : NULL;
        ours = ours || (real && !strcmp(real, library));
        free(real);
      }
      if (!best || (ours && !best_ours)) {
        best = atoi(e->d_name);
        best_ours = ours;
      }
    }
    free(args);
  }
  closedir(proc);
  if (!best) return 0;
  size_t len;
  char *args = cmdline(best, &len), addr[64] = "127.0.0.1", *opt = NULL;
  int port = listening(best, addr, sizeof addr);
  const char *given = args ? arg_value(args, len, "--port") : NULL;
  if (!port && given) port = atoi(given);
  if (!port && (opt = server_option("port"))) port = atoi(opt);
  free(opt);
  if (!port) port = 8080; /* calibre's own default */
  *url = xasprintf("http://%s:%d", addr, port);
  opt = server_option("auth");
  *auth = args && (has_arg(args, len, "--enable-auth") ||
                   (!has_arg(args, len, "--disable-auth") && opt && !strncmp(opt, "True", 4)));
  free(opt);
  free(args);
  return best;
}
