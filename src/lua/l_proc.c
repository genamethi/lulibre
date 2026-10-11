/* Subprocesses, without blocking.
 *
 *   local r = lulibre.system({"calibredb", "--version"} [, opts])
 *     opts.stdin    string fed to the process
 *     opts.cwd      working directory
 *     opts.timeout  milliseconds before the process is killed
 *   r = { code = exit status, signal = terminating signal or 0,
 *         stdout = "...", stderr = "...", timed_out = bool }
 *   or nil, message if the process could not be started.
 *
 * Waits, so it must be called from a task. */
#include <signal.h>
#include <stdlib.h>
#include <string.h>

#include <lua.h>
#include <lauxlib.h>

#include "app.h"
#include "core/log.h"
#include "core/util.h"
#include "lua/lapi.h"
#include "lua/sched.h"

struct proc {
  uv_process_t process;
  uv_pipe_t in, out, err;
  uv_timer_t timer;
  uv_write_t write;
  struct task *task;
  sbuf so, se;
  char *input;
  int have_in, in_closed, have_timer;
  int exited, out_eof, err_eof, finishing;
  int closing; /* handles still to close */
  int64_t code;
  int sig, timed_out;
  double started;
  char *what; /* the command line, for the trace */
};

static void closed(uv_handle_t *h) {
  struct proc *p = h->data;
  if (--p->closing > 0) return;
  lua_State *L = p->task ? sched_end_wait(p->task) : NULL;
  if (L) {
    lua_createtable(L, 0, 5);
    lua_pushinteger(L, p->code);
    lua_setfield(L, -2, "code");
    lua_pushinteger(L, p->sig);
    lua_setfield(L, -2, "signal");
    lua_pushlstring(L, p->so.s ? p->so.s : "", p->so.len);
    lua_setfield(L, -2, "stdout");
    lua_pushlstring(L, p->se.s ? p->se.s : "", p->se.len);
    lua_setfield(L, -2, "stderr");
    lua_pushboolean(L, p->timed_out);
    lua_setfield(L, -2, "timed_out");
    sched_wake(p->task, 1);
  }
  sb_free(&p->so);
  sb_free(&p->se);
  free(p->input);
  free(p->what);
  free(p);
}

/* Once the process has exited, both pipes have drained and stdin is shut,
 * close everything; the result is delivered from the last close callback. */
static void maybe_finish(struct proc *p) {
  if (p->finishing || !p->exited || !p->out_eof || !p->err_eof) return;
  if (p->have_in && !p->in_closed) return;
  p->finishing = 1;
  uv_handle_t *hs[] = {(uv_handle_t *)&p->process, (uv_handle_t *)&p->out, (uv_handle_t *)&p->err,
                       p->have_timer ? (uv_handle_t *)&p->timer : NULL};
  for (size_t i = 0; i < ARRAY_LEN(hs); i++)
    if (hs[i]) {
      p->closing++;
      uv_close(hs[i], closed);
    }
}

static void in_closed_cb(uv_handle_t *h) {
  struct proc *p = h->data;
  p->in_closed = 1;
  maybe_finish(p);
}

static void on_exit_cb(uv_process_t *h, int64_t status, int sig) {
  struct proc *p = h->data;
  p->exited = 1;
  p->code = status;
  p->sig = sig;
  log_debug("exit %lld%s after %.0f ms: %s", (long long)status, p->timed_out ? " (timed out)" : "",
            (now_s() - p->started) * 1000, p->what ? p->what : "");
  free(p->what);
  p->what = NULL;
  maybe_finish(p);
}

static void alloc_cb(uv_handle_t *h, size_t hint, uv_buf_t *buf) {
  buf->base = xmalloc(hint);
  buf->len = hint;
}

static void read_cb(uv_stream_t *s, ssize_t n, const uv_buf_t *buf) {
  struct proc *p = s->data;
  int is_out = s == (uv_stream_t *)&p->out;
  if (n > 0) sb_putn(is_out ? &p->so : &p->se, buf->base, (size_t)n);
  free(buf->base);
  if (n < 0) {
    uv_read_stop(s);
    if (is_out) p->out_eof = 1;
    else p->err_eof = 1;
    maybe_finish(p);
  }
}

static void wrote_cb(uv_write_t *w, int status) {
  struct proc *p = w->data;
  uv_close((uv_handle_t *)&p->in, in_closed_cb); /* EOF for the child */
}

static void kill_cb(void *ud) {
  struct proc *p = ud;
  if (!p->exited) uv_process_kill(&p->process, SIGTERM);
}

static void timeout_cb(uv_timer_t *h) {
  struct proc *p = h->data;
  p->timed_out = 1;
  if (!p->exited) uv_process_kill(&p->process, SIGKILL);
}

