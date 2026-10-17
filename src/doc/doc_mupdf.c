/* PDF, EPUB, FB2, MOBI and friends through MuPDF.
 *
 * Each call builds its own fz_context, so calls on different threads share
 * nothing and need no locking. */
#include <ctype.h>
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

/* What a font is for, by its name (less the subset prefix "ABCDEF+"). */
enum { FONT_TEXT, FONT_VARIABLE, FONT_SYMBOL, FONT_BLACKBOARD, FONT_FRAKTUR, FONT_SCRIPT };

static int font_kind(fz_context *ctx, fz_font *font) {
  static const struct { const char *part; int kind; } parts[] = {
    {"msbm", FONT_BLACKBOARD}, {"bbold", FONT_BLACKBOARD}, {"bbm", FONT_BLACKBOARD},
    {"dsrom", FONT_BLACKBOARD}, {"doublestruck", FONT_BLACKBOARD}, {"blackboard", FONT_BLACKBOARD},
    {"eufm", FONT_FRAKTUR}, {"eufb", FONT_FRAKTUR}, {"fraktur", FONT_FRAKTUR},
    {"rsfs", FONT_SCRIPT}, {"eusm", FONT_SCRIPT}, {"eusb", FONT_SCRIPT},
    {"cmmi", FONT_VARIABLE}, {"mathitalic", FONT_VARIABLE}, {"math-italic", FONT_VARIABLE},
    {"cmsy", FONT_SYMBOL}, {"cmex", FONT_SYMBOL}, {"msam", FONT_SYMBOL}, {"symbol", FONT_SYMBOL},
    {"math", FONT_SYMBOL}, {"stix", FONT_SYMBOL},
  };
  if (!font) return FONT_TEXT;
  const char *name = fz_font_name(ctx, font), *plus = strchr(name, '+');
  if (plus) name = plus + 1;
  char low[64];
  size_t n = 0;
  for (; name[n] && n < sizeof low - 1; n++) low[n] = (char)tolower((unsigned char)name[n]);
  low[n] = '\0';
  for (size_t i = 0; i < ARRAY_LEN(parts); i++)
    if (strstr(low, parts[i].part)) return parts[i].kind;
  return FONT_TEXT;
}

struct glyph {
  int c, kind, bold, script; /* script: 1 raised, -1 lowered, 0 on the line */
  fz_font *font;
};

static int same_word(const struct glyph *a, const struct glyph *b) {
  return a->c < 128 && isalpha(a->c) && a->script == b->script;
}

static int is_operand(int c) {
  return (c >= '0' && c <= '9') || (c < 128 && strchr("+-=()[],.", c)) || c == 0x2212;
}

/* The line with its mathematics as TeX, or NULL when it has none. A word is
 * mathematics when a character of it is set in a mathematical font or is
 * raised or lowered in smaller type (X³, GLₙ); so is a figure or a sign in
 * another font than the line's own beside one ("X³ − 5"). Within it, a
 * capital standing alone in bold (Conrad's ℤ) or in a blackboard font is
 * marked as such: what it stands for is for lulibre.notation to say. */
