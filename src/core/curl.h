#ifndef LULIBRE_CURL_H
#define LULIBRE_CURL_H

/* Requests through libcurl on a libuv loop: libcurl's multi interface
 * says which sockets to watch and when to time out, and the loop watches
 * them (curl's docs/examples/multi-uv.c). Nothing blocks: a request is
 * started, and its done callback runs on the loop when it ends. Any number
 * run at once. Everything here belongs to the loop's thread.
 *
 * curl_global_init runs once, in main, before any thread starts. */

#include <stddef.h>

#include <uv.h>

struct curl_uv;
struct curl_uv_xfer;

/* What to ask. Only url is required: the method is GET, or POST with a
 * body; headers are "Name: value"; timeout_ms 0 is none. Redirects are
 * followed. Everything is copied: it need not outlive the call. */
struct curl_uv_req {
  const char *url;
  const char *method;
  const char *const *headers;
  int nheaders;
  const char *body;
  size_t body_len;
  long timeout_ms;
};

/* What came back: the status, the header lines of the last response (after
 * redirects) as received, the body, and the URL it came from. */
struct curl_uv_resp {
  long status;
  const char *headers;
  size_t headers_len;
  const char *body;
  size_t body_len;
  const char *url;
};

/* resp on success, whatever the status; else err ("cancelled" after
 * curl_uv_cancel or curl_uv_close). Called once, on the loop, never from
 * inside curl_uv_start or curl_uv_cancel. */
typedef void curl_uv_done(const struct curl_uv_resp *resp, const char *err, void *ud);

struct curl_uv *curl_uv_open(uv_loop_t *loop);
/* Cancels what is in flight, each done told before this returns, and
 * frees c once the loop has closed its handles. Not from inside a done. */
void curl_uv_close(struct curl_uv *c);

/* Starts a request. Returns its handle, valid until done runs. */
struct curl_uv_xfer *curl_uv_start(struct curl_uv *c, const struct curl_uv_req *req, curl_uv_done *done,
                                   void *ud);
void curl_uv_cancel(struct curl_uv_xfer *x);

#endif
