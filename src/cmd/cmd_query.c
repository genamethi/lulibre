#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "app.h"
#include "cmd/cmd.h"
#include "core/util.h"
#include "db/query.h"

#define FIRST_FILE(col) "(SELECT f." col " FROM files f WHERE f.book = b.id ORDER BY f.id LIMIT 1)"

static const struct { const char *name, *sql; } columns[] = {
  {"id", "b.id"},
  {"title", "b.title"},
  {"authors", "b.authors"},
  {"tags", "b.tags"},
  {"year", "b.year"},
  {"publisher", "b.publisher"},
  {"series", "b.series"},
  {"formats", "b.formats"},
  {"idents", "b.idents"},
  {"lang", "b.languages"},
  {"added", "b.added"},
  {"modified", "b.modified"},
  {"dir", "b.path"},
  {"file", FIRST_FILE("path")},
  {"pages", FIRST_FILE("npages")},
  {"chars", FIRST_FILE("nchars")},
  {"quality", "round(" FIRST_FILE("quality") ", 2)"},
  {"etitle", FIRST_FILE("emb_title")},
  {"eauthor", FIRST_FILE("emb_author")},
  {"error", FIRST_FILE("error")},
};

static const char help[] =
  "usage: lulibre query [options] [filter]\n\n"
  "List books matching a filter, one per line, tab-separated.\n\n"
  "  -f COLS    columns, comma-separated (default id,authors,title,tags)\n"
  "  -n N       at most N rows\n"
  "  -c         print only the number of matches\n"
  "  -H         print a header row\n"
  "  --sql      print the SQL the filter compiles to, and stop\n\n"
  "Columns: ";

static const char filter_help[] =
  "\n\nFilter: terms separated by spaces all have to hold; `or` starts an alternative;\n"
  "a leading - negates a term.\n"
  "  word, \"a phrase\"    substring of title, authors or tags\n"
  "  field:value         substring of one field, ignoring case and accents\n"
  "  field:=value        exact      field:^value   prefix\n"
  "  field:~pattern      Lua pattern, as in string.find\n"
  "  field:none          empty\n"
  "Fields: title author tag subject publisher series lang path fmt id year\n"
  "        ident doi isbn arxiv url emb text has no is sort\n"
  "  subject:number-theory   also matches the tag math/number-theory/additive\n"
  "  author:unknown          calibre's placeholder authors\n"
  "  year:>1990  id:10-20,35 numbers and ranges\n"
  "  text:\"class field\"      full text of the indexed pages (text:~ for a Lua pattern)\n"
  "  emb:springer            metadata embedded in the files\n"
  "  has:doi  no:publisher   author tags ids doi isbn arxiv url publisher date series\n"
  "                          comments lang text file\n"
  "  is:filetitle            listauthor filetitle indexed unindexed error missing\n"
  "                          needsocr multiformat marked ocr proposed dupe\n"
  "                          inlibrary\n"
  "  sort:-added             id title author year series added modified\n"
  "  in:sync                 library (default) | sync (staged files) | all\n";

static void print_help(void) {
  fputs(help, stdout);
  for (size_t i = 0; i < ARRAY_LEN(columns); i++) printf("%s%s", i ? " " : "", columns[i].name);
  fputs(filter_help, stdout);
}

/* "id,title" -> "b.id, b.title"; dies on an unknown column */
static char *select_list(const char *spec) {
  sbuf sql = SBUF_INIT;
  char *copy = xstrdup(spec), *save = NULL;
  for (char *c = strtok_r(copy, ",", &save); c; c = strtok_r(NULL, ",", &save)) {
    const char *expr = NULL;
    for (size_t i = 0; i < ARRAY_LEN(columns); i++)
      if (!strcmp(columns[i].name, c)) expr = columns[i].sql;
    if (!expr) die("unknown column '%s' (see lulibre query -h)", c);
    if (sql.len) sb_puts(&sql, ", ");
    sb_puts(&sql, expr);
  }
  free(copy);
  if (!sql.len) die("no columns given");
  return sb_take(&sql);
}

int cmd_query(struct app *app, int argc, char **argv) {
  const char *cols = "id,authors,title,tags";
  int limit = 0, count = 0, header = 0, show_sql = 0, i = 1;
  for (; i < argc; i++) {
    const char *a = argv[i];
    if (!strcmp(a, "-h") || !strcmp(a, "--help")) { print_help(); return 0; }
    else if (!strcmp(a, "-f") && i + 1 < argc) cols = argv[++i];
    else if (!strcmp(a, "-n") && i + 1 < argc) limit = atoi(argv[++i]);
    else if (!strcmp(a, "-c")) count = 1;
    else if (!strcmp(a, "-H")) header = 1;
    else if (!strcmp(a, "--sql")) show_sql = 1;
    else if (!strcmp(a, "--")) { i++; break; }
    else break;
  }
  char *filter = cmd_join(argc, argv, i);
  struct query q;
  char *err = NULL;
  if (query_compile(filter, &q, &err)) die("filter: %s", err);
  free(filter);

  if (show_sql) {
    printf("WHERE %s\nORDER BY %s\n", q.where, q.order);
    for (int k = 0; k < q.nparams; k++) printf("?%d = %s\n", k + 1, q.params[k]);
    query_free(&q);
    return 0;
  }

  app_open_db(app);
  char *list = count ? xstrdup("count(*)") : select_list(cols);
  sqlite3_stmt *st;
  if (count) {
    free(q.order);
    q.order = xstrdup("1");
  }
  if (query_prepare(&app->db, &q, list, limit, &st, &err)) die("%s", err);

  if (header && !count) {
    char *h = xstrdup(cols);
    for (char *p = h; *p; p++)
      if (*p == ',') *p = '\t';
    puts(h);
    free(h);
  }
  int rc, ncol = sqlite3_column_count(st);
  while ((rc = sqlite3_step(st)) == SQLITE_ROW) {
    for (int c = 0; c < ncol; c++) {
      if (c) fputc('\t', stdout);
      cmd_put_cell(stdout, st, c);
    }
    fputc('\n', stdout);
  }
  int failed = rc != SQLITE_DONE;
  if (failed) warnf("%s", sqlite3_errmsg(app->db.h));
  sqlite3_finalize(st);
  free(list);
  query_free(&q);
  return failed;
}
