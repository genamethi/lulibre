/* The clipboard: where copied text goes and pasted text comes from.
 *
 * Inside tmux both go through tmux itself (`load-buffer -w`, `show-buffer`):
 * that works with tmux's default settings, where an escape sequence from a
 * program would be ignored or blocked, it reaches the terminal's clipboard
 * too, and what is pasted is whatever was copied last anywhere in tmux.
 * Elsewhere, copying asks the terminal with OSC 52 (which also works through
 * ssh) and pasting gives back what lulibre itself copied last: a terminal
 * will not, as a rule, tell a program what its clipboard holds. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "core/util.h"
#include "tui/tui.h"

static char *last; /* what lulibre last copied */

static int tmux_copy(const char *s, size_t n) {
  FILE *p = popen("tmux load-buffer -w - 2>/dev/null", "w");
  if (!p) return 0;
  int wrote = fwrite(s, 1, n, p) == n;
  return pclose(p) == 0 && wrote;
}

static int osc52_copy(const unsigned char *s, size_t n) {
  static const char b64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  sbuf out = SBUF_INIT;
  sb_puts(&out, "\033]52;c;");
  for (size_t i = 0; i < n; i += 3) {
    unsigned v = (unsigned)s[i] << 16 | (i + 1 < n ? (unsigned)s[i + 1] << 8 : 0) | (i + 2 < n ? s[i + 2] : 0);
    sb_putc(&out, b64[v >> 18 & 63]);
    sb_putc(&out, b64[v >> 12 & 63]);
    sb_putc(&out, i + 1 < n ? b64[v >> 6 & 63] : '=');
    sb_putc(&out, i + 2 < n ? b64[v & 63] : '=');
  }
  sb_puts(&out, "\a");
  /* straight to the terminal device, as one write, so it cannot interleave
   * with a frame */
  FILE *tty = fopen("/dev/tty", "w");
  int ok = 0;
  if (tty) {
    ok = fwrite(out.s, 1, out.len, tty) == out.len;
    fclose(tty);
  }
  sb_free(&out);
  return ok;
}

int clip_copy(const char *s, size_t n) {
  free(last);
  last = xstrndup(s, n);
  if (getenv("TMUX") && tmux_copy(s, n)) return 1;
  return osc52_copy((const unsigned char *)s, n);
}

char *clip_paste(void) {
  if (getenv("TMUX")) {
    FILE *p = popen("tmux show-buffer 2>/dev/null", "r");
    if (p) {
      sbuf out = SBUF_INIT;
      char buf[4096];
      size_t n;
      while ((n = fread(buf, 1, sizeof buf, p)) > 0) sb_putn(&out, buf, n);
      if (pclose(p) == 0 && out.len) return sb_take(&out);
      sb_free(&out);
    }
  }
  return last ? xstrdup(last) : NULL;
}

void clip_free(void) {
  free(last);
  last = NULL;
}
