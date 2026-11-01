/* lulibre offline: what lulibre's unit runs before calibre's content
 * server starts (units.lua, server_hook). calibre's records are read
 * again, and the changes that wait for nothing to hold the library are
 * made, before the server takes it. The rest of 0.2's offline (listing and
 * cancelling what waits) is not here yet. */
#include <stdio.h>
#include <string.h>

#include "app.h"
#include "library/library.h"

int cmd_offline(struct app *app, int argc, char **argv) {
  if (argc > 1 && (!strcmp(argv[1], "-h") || !strcmp(argv[1], "--help"))) {
    puts("usage: lulibre offline\n\nRead calibre's records again and make the changes waiting for nothing to hold\n"
         "the library, then end: what lulibre's systemd unit runs before calibre's content\nserver starts.");
    return 0;
  }
  app_open_db(app); /* reads calibre's records */
  library_resume(app->library);
  uv_run(app->loop, UV_RUN_DEFAULT); /* until what waits is made */
  return 0;
}
