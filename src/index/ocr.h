#ifndef LULIBRE_OCR_H
#define LULIBRE_OCR_H

/* OCR, as a step of reading a file (design 37): tesseract reads a page
 * rendered to an image, and its words become lines as extraction's do,
 * with boxes in points, a size (the line's height) and LINE_BLOCK on the
 * first line of each paragraph. Safe on a worker thread. */

#include "doc/doc.h"

/* tesseract's path on $PATH, malloc'd, or NULL. */
char *ocr_find(void);

/* Reads page (0-based) of the file at path into *out (its no, w and h are
 * the caller's: the page as extraction measured it, in points). Returns 0,
 * or -1 with *err set (malloc'd). */
int ocr_page(const char *tesseract, const char *path, int page, const char *lang, struct doc_page *out,
             char **err);

#endif
