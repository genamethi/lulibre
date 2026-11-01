/* Requests through libcurl on a libuv loop (curl.h). */
#include "core/curl.h"

#include <stdlib.h>
#include <string.h>

#include <curl/curl.h>

#include "core/util.h"

struct curl_uv {
  uv_loop_t *loop;
  CURLM *multi;
  uv_timer_t timer; /* libcurl's timeout */
  uv_timer_t later; /* reports the requests that ended without a transfer */
  struct curl_uv_xfer *active, *ended;
  struct sock *socks;
  int handles; /* uv handles not yet closed */
  int closing;
};

struct curl_uv_xfer {
  struct curl_uv *c;
  CURL *easy;
  struct curl_slist *hdrs;
  sbuf head, data;
  char errbuf[CURL_ERROR_SIZE];
  const char *fail; /* why it ended without a transfer */
  curl_uv_done *done;
  void *ud;
  struct curl_uv_xfer *next, *prev;
};

/* A socket libcurl asked to watch. */
struct sock {
  uv_poll_t poll;
  curl_socket_t fd;
  struct curl_uv *c;
  int closed;
  struct sock *next;
};

static void handle_closed(uv_handle_t *h) {
  struct curl_uv *c = h->data;
  if (--c->handles == 0 && c->closing) free(c);
}

static void sock_closed(uv_handle_t *h) {
  struct sock *s = (struct sock *)h;
  struct curl_uv *c = s->c;
  for (struct sock **p = &c->socks; *p; p = &(*p)->next)
    if (*p == s) {
      *p = s->next;
      break;
    }
  free(s);
  if (--c->handles == 0 && c->closing) free(c);
}

static void sock_close(struct sock *s) {
  if (s->closed) return;
  s->closed = 1;
  uv_poll_stop(&s->poll);
  uv_close((uv_handle_t *)&s->poll, sock_closed);
}

static void unlink_xfer(struct curl_uv_xfer **list, struct curl_uv_xfer *x) {
  if (x->prev) x->prev->next = x->next;
  else *list = x->next;
  if (x->next) x->next->prev = x->prev;
  x->next = x->prev = NULL;
}

static void push_xfer(struct curl_uv_xfer **list, struct curl_uv_xfer *x) {
  x->prev = NULL;
  x->next = *list;
  if (*list) (*list)->prev = x;
  *list = x;
}

static void xfer_free(struct curl_uv_xfer *x) {
  curl_easy_cleanup(x->easy);
  curl_slist_free_all(x->hdrs);
  sb_free(&x->head);
  sb_free(&x->data);
  free(x);
}

/* A request libcurl has finished with: done is told, and x goes. */
static void finished(struct curl_uv_xfer *x, CURLcode res) {
  struct curl_uv *c = x->c;
  curl_multi_remove_handle(c->multi, x->easy);
  unlink_xfer(&c->active, x);
  if (res != CURLE_OK) {
    x->done(NULL, x->errbuf[0] ? x->errbuf : curl_easy_strerror(res), x->ud);
  } else {
    struct curl_uv_resp r = {0};
    char *url = NULL;
    curl_easy_getinfo(x->easy, CURLINFO_RESPONSE_CODE, &r.status);
    curl_easy_getinfo(x->easy, CURLINFO_EFFECTIVE_URL, &url);
    r.url = url ? url : "";
    r.headers = x->head.s ? x->head.s : "";
    r.headers_len = x->head.len;
    r.body = x->data.s ? x->data.s : "";
    r.body_len = x->data.len;
    x->done(&r, NULL, x->ud);
  }
  xfer_free(x);
}

static void read_info(struct curl_uv *c) {
  CURLMsg *m;
  int left;
  while ((m = curl_multi_info_read(c->multi, &left))) {
    if (m->msg != CURLMSG_DONE) continue;
    struct curl_uv_xfer *x = NULL;
    CURLcode res = m->data.result;
    curl_easy_getinfo(m->easy_handle, CURLINFO_PRIVATE, (char **)&x);
    if (x) finished(x, res);
  }
}

static void poll_cb(uv_poll_t *h, int status, int events) {
  struct sock *s = (struct sock *)h;
  struct curl_uv *c = s->c;
  int flags = 0, running;
  if (status < 0) flags = CURL_CSELECT_ERR;
  else {
    if (events & UV_READABLE) flags |= CURL_CSELECT_IN;
    if (events & UV_WRITABLE) flags |= CURL_CSELECT_OUT;
  }
  curl_multi_socket_action(c->multi, s->fd, flags, &running);
  read_info(c);
}

static void timer_cb(uv_timer_t *h) {
  struct curl_uv *c = h->data;
  int running;
  curl_multi_socket_action(c->multi, CURL_SOCKET_TIMEOUT, 0, &running);
  read_info(c);
}

/* libcurl: watch socket fd for action, or stop watching it */
static int socket_fn(CURL *easy, curl_socket_t fd, int action, void *userp, void *socketp) {
  struct curl_uv *c = userp;
  struct sock *s = socketp;
  (void)easy;
  if (action == CURL_POLL_REMOVE) {
    if (s) {
      curl_multi_assign(c->multi, fd, NULL);
      sock_close(s);
    }
    return 0;
  }
  if (!s) {
    s = xcalloc(1, sizeof *s);
    s->fd = fd;
    s->c = c;
    if (uv_poll_init_socket(c->loop, &s->poll, fd)) {
      free(s);
      return -1;
    }
    c->handles++;
    s->next = c->socks;
    c->socks = s;
    curl_multi_assign(c->multi, fd, s);
  }
  int events = 0;
  if (action == CURL_POLL_IN || action == CURL_POLL_INOUT) events |= UV_READABLE;
  if (action == CURL_POLL_OUT || action == CURL_POLL_INOUT) events |= UV_WRITABLE;
  uv_poll_start(&s->poll, events, poll_cb);
  return 0;
}

