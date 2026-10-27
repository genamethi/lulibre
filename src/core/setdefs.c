#include "core/setdefs.h"

#include <stddef.h>

const struct setting_def setting_defs[S_COUNT] = {
  [S_LIBRARY] = {"library", SETTING_PATH, 0, "", NULL, "calibre library directory"},
  [S_INDEX] = {"index", SETTING_PATH, 0, "", NULL, "index database file (default: under the XDG data dir)"},
  [S_CONFIG_DIR] = {"config_dir", SETTING_PATH, SETTING_CLI_ONLY, "", NULL,
                    "where init.lua and lua/ are looked for (default: ~/.config/lulibre); also -C DIR or "
                    "$LULIBRE_CONFIG_DIR"},
  [S_PERSISTENT] = {"persistent", SETTING_BOOL, SETTING_PERSIST, "false", NULL,
                    "keep the settings changed during a run, in ~/.local/state/lulibre/settings, and start "
                    "from them next time"},
  [S_LOG_FILE] = {"log_file", SETTING_PATH, 0, "", NULL,
                  "also append the log to this file (the console, `, shows it either way)"},
  [S_JOBS] = {"jobs", SETTING_INT, 0, "0", NULL, "worker threads (0 = one per core)"},
  [S_PAGES] = {"pages", SETTING_INT, 0, "6", NULL, "first N pages of each file to index as text"},
  [S_OCR] = {"ocr", SETTING_STR, 0, "never", "never|auto|always",
             "read page images with tesseract after indexing: never, auto (files with no text), always"},
  [S_OCR_PAGES] = {"ocr_pages", SETTING_INT, 0, "3", NULL, "pages per file the OCR pass reads"},
  [S_OCR_LANG] = {"ocr_lang", SETTING_STR, 0, "eng", NULL, "tesseract language(s), e.g. eng or eng+fra"},
  [S_AUTO_INDEX] = {"auto_index", SETTING_STR, 0, "auto", "auto|ask|never",
                    "index new or changed files when the interface starts (ask: only say how many are waiting)"},
  [S_MOUSE] = {"mouse", SETTING_BOOL, 0, "true", NULL,
               "true: click selects, the wheel scrolls (Shift selects text); false: off"},
  [S_LEADER] = {"leader", SETTING_STR, 0, "\\", NULL,
                "the key <Leader> stands for in key bindings, in key-map notation: \\, <Space>, ,"},
  [S_BLITTER] = {"blitter", SETTING_STR, 0, "auto", "auto|pixel|sextant|quadrant|half", "how page images are drawn"},
  [S_PREVIEW] = {"preview", SETTING_STR, 0, "text", "text|image", "what the preview shows first; P switches"},
  [S_SYNC_DIR] = {"sync_dir", SETTING_PATH, 0, "", NULL,
                  "a folder of files waiting to be added to the library; gS shows it"},
  [S_MOD_TREE] = {"mod_tree", SETTING_PATH, 0, "", NULL,
                  "a prefix of Lua modules: its share/lua/<version> and lib/lua/<version> are searched after "
                  "lulibre's own. Ignored in a pixi environment, where pixi's environment holds the modules"},
  [S_SIMILAR_NEAR] = {"similar_near", SETTING_NUM, 0, "0.7", NULL,
                      "two values are near when each is at least this much found in the other (0 to 1)"},
  [S_SIMILAR_SAME] = {"similar_same", SETTING_NUM, 0, "0.95", NULL,
                      "a value is all found in another at this much or more (0 to 1): both ways, they are equal"},
  [S_SERVER] = {"server", SETTING_STR, 0, "", NULL,
                "calibre content server URL; changes go through it (http://127.0.0.1:8080)"},
  [S_USER] = {"user", SETTING_STR, 0, "", NULL, "content server user"},
  [S_PASSWORD_FILE] = {"password_file", SETTING_PATH, 0, "", NULL, "file holding the content server password"},
};
