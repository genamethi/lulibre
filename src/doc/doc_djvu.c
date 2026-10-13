/* DjVu through djvulibre: the hidden text layer, line by line.
 *
 * DjVu carries no font information, so a line's "size" is its height. The
 * s-expression API keeps global state, so DjVu extraction is serialised
 * behind one mutex; these files are a small share of any library. */
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

#include <libdjvu/ddjvuapi.h>
#include <libdjvu/miniexp.h>

#include "core/util.h"
#include "doc/doc.h"

/* Shared with doc_render.c. */
pthread_mutex_t doc_djvu_lock = PTHREAD_MUTEX_INITIALIZER;
#define djvu_lock doc_djvu_lock
static ddjvu_context_t *djvu_ctx;

ddjvu_context_t *doc_djvu_context(void) {
  if (!djvu_ctx) djvu_ctx = ddjvu_context_create("lulibre");
  return djvu_ctx;
}

/* Drain the message queue, keeping the first error message seen. */
void doc_djvu_pump(int wait, char **errmsg) {
  const ddjvu_message_t *msg;
  if (wait) ddjvu_message_wait(djvu_ctx);
  while ((msg = ddjvu_message_peek(djvu_ctx))) {
    if (msg->m_any.tag == DDJVU_ERROR && errmsg && !*errmsg && msg->m_error.message)
      *errmsg = xstrdup(msg->m_error.message);
    ddjvu_message_pop(djvu_ctx);
  }
}

struct walk {
  struct doc_page *pg;
  float scale; /* pixels -> points */
  float page_h; /* pixels */
  int depth;
};

/* A text zone is (type x0 y0 x1 y1 child...), children being either strings
 * or nested zones. Emit one line per zone that directly holds strings. */
static void walk(struct walk *w, miniexp_t e, int first_in_block) {
  if (!miniexp_consp(e) || miniexp_length(e) < 5 || w->depth > 16) return;
  int x0 = miniexp_to_int(miniexp_nth(1, e)), y0 = miniexp_to_int(miniexp_nth(2, e));
  int x1 = miniexp_to_int(miniexp_nth(3, e)), y1 = miniexp_to_int(miniexp_nth(4, e));

  sbuf text = SBUF_INIT;
  int child_first = 1;
  w->depth++;
  for (miniexp_t r = miniexp_cdr(miniexp_cdr(miniexp_cdr(miniexp_cdr(miniexp_cdr(e)))));
       miniexp_consp(r); r = miniexp_cdr(r)) {
    miniexp_t c = miniexp_car(r);
    if (miniexp_stringp(c)) {
      if (text.len) sb_putc(&text, ' ');
      sb_puts(&text, miniexp_to_str(c));
    } else {
      int before = w->pg->nlines;
      walk(w, c, child_first);
      if (w->pg->nlines > before) child_first = 0;
    }
  }
  w->depth--;

  if (text.len) {
    for (size_t i = 0; i < text.len; i++)
      if ((unsigned char)text.s[i] < 0x20) text.s[i] = ' ';
    /* DjVu's origin is the bottom left */
    doc_page_add_line(w->pg, sb_take(&text), (float)(y1 - y0) * w->scale,
                      first_in_block ? LINE_BLOCK : 0, (float)x0 * w->scale,
                      (w->page_h - (float)y1) * w->scale, (float)x1 * w->scale,
                      (w->page_h - (float)y0) * w->scale);
  } else {
    sb_free(&text);
  }
}

static void extract_locked(const char *path, const struct doc_opts *o, struct doc_info *out) {
  char *errmsg = NULL;
  if (!doc_djvu_context()) {
    out->error = xstrdup("djvu: cannot create context");
    return;
  }
  ddjvu_document_t *doc = ddjvu_document_create_by_filename_utf8(djvu_ctx, path, TRUE);
  if (!doc) {
    out->error = xstrdup("djvu: cannot open");
    return;
  }
  while (!ddjvu_document_decoding_done(doc)) doc_djvu_pump(1, &errmsg);
  if (ddjvu_document_decoding_error(doc)) {
    out->error = xasprintf("djvu: %s", errmsg ? errmsg : "decoding failed");
    goto done;
  }

  out->npages = ddjvu_document_get_pagenum(doc);
  int n = out->npages < o->pages ? out->npages : o->pages;
  out->pages = xcalloc((size_t)(n > 0 ? n : 0), sizeof *out->pages);
  int from = o->tail ? out->npages - n : 0; /* the last pages instead of the first */
  for (int i = 0; i < n; i++) {
    struct doc_page *pg = &out->pages[i];
    int page = from + i;
    pg->no = page + 1;
    out->n = i + 1;

    ddjvu_pageinfo_t info;
    ddjvu_status_t st;
    while ((st = ddjvu_document_get_pageinfo(doc, page, &info)) < DDJVU_JOB_OK) doc_djvu_pump(1, NULL);
    if (st >= DDJVU_JOB_FAILED || info.dpi <= 0) {
      doc_page_finish(pg, 0);
      continue;
    }
    struct walk w = {pg, 72.0f / (float)info.dpi, (float)info.height, 0};
    pg->w = (float)info.width * w.scale;
    pg->h = (float)info.height * w.scale;

    miniexp_t r;
    while ((r = ddjvu_document_get_pagetext(doc, page, "line")) == miniexp_dummy) doc_djvu_pump(1, NULL);
    if (r != miniexp_nil) {
      walk(&w, r, 1);
      ddjvu_miniexp_release(doc, r);
    }
    doc_page_finish(pg, i < o->layout_pages);
  }
done:
  doc_djvu_pump(0, NULL);
  free(errmsg);
  ddjvu_document_release(doc);
}

void doc_djvu_extract(const char *path, const struct doc_opts *o, struct doc_info *out) {
  pthread_mutex_lock(&djvu_lock);
  extract_locked(path, o, out);
  pthread_mutex_unlock(&djvu_lock);
}