/* libcurl: call back in timeout_ms; never from inside this call */
static int timer_fn(CURLM *multi, long timeout_ms, void *userp) {
  struct curl_uv *c = userp;
  (void)multi;
  if (timeout_ms < 0) uv_timer_stop(&c->timer);
  else uv_timer_start(&c->timer, timer_cb, (uint64_t)timeout_ms, 0);
  return 0;
}

static void later_cb(uv_timer_t *h) {
  struct curl_uv *c = h->data;
  while (c->ended) {
    struct curl_uv_xfer *x = c->ended;
    unlink_xfer(&c->ended, x);
    x->done(NULL, x->fail, x->ud);
    xfer_free(x);
  }
}

struct curl_uv *curl_uv_open(uv_loop_t *loop) {
  struct curl_uv *c = xcalloc(1, sizeof *c);
  c->loop = loop;
  c->multi = curl_multi_init();
  if (!c->multi) die("libcurl: cannot start");
  curl_multi_setopt(c->multi, CURLMOPT_SOCKETFUNCTION, socket_fn);
  curl_multi_setopt(c->multi, CURLMOPT_SOCKETDATA, c);
  curl_multi_setopt(c->multi, CURLMOPT_TIMERFUNCTION, timer_fn);
  curl_multi_setopt(c->multi, CURLMOPT_TIMERDATA, c);
  uv_timer_init(loop, &c->timer);
  uv_timer_init(loop, &c->later);
  c->timer.data = c->later.data = c;
  c->handles = 2;
  return c;
}

/* Ends x without a transfer: done is told why on the next loop turn. */
static void end_later(struct curl_uv_xfer *x, const char *why) {
  struct curl_uv *c = x->c;
  x->fail = why;
  push_xfer(&c->ended, x);
  uv_timer_start(&c->later, later_cb, 0, 0);
}

void curl_uv_cancel(struct curl_uv_xfer *x) {
  struct curl_uv *c = x->c;
  if (x->fail) return; /* already ending */
  curl_multi_remove_handle(c->multi, x->easy);
  unlink_xfer(&c->active, x);
  end_later(x, "cancelled");
}

void curl_uv_close(struct curl_uv *c) {
  if (!c) return;
  while (c->active) curl_uv_cancel(c->active);
  later_cb(&c->later); /* each is told now: the loop may not turn again */
  curl_multi_cleanup(c->multi);
  c->closing = 1;
  for (struct sock *s = c->socks; s; s = s->next) sock_close(s);
  uv_close((uv_handle_t *)&c->timer, handle_closed);
  uv_close((uv_handle_t *)&c->later, handle_closed);
}

static size_t body_cb(char *p, size_t size, size_t n, void *ud) {
  struct curl_uv_xfer *x = ud;
  sb_putn(&x->data, p, size * n);
  return size * n;
}

/* the header lines of each response; a redirect's are replaced by the next */
static size_t head_cb(char *p, size_t size, size_t n, void *ud) {
  struct curl_uv_xfer *x = ud;
  if (size * n >= 5 && !strncmp(p, "HTTP/", 5)) sb_reset(&x->head);
  sb_putn(&x->head, p, size * n);
  return size * n;
}

struct curl_uv_xfer *curl_uv_start(struct curl_uv *c, const struct curl_uv_req *req, curl_uv_done *done,
                                   void *ud) {
  struct curl_uv_xfer *x = xcalloc(1, sizeof *x);
  x->c = c;
  x->done = done;
  x->ud = ud;
  x->easy = curl_easy_init();
  if (!x->easy) die("libcurl: cannot start a request");
  CURL *e = x->easy;
  curl_easy_setopt(e, CURLOPT_URL, req->url);
  curl_easy_setopt(e, CURLOPT_PRIVATE, (char *)x);
  curl_easy_setopt(e, CURLOPT_ERRORBUFFER, x->errbuf);
  curl_easy_setopt(e, CURLOPT_NOSIGNAL, 1L);
  curl_easy_setopt(e, CURLOPT_FOLLOWLOCATION, 1L);
  curl_easy_setopt(e, CURLOPT_MAXREDIRS, 10L);
  curl_easy_setopt(e, CURLOPT_ACCEPT_ENCODING, "");
  curl_easy_setopt(e, CURLOPT_WRITEFUNCTION, body_cb);
  curl_easy_setopt(e, CURLOPT_WRITEDATA, x);
  curl_easy_setopt(e, CURLOPT_HEADERFUNCTION, head_cb);
  curl_easy_setopt(e, CURLOPT_HEADERDATA, x);
  if (req->timeout_ms > 0) curl_easy_setopt(e, CURLOPT_TIMEOUT_MS, req->timeout_ms);
  if (req->body) {
    curl_easy_setopt(e, CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t)req->body_len);
    curl_easy_setopt(e, CURLOPT_COPYPOSTFIELDS, req->body);
  }
  const char *plain = req->body ? "POST" : "GET";
  if (req->method && strcmp(req->method, plain)) {
    if (!strcmp(req->method, "HEAD")) curl_easy_setopt(e, CURLOPT_NOBODY, 1L);
    else curl_easy_setopt(e, CURLOPT_CUSTOMREQUEST, req->method);
  }
  for (int i = 0; i < req->nheaders; i++) x->hdrs = curl_slist_append(x->hdrs, req->headers[i]);
  if (x->hdrs) curl_easy_setopt(e, CURLOPT_HTTPHEADER, x->hdrs);
  if (curl_multi_add_handle(c->multi, e) != CURLM_OK) {
    end_later(x, "libcurl refused the request");
  } else {
    push_xfer(&c->active, x);
  }
  return x;
}
