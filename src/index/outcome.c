#include "index/outcome.h"

const char *const outcome_names[OUTCOMES] = {
  [OUT_PENDING] = "not read yet",
  [OUT_READ] = "read",
  [OUT_READ_OCR] = "read by OCR",
  [OUT_OCR_NO_HELP] = "OCR did not help",
  [OUT_OCR_UNAVAILABLE] = "no usable text, and no OCR",
  [OUT_UNREADABLE] = "could not be read",
  [OUT_MISSING] = "missing",
  [OUT_NO_TEXT] = "marked as having no text",
};

const char *const outcome_words[OUTCOMES] = {
  [OUT_PENDING] = "unread",       [OUT_READ] = "read",       [OUT_READ_OCR] = "ocr",
  [OUT_OCR_NO_HELP] = "ocrfailed", [OUT_OCR_UNAVAILABLE] = "noocr", [OUT_UNREADABLE] = "unreadable",
  [OUT_MISSING] = "missing",      [OUT_NO_TEXT] = "notext",
};
