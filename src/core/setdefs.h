#ifndef LULIBRE_SETDEFS_H
#define LULIBRE_SETDEFS_H

/* lulibre's settings: the definitions, and an index per setting in the
 * same order, for C to read a value without looking it up by name. The
 * names, defaults and help are all in setdefs.c. */

#include "core/settings.h"

enum setting_id {
  S_LIBRARY,
  S_INDEX,
  S_JOURNAL_DB,
  S_CUSTOM_DB,
  S_WIT_DB,
  S_NET_DB,
  S_CONFIG_DIR,
  S_STATE,
  S_PERSISTENT,
  S_LOG_FILE,
  S_CRASH,
  S_JOBS,
  S_PAGES,
  S_OCR,
  S_OCR_PAGES,
  S_OCR_LANG,
  S_AUTO_INDEX,
  S_MOUSE,
  S_LEADER,
  S_BLITTER,
  S_PREVIEW,
  S_SYNC_DIR,
  S_MOD_TREE,
  S_RANK_COVERAGE,
  S_RANK_AGREEMENT,
  S_RANK_TRACK,
  S_TRACK_AFTER,
  S_SIMILAR_NEAR,
  S_SIMILAR_SAME,
  S_EMBED,
  S_WRITE_JOBS,
  S_CONTACT_EMAIL,
  S_SERVER,
  S_USER,
  S_PASSWORD_FILE,
  S_COUNT
};

extern const struct setting_def setting_defs[S_COUNT];

#endif
