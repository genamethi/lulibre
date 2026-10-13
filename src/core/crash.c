/* When lulibre crashes: leave a trace.
 *
 * A fatal signal appends the version, the signal and a backtrace to
 * ~/.local/state/lulibre/crash.log (or $XDG_STATE_HOME/lulibre/), then lets
 * the handlers that were there before (notcurses' own, which gives the
 * terminal back) and the default action (a core dump) run as usual. Frames
 * are printed as binary(+0xOFFSET); `addr2line -fe $(command -v lulibre)
 * 0xOFFSET` names the line. */
#include <execinfo.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <config.h>

#include "core/util.h"
#include "version.h"

/* which build this is (app.c, build/buildno.c) */
extern const char lulibre_build_number[], lulibre_build_commit[];

static const int fatal[] = {SIGSEGV, SIGBUS, SIGFPE, SIGILL, SIGABRT};
static struct sigaction before[sizeof fatal / sizeof fatal[0]];
static char path[1024];

static void put(int fd, const char *s) {
  ssize_t r = write(fd, s, strlen(s));
  (void)r;
}

static void put_num(int fd, long v) {
  char buf[24];
  int i = sizeof buf;
  buf[--i] = '\0';
  do buf[--i] = (char)('0' + v % 10);
  while ((v /= 10) > 0 && i > 0);
  put(fd, buf + i);
}

static void on_fatal(int sig) {
  /* only what may be called from a signal handler */
  int fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0600);
  if (fd >= 0) {
    put(fd, "\nlulibre " LULIBRE_VERSION " (" LULIBRE_BUILD " build ");
    put(fd, lulibre_build_number);
    put(fd, " from ");
    put(fd, lulibre_build_commit);
    put(fd, ", Lua " LULIBRE_LUA_VER "): signal ");
    put_num(fd, sig);
    put(fd, " at unix time ");
    put_num(fd, (long)time(NULL));
    put(fd, "\n");
    void *frames[64];
    int n = backtrace(frames, 64);
    backtrace_symbols_fd(frames, n, fd);
    close(fd);
  }
  /* hand over to whoever was there before, then to the default */
  for (size_t i = 0; i < sizeof fatal / sizeof fatal[0]; i++)
    if (fatal[i] == sig) sigaction(sig, &before[i], NULL);
  raise(sig);
}

const char *crash_log_path(void) {
  return path;
}

void crash_install(void) {
  const char *xdg = getenv("XDG_STATE_HOME");
  char *dir = xdg && xdg[0] ? xasprintf("%s/lulibre", xdg) : path_expand("~/.local/state/lulibre");
  mkdir_p(dir);
  snprintf(path, sizeof path, "%s/crash.log", dir);
  free(dir);
  void *warm[2];
  backtrace(warm, 2); /* loads what backtrace needs now, not inside the handler */
  struct sigaction sa;
  memset(&sa, 0, sizeof sa);
  sa.sa_handler = on_fatal;
  sa.sa_flags = SA_ONSTACK | SA_NODEFER;
  sigemptyset(&sa.sa_mask);
  for (size_t i = 0; i < sizeof fatal / sizeof fatal[0]; i++) sigaction(fatal[i], &sa, &before[i]);
}
