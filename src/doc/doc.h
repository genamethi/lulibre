#ifndef LULIBRE_DOC_H
#define LULIBRE_DOC_H

/* Text extraction from ebook files. Everything here is safe to call from a
 * worker thread and touches nothing but the file it is given. Coordinates are
 * in points with the origin at the top left, whatever the format. */

enum {
  LINE_BOLD = 1,
  LINE_ITALIC = 2,
  LINE_SUPER = 4,   /* carries a superscript, e.g. an author footnote mark */
  LINE_ROTATED = 8, /* not horizontal, e.g. the arXiv margin stamp */
  LINE_MONO = 16,
  LINE_BLOCK = 32,  /* first line of a block (paragraph) */
};

struct doc_line {
  char *text;
  float size; /* dominant font size; for DjVu, the line height */
  unsigned flags;
  float x0, y0, x1, y1;
  /* the line with its mathematics marked up as TeX, from the fonts and the
   * size and height of each character ("THE SPLITTING FIELD OF $X^{3} − 5$
   * OVER Q"); NULL when it has none, or the format cannot say */
  char *math;
};

struct doc_page {
  int no; /* 1-based */
  char *text;
  float w, h;
  struct doc_line *lines;
  int nlines, cap;
};

enum { DOC_TITLE, DOC_AUTHOR, DOC_SUBJECT, DOC_KEYWORDS, DOC_CREATOR, DOC_PRODUCER, DOC_META_N };

struct doc_info {
  int npages;
  char *meta[DOC_META_N]; /* embedded metadata; NULL when absent */
  struct doc_page *pages;
  int n;
  long nchars;    /* letters and digits across the extracted pages */
  double quality; /* share of word tokens that look like words, 0..1 */
  double garbled; /* share of characters that are no characters (U+FFFD, private use), 0..1 */
  char *error;    /* set when the file could not be read at all */
};

struct doc_opts {
  int pages;        /* extract the first N pages */
  int layout_pages; /* keep tagged lines for the first M of them */
  int tail;         /* the last N pages instead of the first: where a bibliography is */
};

/* Fills *out (zeroed first). Check out->error. */
void doc_extract(const char *path, const char *format, const struct doc_opts *o,
                 struct doc_info *out);
void doc_info_free(struct doc_info *d);

/* One page rendered to pixels, `width` pixels wide. page is 0-based. aspect
 * is the height/width of one output pixel: 1 for real pixels, more when the
 * "pixels" are the taller-than-wide parts of a terminal cell, in which case
 * the image is squashed vertically to compensate. Check out->error. */
struct doc_image {
  unsigned char *rgba;
  int w, h;
  char *error;
};
void doc_render(const char *path, int page, int width, float aspect, struct doc_image *out);
void doc_image_free(struct doc_image *img);

/* helpers shared by the format backends */
/* takes ownership of text; returns the line, or NULL when it was only whitespace */
struct doc_line *doc_page_add_line(struct doc_page *pg, char *text, float size, unsigned flags,
                                   float x0, float y0, float x1, float y1);
void doc_page_finish(struct doc_page *pg, int keep_lines);
double doc_text_quality(const char *s, long *nchars, double *garbled);

/* A PDF's XMP packet and Info dictionary ("Key: value" lines), or an EPUB's
 * package document, as text (malloc'd; "" when there is none). NULL and
 * *err (malloc'd) when the file cannot be opened. */
char *doc_metadata(const char *path, char **err);
void doc_mupdf_extract(const char *path, const struct doc_opts *o, struct doc_info *out);
void doc_djvu_extract(const char *path, const struct doc_opts *o, struct doc_info *out);

#endif
