/* calibre's own settings, as far as lulibre reads them: the library calibre
 * opened last (library_path in global.py.json, in calibre's configuration
 * folder: $CALIBRE_CONFIG_DIRECTORY, else calibre/ under $XDG_CONFIG_HOME
 * or ~/.config, as calibre finds it). Parsed with mupdf's JSON reader. */
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <mupdf/fitz.h>

#include "core/util.h"
#include "library/library.h"

char *calibre_library_path(void) {
  const char *dir = getenv("CALIBRE_CONFIG_DIRECTORY"), *xdg = getenv("XDG_CONFIG_HOME");
  char *home = path_expand("~/.config");
  char *path = dir && *dir ? xasprintf("%s/global.py.json", dir)
               : xasprintf("%s/calibre/global.py.json", xdg && *xdg ? xdg : home);
  free(home);
  char *text = file_read(path, NULL), *found = NULL;
  free(path);
  if (!text) return NULL;
  fz_context *ctx = fz_new_context(NULL, NULL, 8 << 20);
  fz_pool *pool = NULL;
  fz_var(pool);
  if (ctx) {
    fz_try(ctx) {
      pool = fz_new_pool(ctx);
      fz_json *lib = fz_json_object_get(ctx, fz_parse_json(ctx, pool, text), "library_path");
      if (lib && fz_json_is_string(ctx, lib)) found = xstrdup(fz_json_to_string(ctx, lib));
    }
    fz_always(ctx) fz_drop_pool(ctx, pool);
    fz_catch(ctx) fz_ignore_error(ctx);
    fz_drop_context(ctx);
  }
  free(text);
  if (found) { /* only a library that is there */
    char *db = xasprintf("%s/metadata.db", found);
    int there = access(db, R_OK) == 0;
    free(db);
    if (!there) {
      free(found);
      found = NULL;
    }
  }
  return found;
}
