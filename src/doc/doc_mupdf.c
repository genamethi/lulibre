/* PDF, EPUB, FB2, MOBI and friends through MuPDF.
 *
 * Each call builds its own fz_context, so calls on different threads share
 * nothing and need no locking. */
#include <math.h>
#include <stdlib.h>
#include <string.h>

#include <mupdf/fitz.h>

#include "core/util.h"
#include "doc/doc.h"

static void quiet(void *user, const char *message) {
  (void)user;
  (void)message;
}

static char *lookup(fz_context *ctx, fz_document *doc, const char *key) {
  char buf[1024];
  int n = -1;
  fz_var(n);
  fz_try(ctx)
    n = fz_lookup_metadata(ctx, doc, key, buf, sizeof buf);
  fz_catch(ctx) {
    fz_ignore_error(ctx);
    n = -1;
  }
  if (n <= 1) return NULL; /* n counts the terminator */
  buf[sizeof buf - 1] = '\0';
  const char *s = buf;
  while (*s == ' ') s++;
  return *s ? xstrdup(s) : NULL;
}

static void add_line(fz_context *ctx, struct doc_page *pg, fz_stext_line *line, int first) {
  sbuf text = SBUF_INIT;
  float size = 0, base_y = 0;
  int n = 0, bold = 0, italic = 0, mono = 0;

  for (fz_stext_char *c = line->first_char; c; c = c->next) {
    char utf[8];
    int r = c->c < 0x20 ? ' ' : c->c; /* stray control characters, NUL included */
    sb_putn(&text, utf, (size_t)fz_runetochar(utf, r));
    if (r == ' ' || r == 0xa0) continue;
    n++;
    if (c->size > size) {
      size = c->size;
      base_y = c->origin.y;
    }
    if ((c->flags & FZ_STEXT_BOLD) || (c->font && fz_font_is_bold(ctx, c->font))) bold++;
    if (c->font && fz_font_is_italic(ctx, c->font)) italic++;
    if (c->font && fz_font_is_monospaced(ctx, c->font)) mono++;
  }
  if (n == 0) {
    sb_free(&text);
    return;
  }

  unsigned flags = first ? LINE_BLOCK : 0;
  if (bold * 2 > n) flags |= LINE_BOLD;
  if (italic * 2 > n) flags |= LINE_ITALIC;
  if (mono * 2 > n) flags |= LINE_MONO;
  if (fabsf(line->dir.y) > 0.5f) {
    flags |= LINE_ROTATED;
  } else {
    /* a clearly smaller glyph sitting above the baseline */
    for (fz_stext_char *c = line->first_char; c; c = c->next)
      if (c->c != ' ' && c->size < 0.8f * size && base_y - c->origin.y > 0.15f * size) {
        flags |= LINE_SUPER;
        break;
      }
  }
  doc_page_add_line(pg, sb_take(&text), roundf(size * 10) / 10, flags, line->bbox.x0,
                    line->bbox.y0, line->bbox.x1, line->bbox.y1);
}

static void extract_page(fz_context *ctx, fz_document *doc, int i, struct doc_page *pg,
                         int keep_lines) {
  fz_stext_page *sp = NULL;
  fz_stext_options opts;
  memset(&opts, 0, sizeof opts);
  fz_var(sp);
  pg->no = i + 1;
  /* one unreadable page should not cost the rest of the file */
  fz_try(ctx) {
    sp = fz_new_stext_page_from_page_number(ctx, doc, i, &opts);
    pg->w = sp->mediabox.x1 - sp->mediabox.x0;
    pg->h = sp->mediabox.y1 - sp->mediabox.y0;
    for (fz_stext_block *b = sp->first_block; b; b = b->next) {
      if (b->type != FZ_STEXT_BLOCK_TEXT) continue;
      int first = 1;
      for (fz_stext_line *l = b->u.t.first_line; l; l = l->next) {
        int before = pg->nlines;
        add_line(ctx, pg, l, first);
        if (pg->nlines > before) first = 0;
      }
    }
  }
  fz_always(ctx)
    fz_drop_stext_page(ctx, sp);
  fz_catch(ctx)
    fz_ignore_error(ctx);
  doc_page_finish(pg, keep_lines);
}

void doc_mupdf_extract(const char *path, const struct doc_opts *o, struct doc_info *out) {
  static const char *const keys[DOC_META_N] = {
    FZ_META_INFO_TITLE,    FZ_META_INFO_AUTHOR,  FZ_META_INFO_SUBJECT,
    FZ_META_INFO_KEYWORDS, FZ_META_INFO_CREATOR, FZ_META_INFO_PRODUCER,
  };
  fz_context *ctx = fz_new_context(NULL, NULL, 32 << 20);
  if (!ctx) {
    out->error = xstrdup("mupdf: cannot create context");
    return;
  }
  fz_set_warning_callback(ctx, quiet, NULL);
  fz_set_error_callback(ctx, quiet, NULL);

  fz_document *doc = NULL;
  fz_var(doc);
  fz_try(ctx) {
    fz_register_document_handlers(ctx);
    doc = fz_open_document(ctx, path);
    if (fz_needs_password(ctx, doc) && !fz_authenticate_password(ctx, doc, ""))
      fz_throw(ctx, FZ_ERROR_GENERIC, "password protected");
    if (fz_is_document_reflowable(ctx, doc))
      fz_layout_document(ctx, doc, 595, 842, 11); /* A4-ish pages for EPUB and co. */
    out->npages = fz_count_pages(ctx, doc);
    for (int k = 0; k < DOC_META_N; k++) out->meta[k] = lookup(ctx, doc, keys[k]);

    int n = out->npages < o->pages ? out->npages : o->pages;
    if (n < 0) n = 0;
    out->pages = xcalloc((size_t)n, sizeof *out->pages);
    int from = o->tail ? out->npages - n : 0;
    for (int i = 0; i < n; i++) {
      extract_page(ctx, doc, from + i, &out->pages[i], i < o->layout_pages);
      out->n = i + 1;
    }
  }
  fz_always(ctx)
    fz_drop_document(ctx, doc);
  fz_catch(ctx) {
    out->error = xstrdup(fz_caught_message(ctx));
    fz_ignore_error(ctx);
  }
  fz_drop_context(ctx);
}
