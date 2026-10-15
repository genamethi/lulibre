#include "doc/doc.h"

#include <ctype.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/types.h>

#include "core/util.h"

/* Plain text and Markdown: no layout, so cut the head of the file into
 * pseudo-pages of 60 lines. */
static void text_extract(FILE *f, const struct doc_opts *o, struct doc_info *out) {
  enum { PAGE_LINES = 60 };
  char *line = NULL;
  size_t cap = 0;
  ssize_t len;
  int n = 0;
  out->pages = xcalloc((size_t)(o->pages > 0 ? o->pages : 1), sizeof *out->pages);
  while (out->n <= o->pages && (len = getline(&line, &cap, f)) >= 0) {
    if (n % PAGE_LINES == 0) {
      if (out->n) doc_page_finish(&out->pages[out->n - 1], out->n <= o->layout_pages);
      if (out->n == o->pages) break;
      out->pages[out->n].no = out->n + 1;
      out->n++;
    }
    for (ssize_t i = 0; i < len; i++)
      if ((unsigned char)line[i] < 0x20) line[i] = ' ';
    doc_page_add_line(&out->pages[out->n - 1], xstrdup(line), 0, 0, 0, 0, 0, 0);
    n++;
  }
  if (out->n && !out->pages[out->n - 1].text)
    doc_page_finish(&out->pages[out->n - 1], out->n <= o->layout_pages);
  free(line);
  out->npages = out->n; /* lower bound: only the head of the file is read */
}

void doc_extract(const char *path, const char *format, const struct doc_opts *o,
                 struct doc_info *out) {
  memset(out, 0, sizeof *out);

  /* Trust the content over the extension: libraries collect misnamed files. */
  char magic[8] = {0};
  FILE *f = fopen(path, "rb");
  if (!f) {
    out->error = xasprintf("cannot open: %s", strerror(errno));
    return;
  }
  size_t got = fread(magic, 1, sizeof magic, f);
  if (got == 0) {
    fclose(f);
    out->error = xstrdup("empty file");
    return;
  }
  int is_djvu = got >= 8 && memcmp(magic, "AT&TFORM", 8) == 0;
  int is_pdf = got >= 4 && memcmp(magic, "%PDF", 4) == 0;
  int is_text = !is_djvu && !is_pdf && (!strcasecmp(format, "txt") || !strcasecmp(format, "md"));
  if (is_text) {
    rewind(f);
    text_extract(f, o, out);
  }
  fclose(f);

  if (is_djvu) doc_djvu_extract(path, o, out);
  else if (!is_text) doc_mupdf_extract(path, o, out); /* pdf, epub, fb2, mobi, xps, cbz */
  if (out->error) return;

  sbuf all = SBUF_INIT;
  for (int i = 0; i < out->n; i++) {
    sb_puts(&all, out->pages[i].text ? out->pages[i].text : "");
    sb_putc(&all, '\n');
  }
  out->quality = doc_text_quality(all.s ? all.s : "", &out->nchars);
  sb_free(&all);
}

void doc_info_free(struct doc_info *d) {
  for (int i = 0; i < DOC_META_N; i++) free(d->meta[i]);
  for (int i = 0; i < d->n; i++) {
    struct doc_page *pg = &d->pages[i];
    for (int j = 0; j < pg->nlines; j++) free(pg->lines[j].text);
    free(pg->lines);
    free(pg->text);
  }
  free(d->pages);
  free(d->error);
  memset(d, 0, sizeof *d);
}

void doc_page_add_line(struct doc_page *pg, char *text, float size, unsigned flags, float x0,
                       float y0, float x1, float y1) {
  /* trim, and drop lines that are only whitespace */
  size_t n = strlen(text);
  while (n && isspace((unsigned char)text[n - 1])) text[--n] = '\0';
  char *s = text;
  while (*s && isspace((unsigned char)*s)) s++;
  if (!*s) {
    free(text);
    return;
  }
  if (s != text) memmove(text, s, strlen(s) + 1);
  if (pg->nlines == pg->cap) {
    pg->cap = pg->cap ? pg->cap * 2 : 32;
    pg->lines = xrealloc(pg->lines, (size_t)pg->cap * sizeof *pg->lines);
  }
  pg->lines[pg->nlines++] = (struct doc_line){text, size, flags, x0, y0, x1, y1};
}

void doc_page_finish(struct doc_page *pg, int keep_lines) {
  sbuf b = SBUF_INIT;
  for (int i = 0; i < pg->nlines; i++) {
    if (i && (pg->lines[i].flags & LINE_BLOCK)) sb_putc(&b, '\n');
    sb_puts(&b, pg->lines[i].text);
    sb_putc(&b, '\n');
  }
  pg->text = sb_take(&b);
  if (!keep_lines) {
    for (int i = 0; i < pg->nlines; i++) free(pg->lines[i].text);
    free(pg->lines);
    pg->lines = NULL;
    pg->nlines = pg->cap = 0;
  }
}

/* A character that is no character: U+FFFD (what a font with no map to
 * Unicode comes out as), the private use area (a font's own glyph numbers),
 * C0 controls. n: its length in bytes, or 0 when p is something else. */
static int unreadable(const unsigned char *p, int *n) {
  if (p[0] == 0xef && p[1] == 0xbf && p[2] == 0xbd) return *n = 3, 1;
  if (p[0] == 0xee && p[1] >= 0x80 && p[2] >= 0x80) return *n = 3, 1; /* U+E000..U+EFFF */
  if (p[0] == 0xef && p[1] >= 0x80 && p[1] <= 0xa3 && p[2] >= 0x80) return *n = 3, 1; /* ..U+F8FF */
  if (p[0] == 0xf3 && p[1] >= 0xb0) return *n = 4, 1; /* planes 15 and 16 */
  if (p[0] < 0x20 && p[0] != '\n' && p[0] != '\t' && p[0] != '\r' && p[0] != '\f') return *n = 1, 1;
  return *n = 0, 0;
}

/* A scanned book's stale OCR layer is mostly one- and two-letter fragments;
 * real prose is mostly longer words. Text a font could not be read from is
 * full of unreadable characters, which count against it: each per cent of
 * them takes a tenth off. Used to decide when OCR is worth it. */
double doc_text_quality(const char *s, long *nchars) {
  long tokens = 0, good = 0, chars = 0, bad = 0;
  const unsigned char *p = (const unsigned char *)s;
  int n;
  int run = 0; /* unreadable characters in a row: a run of eight or more (dots
                 leading to a page number, a rule) counts as one */
  while (*p) {
    if (unreadable(p, &n)) {
      if (++run < 8) bad++;
      else if (run == 8) bad -= 6;
      chars++;
      p += n;
      continue;
    }
    run = 0;
    if (*p >= 0x80 || isalpha(*p)) {
      long len = 0;
      int spoilt = 0;
      while (*p && (*p >= 0x80 || isalpha(*p))) {
        if (unreadable(p, &n)) {
          spoilt = 1;
          bad++;
          len++;
          p += n;
          continue;
        }
        if ((*p & 0xc0) != 0x80) len++; /* count code points, not bytes */
        p++;
      }
      tokens++;
      chars += len;
      if (len >= 3 && !spoilt) good++;
    } else {
      if (isdigit(*p)) chars++;
      p++;
    }
  }
  if (nchars) *nchars = chars;
  double q = tokens ? (double)good / (double)tokens : 0.0;
  if (chars > 0 && bad > 0) {
    double keep = 1.0 - 10.0 * (double)bad / (double)chars;
    q *= keep > 0 ? keep : 0;
  }
  return q;
}