static char *math_of(fz_context *ctx, fz_stext_line *line, float size, float base_y) {
  int n = 0;
  for (fz_stext_char *c = line->first_char; c; c = c->next) n++;
  if (n == 0) return NULL;
  struct glyph *g = xcalloc((size_t)n, sizeof *g);
  int k = 0, any = 0;
  for (fz_stext_char *c = line->first_char; c; c = c->next, k++) {
    g[k].c = c->c < 0x20 ? ' ' : c->c;
    if (g[k].c == ' ' || g[k].c == 0xa0) { g[k].c = ' '; continue; }
    g[k].font = c->font;
    g[k].kind = font_kind(ctx, c->font);
    g[k].bold = (c->flags & FZ_STEXT_BOLD) || (c->font && fz_font_is_bold(ctx, c->font));
    if (c->size < 0.85f * size) {
      float up = base_y - c->origin.y;
      g[k].script = up > 0.1f * size ? 1 : up < -0.08f * size ? -1 : 0;
    }
    if (g[k].kind != FONT_TEXT || g[k].script) any = 1;
  }
  if (!any) {
    free(g);
    return NULL;
  }
  /* the line's own font: the one most of its characters are in */
  fz_font *own = NULL;
  for (int i = 0, best = 0; i < n; i++) {
    if (g[i].c == ' ' || g[i].font == own) continue;
    int count = 0;
    for (int j = 0; j < n; j++) count += g[j].font == g[i].font;
    if (count > best) best = count, own = g[i].font;
  }
  /* words: [start, end) runs between spaces; math 2 = surely, 1 = if beside one */
  int nw = 0, (*w)[4] = xcalloc((size_t)n, sizeof *w); /* start, end, math, end with punctuation */
  int set_apart = 0;
  for (int i = 0; i < n;) {
    if (g[i].c == ' ') { i++; continue; }
    int s = i, math = 0, operand = 1, letters = 0, raised = 0;
    for (; i < n && g[i].c != ' '; i++) {
      /* a sign run into a word with no space between them ("⊗AND") */
      if (i > s && g[i - 1].kind == FONT_SYMBOL && !(g[i - 1].c < 128 && isalpha(g[i - 1].c)) &&
          g[i].kind == FONT_TEXT && !g[i].script && i + 1 < n && g[i].c < 128 && isalpha(g[i].c) &&
          g[i + 1].c < 128 && isalpha(g[i + 1].c))
        break;
      letters += g[i].c < 128 && isalpha(g[i].c);
      raised += g[i].script != 0;
    }
    /* a whole word in smaller type, higher or lower, is set apart (a date
     * over the title), not a script; and so are the words after it */
    int apart = raised == i - s && (letters >= 2 || set_apart);
    set_apart = apart;
    if (apart)
      for (int j = s; j < i; j++) g[j].script = 0;
    for (int j = s; j < i; j++) {
      if (g[j].kind != FONT_TEXT || g[j].script) math = 2;
      if (!is_operand(g[j].c) || g[j].font == own) operand = 0;
    }
    /* the comma or full stop after a formula belongs to the sentence, and so
     * does a word it is hyphened to ("p-adic", "Sₙ-modules") */
    int e = i;
    for (int j = s + 1; math && j < i - 2; j++)
      if (g[j].c == '-') {
        int word = 1;
        for (int k = j + 1; k < i; k++)
          if (g[k].script || g[k].kind != FONT_TEXT || !(g[k].c < 128 && isalpha(g[k].c))) word = 0;
        if (word) e = j;
      }
    while (math && e == i && e - 1 > s && !g[e - 1].script && g[e - 1].c < 128 && strchr(",.;:", g[e - 1].c)) e--;
    w[nw][0] = s, w[nw][1] = e, w[nw][2] = math ? math : operand, w[nw][3] = i;
    nw++;
  }
  for (int pass = 0; pass < 2; pass++)
    for (int i = 0; i < nw; i++)
      if (w[i][2] == 1 && ((i > 0 && w[i - 1][2] == 2) || (i + 1 < nw && w[i + 1][2] == 2))) w[i][2] = 2;
  any = 0;
  for (int i = 0; i < nw; i++) any |= w[i][2] == 2;
  if (!any) {
    free(w);
    free(g);
    return NULL;
  }

  sbuf out = SBUF_INIT;
  int in_math = 0;
  for (int i = 0; i < nw; i++) {
    int math = w[i][2] == 2;
    if (i) sb_puts(&out, in_math && !math ? "$ " : " ");
    if (math && !in_math) sb_putc(&out, '$');
    int script = 0;
    for (int j = w[i][0]; j < w[i][1]; j++) {
      int c = g[j].c;
      char utf[8];
      utf[fz_runetochar(utf, c)] = '\0';
      if (!math) {
        if (c == '$' || c == '\\') sb_printf(&out, "\\%c", c);
        else sb_puts(&out, utf);
        continue;
      }
      if (g[j].script != script) {
        if (script) sb_putc(&out, '}');
        if (g[j].script) sb_puts(&out, g[j].script > 0 ? "^{" : "_{");
        script = g[j].script;
      }
      int letter = c < 128 && isalpha(c), cap = c < 128 && isupper(c);
      /* (a letter in a script is not a neighbour: the Q of Qₚ stands alone) */
      int alone = (j == w[i][0] || !same_word(&g[j - 1], &g[j])) &&
                  (j + 1 == w[i][1] || !same_word(&g[j + 1], &g[j]));
      if (letter && g[j].kind == FONT_BLACKBOARD) sb_printf(&out, "\\mathbb{%c}", c);
      else if (letter && g[j].kind == FONT_FRAKTUR) sb_printf(&out, "\\mathfrak{%c}", c);
      else if (cap && (g[j].kind == FONT_SCRIPT || g[j].kind == FONT_SYMBOL)) sb_printf(&out, "\\mathcal{%c}", c);
      else if (cap && alone && g[j].bold && g[j].kind == FONT_TEXT) sb_printf(&out, "\\mathbf{%c}", c);
      else if (c < 128 && strchr("{}$_^\\", c)) sb_printf(&out, "\\%c", c);
      else sb_puts(&out, utf);
    }
    if (script) sb_putc(&out, '}');
    in_math = math;
    if (math && w[i][1] < w[i][3]) {
      sb_putc(&out, '$');
      for (int j = w[i][1]; j < w[i][3]; j++) sb_putc(&out, (char)g[j].c);
      in_math = 0;
    }
  }
  if (in_math) sb_putc(&out, '$');
  free(w);
  free(g);
  return sb_take(&out);
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
  struct doc_line *l = doc_page_add_line(pg, sb_take(&text), roundf(size * 10) / 10, flags,
                                         line->bbox.x0, line->bbox.y0, line->bbox.x1, line->bbox.y1);
  if (l && !(flags & LINE_ROTATED)) l->math = math_of(ctx, line, size, base_y);
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
