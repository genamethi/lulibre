#include "cmd/cmd.h"

#include "core/util.h"

void cmd_put_cell(FILE *f, sqlite3_stmt *st, int col) {
  const unsigned char *s = sqlite3_column_text(st, col);
  if (!s) return;
  for (; *s; s++) fputc(*s == '\t' || *s == '\n' || *s == '\r' ? ' ' : *s, f);
}

char *cmd_join(int argc, char **argv, int from) {
  sbuf b = SBUF_INIT;
  for (int i = from; i < argc; i++) {
    if (b.len) sb_putc(&b, ' ');
    sb_puts(&b, argv[i]);
  }
  return sb_take(&b);
}
