#ifndef LULIBRE_OUTCOME_H
#define LULIBRE_OUTCOME_H

/* What reading a file came to (design 37, 38): one outcome per file, each
 * one a filter. Replaces enum file_status. */

enum file_outcome {
  OUT_PENDING,         /* not read yet */
  OUT_READ,            /* usable text */
  OUT_READ_OCR,        /* the text layer was unusable; OCR's text is usable */
  OUT_OCR_NO_HELP,     /* unusable after OCR */
  OUT_OCR_UNAVAILABLE, /* unusable, and OCR is off or has no reader */
  OUT_UNREADABLE,      /* the file did not open; the error is kept */
  OUT_MISSING,         /* no file at the recorded path */
  OUT_NO_TEXT,         /* marked by the user as having no text: never retried */
};

#endif
