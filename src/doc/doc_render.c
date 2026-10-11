/* Page rendering for the graphic preview. Like extraction, safe on a worker
 * thread; the result is a plain RGBA buffer the UI thread can blit. */
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <libdjvu/ddjvuapi.h>
#include <mupdf/fitz.h>

#include "core/util.h"
#include "doc/doc.h"

static void quiet(void *user, const char *message) {
  (void)user;
  (void)message;
}

static void render_mupdf(const char *path, int page, int width, float aspect,
                         struct doc_image *out) {
  fz_context *ctx = fz_new_context(NULL, NULL, 64 << 20);
  if (!ctx) {
    out->error = xstrdup("mupdf: cannot create context");
    return;
  }
  fz_set_warning_callback(ctx, quiet, NULL);
  fz_set_error_callback(ctx, quiet, NULL);
  fz_document *doc = NULL;
  fz_page *pg = NULL;
  fz_pixmap *pix = NULL;
  fz_var(doc);
  fz_var(pg);
  fz_var(pix);
  fz_try(ctx) {
    fz_register_document_handlers(ctx);
    doc = fz_open_document(ctx, path);
    if (fz_needs_password(ctx, doc) && !fz_authenticate_password(ctx, doc, ""))
      fz_throw(ctx, FZ_ERROR_GENERIC, "password protected");
    if (fz_is_document_reflowable(ctx, doc)) fz_layout_document(ctx, doc, 595, 842, 11);
    int n = fz_count_pages(ctx, doc);
    if (page < 0 || page >= n) fz_throw(ctx, FZ_ERROR_GENERIC, "no page %d", page + 1);
    pg = fz_load_page(ctx, doc, page);
    fz_rect box = fz_bound_page(ctx, pg);
    float pw = box.x1 - box.x0;
    float zoom = pw > 0 ? (float)width / pw : 1;
    pix = fz_new_pixmap_from_page(ctx, pg, fz_scale(zoom, zoom / aspect), fz_device_rgb(ctx), 0);
    int w = fz_pixmap_width(ctx, pix), h = fz_pixmap_height(ctx, pix);
    int comps = fz_pixmap_components(ctx, pix);
    ptrdiff_t stride = fz_pixmap_stride(ctx, pix);
    unsigned char *src = fz_pixmap_samples(ctx, pix);
    out->w = w;
    out->h = h;
    out->rgba = xmalloc((size_t)w * (size_t)h * 4);
    for (int y = 0; y < h; y++) {
      unsigned char *s = src + (ptrdiff_t)y * stride, *d = out->rgba + (size_t)y * (size_t)w * 4;
      for (int x = 0; x < w; x++, s += comps, d += 4) {
        d[0] = s[0];
        d[1] = comps >= 3 ? s[1] : s[0];
        d[2] = comps >= 3 ? s[2] : s[0];
        d[3] = 255;
      }
    }
  }
  fz_always(ctx) {
    fz_drop_pixmap(ctx, pix);
    fz_drop_page(ctx, pg);
    fz_drop_document(ctx, doc);
  }
  fz_catch(ctx) {
    out->error = xstrdup(fz_caught_message(ctx));
    fz_ignore_error(ctx);
  }
  fz_drop_context(ctx);
}

/* DjVu shares the one context and lock in doc_djvu.c. */
extern pthread_mutex_t doc_djvu_lock;
ddjvu_context_t *doc_djvu_context(void);
void doc_djvu_pump(int wait, char **errmsg);

static void render_djvu(const char *path, int page, int width, float aspect,
                        struct doc_image *out) {
  pthread_mutex_lock(&doc_djvu_lock);
  ddjvu_context_t *ctx = doc_djvu_context();
  ddjvu_document_t *doc = ctx ? ddjvu_document_create_by_filename_utf8(ctx, path, TRUE) : NULL;
  ddjvu_page_t *pg = NULL;
  ddjvu_format_t *fmt = NULL;
  unsigned char *rgb = NULL;
  if (!doc) {
    out->error = xstrdup("djvu: cannot open");
    goto done;
  }
  while (!ddjvu_document_decoding_done(doc)) doc_djvu_pump(1, NULL);
  if (ddjvu_document_decoding_error(doc) || page < 0 || page >= ddjvu_document_get_pagenum(doc)) {
    out->error = xstrdup("djvu: cannot decode");
    goto done;
  }
  pg = ddjvu_page_create_by_pageno(doc, page);
  if (!pg) {
    out->error = xstrdup("djvu: cannot load page");
    goto done;
  }
  while (!ddjvu_page_decoding_done(pg)) doc_djvu_pump(1, NULL);
  int pw = ddjvu_page_get_width(pg), ph = ddjvu_page_get_height(pg);
  if (ddjvu_page_decoding_error(pg) || pw <= 0 || ph <= 0) {
    out->error = xstrdup("djvu: cannot decode page");
    goto done;
  }
  int w = width, h = (int)((double)ph * width / pw / aspect);
  if (h < 1) h = 1;
  ddjvu_rect_t rect = {0, 0, (unsigned)w, (unsigned)h};
  fmt = ddjvu_format_create(DDJVU_FORMAT_RGB24, 0, NULL);
  ddjvu_format_set_row_order(fmt, 1);
  rgb = xmalloc((size_t)w * (size_t)h * 3);
  memset(rgb, 255, (size_t)w * (size_t)h * 3);
  if (!ddjvu_page_render(pg, DDJVU_RENDER_COLOR, &rect, &rect, fmt, (unsigned long)w * 3,
                         (char *)rgb)) {
    out->error = xstrdup("djvu: nothing to render");
    goto done;
  }
  out->w = w;
  out->h = h;
  out->rgba = xmalloc((size_t)w * (size_t)h * 4);
  for (size_t i = 0, n = (size_t)w * (size_t)h; i < n; i++) {
    out->rgba[i * 4] = rgb[i * 3];
    out->rgba[i * 4 + 1] = rgb[i * 3 + 1];
    out->rgba[i * 4 + 2] = rgb[i * 3 + 2];
    out->rgba[i * 4 + 3] = 255;
  }
done:
  free(rgb);
  if (fmt) ddjvu_format_release(fmt);
  if (pg) ddjvu_page_release(pg);
  if (doc) ddjvu_document_release(doc);
  pthread_mutex_unlock(&doc_djvu_lock);
}

void doc_render(const char *path, int page, int width, float aspect, struct doc_image *out) {
  memset(out, 0, sizeof *out);
  if (aspect < 0.25f || aspect > 4.0f) aspect = 1.0f;
  if (width < 16) width = 16;
  if (width > 4096) width = 4096;
  char magic[8] = {0};
  FILE *f = fopen(path, "rb");
  if (!f) {
    out->error = xstrdup("cannot open file");
    return;
  }
  size_t got = fread(magic, 1, sizeof magic, f);
  fclose(f);
  if (got >= 8 && memcmp(magic, "AT&TFORM", 8) == 0) render_djvu(path, page, width, aspect, out);
  else render_mupdf(path, page, width, aspect, out);
}

void doc_image_free(struct doc_image *img) {
  free(img->rgba);
  free(img->error);
  memset(img, 0, sizeof *img);
}