static int l_system(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  sched_require_task(L);
  struct app *app = lapi_app(L);
  int n = (int)lua_rawlen(L, 1);
  luaL_argcheck(L, n > 0, 1, "an argument list such as {\"ls\", \"-l\"}");

  const char *cwd = NULL, *input = NULL;
  size_t input_len = 0;
  lua_Integer timeout = 0;
  if (lua_istable(L, 2)) {
    lua_getfield(L, 2, "cwd");
    cwd = lua_tostring(L, -1);
    lua_getfield(L, 2, "stdin");
    input = lua_tolstring(L, -1, &input_len);
    lua_getfield(L, 2, "timeout");
    timeout = lua_tointeger(L, -1);
  }
  char **argv = xcalloc((size_t)n + 1, sizeof *argv);
  for (int i = 0; i < n; i++) {
    lua_rawgeti(L, 1, i + 1);
    const char *a = luaL_tolstring(L, -1, NULL);
    argv[i] = xstrdup(a);
    lua_pop(L, 2);
  }

  struct proc *p = xcalloc(1, sizeof *p);
  uv_loop_t *loop = app->lloop;
  uv_pipe_init(loop, &p->out, 0);
  uv_pipe_init(loop, &p->err, 0);
  p->process.data = p->out.data = p->err.data = p->in.data = p->timer.data = p->write.data = p;
  uv_stdio_container_t stdio[3];
  stdio[0].flags = UV_IGNORE;
  if (input) {
    uv_pipe_init(loop, &p->in, 0);
    p->have_in = 1;
    stdio[0].flags = UV_CREATE_PIPE | UV_READABLE_PIPE;
    stdio[0].data.stream = (uv_stream_t *)&p->in;
  }
  stdio[1].flags = UV_CREATE_PIPE | UV_WRITABLE_PIPE;
  stdio[1].data.stream = (uv_stream_t *)&p->out;
  stdio[2].flags = UV_CREATE_PIPE | UV_WRITABLE_PIPE;
  stdio[2].data.stream = (uv_stream_t *)&p->err;

  uv_process_options_t po;
  memset(&po, 0, sizeof po);
  po.file = argv[0];
  po.args = argv;
  po.cwd = cwd;
  po.stdio = stdio;
  po.stdio_count = 3;
  po.exit_cb = on_exit_cb;
  if (LULIBRE_DEBUG) {
    sbuf line = SBUF_INIT;
    for (int i = 0; i < n; i++) sb_printf(&line, "%s%s", i ? " " : "", argv[i]);
    p->what = sb_take(&line);
    log_debug("run: %s", p->what);
  }
  p->started = now_s();
  int rc = uv_spawn(loop, &p->process, &po);
  if (rc) {
    /* the handles exist even though nothing started: close them through the
     * loop (which frees p), and report failure to the caller right away */
    lua_pushnil(L);
    lua_pushfstring(L, "cannot run %s: %s", argv[0], uv_strerror(rc));
    for (int i = 0; i < n; i++) free(argv[i]);
    free(argv);
    p->finishing = 1;
    uv_handle_t *hs[] = {(uv_handle_t *)&p->process, (uv_handle_t *)&p->out,
                         (uv_handle_t *)&p->err, p->have_in ? (uv_handle_t *)&p->in : NULL};
    for (size_t i = 0; i < ARRAY_LEN(hs); i++)
      if (hs[i]) {
        p->closing++;
        uv_close(hs[i], closed);
      }
    return 2;
  }
  for (int i = 0; i < n; i++) free(argv[i]);
  free(argv);
  p->task = sched_begin_wait(L);

  uv_read_start((uv_stream_t *)&p->out, alloc_cb, read_cb);
  uv_read_start((uv_stream_t *)&p->err, alloc_cb, read_cb);
  if (input) {
    p->input = xstrndup(input, input_len);
    uv_buf_t b = uv_buf_init(p->input, (unsigned)input_len);
    if (uv_write(&p->write, (uv_stream_t *)&p->in, &b, 1, wrote_cb) != 0)
      uv_close((uv_handle_t *)&p->in, in_closed_cb);
  }
  if (timeout > 0) {
    uv_timer_init(loop, &p->timer);
    p->have_timer = 1;
    uv_timer_start(&p->timer, timeout_cb, (uint64_t)timeout, 0);
  }
  sched_on_cancel(p->task, kill_cb, p);
  return lua_yield(L, 0);
}

void l_proc_open(lua_State *L) {
  static const luaL_Reg fns[] = {{"system", l_system}, {NULL, NULL}};
  luaL_setfuncs(L, fns, 0);
}
