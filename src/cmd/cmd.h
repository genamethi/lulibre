#ifndef LULIBRE_CMD_H
#define LULIBRE_CMD_H

#include <stdio.h>

#include "db/db.h"

/* Print a column as one TSV cell: NULL is empty, tabs and newlines become
 * spaces so one row stays one line. */
void cmd_put_cell(FILE *f, sqlite3_stmt *st, int col);

/* Join argv[from..argc) with spaces; malloc'd. */
char *cmd_join(int argc, char **argv, int from);

#endif
