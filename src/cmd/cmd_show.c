#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "app.h"
#include "cmd/cmd.h"
#include "core/util.h"
#include "doc/doc.h"

static const char help[] =
  "usage: lulibre show [options] ID\n\n"
  "Show one book: calibre metadata, its files, and the indexed text.\n\n"
  "  -p N     page to print (default 1; 0 prints no text)\n"
  "  -l       print the page as tagged lines instead of plain text\n"
  "           size  flags  text      flags: B bold  I italic  ^ superscript\n"
  "                                         R rotated  M monospace  | block start\n";

static void field(const char *label, sqlite3_stmt *st, int col) {
  if (sqlite3_column_type(st, col) == SQLITE_NULL) return;
  const char *s = (const char *)sqlite3_column_text(st, col);
  if (!s[0]) return;
  printf("%-10s ", label);
  cmd_put_cell(stdout, st, col);
  fputc('\n', stdout);
}

static void flags_str(unsigned f, char out[8]) {
  int n = 0;
  if (f & LINE_BLOCK) out[n++] = '|';
  if (f & LINE_BOLD) out[n++] = 'B';
  if (f & LINE_ITALIC) out[n++] = 'I';
  if (f & LINE_SUPER) out[n++] = '^';
  if (f & LINE_ROTATED) out[n++] = 'R';
  if (f & LINE_MONO) out[n++] = 'M';
  out[n] = '\0';
}

int cmd_show(struct app *app, int argc, char **argv) {
  int page = 1, lines = 0;
  long id = 0;
  for (int i = 1; i < argc; i++) {
    const char *a = argv[i];
    if (!strcmp(a, "-h") || !strcmp(a, "--help")) { fputs(help, stdout); return 0; }
    else if (!strcmp(a, "-p") && i + 1 < argc) page = atoi(argv[++i]);
    else if (!strcmp(a, "-l")) lines = 1;
    else id = atol(a);
  }
  if (id <= 0) { fputs(help, stderr); return 2; }

  app_open_db(app);
  struct db *db = &app->db;
  sqlite3_stmt *st;
  char *err = NULL;

  if (db_prepare(db,
                 "SELECT title, authors, tags, series, publisher, pubdate, languages, idents,"
                 " added, modified FROM books WHERE id = ?",
                 &st, &err))
    die("%s", err);
  sqlite3_bind_int64(st, 1, id);
  if (sqlite3_step(st) != SQLITE_ROW) {
    sqlite3_finalize(st);
    warnf("no book with id %ld", id);
    return 1;
  }
  static const char *const labels[] = {"title", "authors", "tags", "series", "publisher",
                                       "pubdate", "lang", "idents", "added", "modified"};
  for (int c = 0; c < (int)ARRAY_LEN(labels); c++) field(labels[c], st, c);
  sqlite3_finalize(st);

  if (db_prepare(db,
                 "SELECT id, format, path, status, error, npages, nchars, round(quality, 2),"
                 " emb_title, emb_author, emb_subject, emb_keywords, emb_creator, emb_producer"
                 " FROM files WHERE book = ? ORDER BY id",
                 &st, &err))
    die("%s", err);
  sqlite3_bind_int64(st, 1, id);
  sqlite3_int64 first_file = 0;
  static const char *const status[] = {"not indexed", "indexed", "failed", "missing"};
  while (sqlite3_step(st) == SQLITE_ROW) {
    if (!first_file) first_file = sqlite3_column_int64(st, 0);
    int s = sqlite3_column_int(st, 3);
    printf("\n%-10s %s\n", (const char *)sqlite3_column_text(st, 1),
           (const char *)sqlite3_column_text(st, 2));
    printf("%-10s %s", "", status[s >= 0 && s <= 3 ? s : 0]);
    if (s == FILE_OK)
      printf(", %d pages, %lld characters indexed, text quality %s", sqlite3_column_int(st, 5),
             (long long)sqlite3_column_int64(st, 6), (const char *)sqlite3_column_text(st, 7));
    if (s == FILE_ERROR) printf(": %s", (const char *)sqlite3_column_text(st, 4));
    fputc('\n', stdout);
    static const char *const emb[] = {"e.title", "e.author", "e.subject", "e.keywords",
                                      "e.creator", "e.producer"};
    for (int c = 0; c < (int)ARRAY_LEN(emb); c++) field(emb[c], st, 8 + c);
  }
  sqlite3_finalize(st);
  if (!first_file || page <= 0) return 0;

  if (lines) {
    if (db_prepare(db,
                   "SELECT size, flags, text FROM lines WHERE file = ? AND page = ? ORDER BY n",
                   &st, &err))
      die("%s", err);
    sqlite3_bind_int64(st, 1, first_file);
    sqlite3_bind_int(st, 2, page);
    printf("\n--- page %d, lines ---\n", page);
    int n = 0;
    while (sqlite3_step(st) == SQLITE_ROW) {
      char fl[8];
      flags_str((unsigned)sqlite3_column_int(st, 1), fl);
      printf("%5.1f %-4s %s\n", sqlite3_column_double(st, 0), fl,
             (const char *)sqlite3_column_text(st, 2));
      n++;
    }
    if (!n) printf("(no lines kept for this page; see the layout_pages option)\n");
  } else {
    if (db_prepare(db, "SELECT text FROM pages WHERE file = ? AND page = ?", &st, &err))
      die("%s", err);
    sqlite3_bind_int64(st, 1, first_file);
    sqlite3_bind_int(st, 2, page);
    printf("\n--- page %d ---\n", page);
    if (sqlite3_step(st) == SQLITE_ROW) fputs((const char *)sqlite3_column_text(st, 0), stdout);
    else printf("(page not indexed)\n");
  }
  sqlite3_finalize(st);
  return 0;
}
