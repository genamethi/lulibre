/* The metadata a file carries beside its pages, as text: a PDF's XMP packet
 * and Info dictionary, an EPUB's package document (the OPF). Publishers put
 * a work's own identifiers there (prism:doi, dc:identifier); what to make of
 * them is left to Lua (lua/lulibre/ids.lua, from_metadata). */
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#include <mupdf/fitz.h>
#include <mupdf/pdf.h>

#include "core/util.h"
#include "doc/doc.h"

/* no more than this much of any one part is kept */
#define META_MAX (1 << 20)

static void quiet(void *user, const char *message) {
  (void)user;
  (void)message;
}

static void put_buffer(fz_context *ctx, sbuf *out, fz_buffer *b) {
  unsigned char *data = NULL;
  size_t n = fz_buffer_storage(ctx, b, &data);
  if (n > META_MAX) n = META_MAX;
  sb_putn(out, (const char *)data, n);
  sb_putc(out, '\n');
}

/* the OPF named by META-INF/container.xml: <rootfile full-path="..."> */
static void epub_package(fz_context *ctx, const char *path, sbuf *out) {
  fz_archive *arch = fz_open_archive(ctx, path);
  fz_buffer *container = NULL, *opf = NULL;
  fz_var(container);
  fz_var(opf);
  fz_try(ctx) {
    container = fz_read_archive_entry(ctx, arch, "META-INF/container.xml");
    const char *text = fz_string_from_buffer(ctx, container);
    const char *at = strstr(text, "full-path=\"");
    if (at) {
      at += strlen("full-path=\"");
      const char *end = strchr(at, '"');
      if (end && end - at < 512) {
        char name[512];
        memcpy(name, at, (size_t)(end - at));
        name[end - at] = 0;
        opf = fz_read_archive_entry(ctx, arch, name);
        put_buffer(ctx, out, opf);
      }
    }
  }
  fz_always(ctx) {
    fz_drop_buffer(ctx, container);
    fz_drop_buffer(ctx, opf);
    fz_drop_archive(ctx, arch);
  }
  fz_catch(ctx) fz_ignore_error(ctx);
}

static void pdf_parts(fz_context *ctx, pdf_document *pdf, sbuf *out) {
  pdf_obj *trailer = pdf_trailer(ctx, pdf);
  pdf_obj *meta = pdf_dict_getp(ctx, trailer, "Root/Metadata");
  if (pdf_is_stream(ctx, meta)) {
    fz_buffer *b = NULL;
    fz_var(b);
    fz_try(ctx) {
      b = pdf_load_stream(ctx, meta);
      put_buffer(ctx, out, b);
    }
    fz_always(ctx) fz_drop_buffer(ctx, b);
    fz_catch(ctx) fz_ignore_error(ctx);
  }
  pdf_obj *info = pdf_dict_get(ctx, trailer, PDF_NAME(Info));
  int n = pdf_dict_len(ctx, info);
  for (int i = 0; i < n; i++) {
    pdf_obj *val = pdf_dict_get_val(ctx, info, i);
    if (!pdf_is_string(ctx, val)) continue;
    const char *s = pdf_to_text_string(ctx, val);
    if (!s || !*s) continue;
    sb_printf(out, "%s: ", pdf_to_name(ctx, pdf_dict_get_key(ctx, info, i)));
    sb_putn(out, s, strnlen(s, 4096));
    sb_putc(out, '\n');
  }
}

char *doc_metadata(const char *path, char **err) {
  fz_context *ctx = fz_new_context(NULL, NULL, 32 << 20);
  if (!ctx) {
    *err = xstrdup("mupdf: cannot create context");
    return NULL;
  }
  fz_set_warning_callback(ctx, quiet, NULL);
  fz_set_error_callback(ctx, quiet, NULL);
  sbuf out = SBUF_INIT;
  const char *ext = strrchr(path, '.');
  fz_document *doc = NULL;
  fz_var(doc);
  fz_try(ctx) {
    fz_register_document_handlers(ctx);
    if (ext && !strcasecmp(ext, ".epub")) {
      epub_package(ctx, path, &out);
    } else {
      doc = fz_open_document(ctx, path);
      pdf_document *pdf = pdf_specifics(ctx, doc);
      if (pdf) pdf_parts(ctx, pdf, &out);
    }
  }
  fz_always(ctx) fz_drop_document(ctx, doc);
  fz_catch(ctx) {
    if (!*err) *err = xstrdup(fz_caught_message(ctx));
  }
  fz_drop_context(ctx);
  if (*err) {
    sb_free(&out);
    return NULL;
  }
  return sb_take(&out);
}
