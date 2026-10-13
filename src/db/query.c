#include "db/query.h"

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#include "core/util.h"

enum fkind {
  F_COL, F_AUTHOR, F_TAG, F_SUBJECT, F_FMT, F_NUM, F_IDENT, F_IDTYPE, F_HAS, F_NO, F_IS,
  F_TEXT, F_EMB, F_SORT, F_IN,
};

static const struct field {
  const char *name;
  enum fkind kind;
  const char *col;
} fields[] = {
  {"title", F_COL, "b.title"},         {"t", F_COL, "b.title"},
  {"author", F_AUTHOR, NULL},          {"authors", F_AUTHOR, NULL},
  {"a", F_AUTHOR, NULL},               {"tag", F_TAG, NULL},
  {"tags", F_TAG, NULL},               {"subject", F_SUBJECT, NULL},
  {"s", F_SUBJECT, NULL},              {"publisher", F_COL, "b.publisher"},
  {"pub", F_COL, "b.publisher"},       {"series", F_COL, "b.series"},
  {"lang", F_COL, "b.languages"},      {"path", F_COL, "b.path"},
  {"fmt", F_FMT, NULL},                {"format", F_FMT, NULL},
  {"id", F_NUM, "b.id"},               {"year", F_NUM, "b.year"},
  {"ident", F_IDENT, NULL},            {"doi", F_IDTYPE, "doi"},
  {"isbn", F_IDTYPE, "isbn"},          {"arxiv", F_IDTYPE, "arxiv"},
  {"url", F_IDTYPE, "url"},            {"has", F_HAS, NULL},
  {"no", F_NO, NULL},                  {"is", F_IS, NULL},
  {"text", F_TEXT, NULL},              {"emb", F_EMB, NULL},
  {"sort", F_SORT, NULL},              {"in", F_IN, NULL},
};

#define UNKNOWN_AUTHOR "(b.authors IS NULL OR b.authors IN ('', 'Unknown', '()'))"
#define IDENT_OF(type) "EXISTS(SELECT 1 FROM idents i WHERE i.book = b.id AND i.type = '" type "')"
#define ANY_FILE(cond) "EXISTS(SELECT 1 FROM files f WHERE f.book = b.id AND " cond ")"

static const struct { const char *name, *sql; } has_tests[] = {
  {"author", "NOT " UNKNOWN_AUTHOR},  {"authors", "NOT " UNKNOWN_AUTHOR},
  {"tag", "b.tags IS NOT NULL"},      {"tags", "b.tags IS NOT NULL"},
  {"subject", "b.tags IS NOT NULL"},  {"ids", "b.idents IS NOT NULL"},
  {"ident", "b.idents IS NOT NULL"},  {"doi", IDENT_OF("doi")},
  {"isbn", IDENT_OF("isbn")},         {"arxiv", IDENT_OF("arxiv")},
  {"url", IDENT_OF("url")},           {"publisher", "b.publisher IS NOT NULL"},
  {"date", "b.year IS NOT NULL"},     {"year", "b.year IS NOT NULL"},
  {"series", "b.series IS NOT NULL"}, {"comments", "b.has_comments"},
  {"lang", "b.languages IS NOT NULL"}, {"text", ANY_FILE("f.nchars >= 200")},
  {"file", ANY_FILE("1")},
};

static const struct { const char *name, *sql; } is_tests[] = {
  {"listauthor", "EXISTS(SELECT 1 FROM book_authors ba JOIN authors a ON a.id = ba.author"
                 " WHERE ba.book = b.id AND (a.name LIKE '%;%' OR a.name LIKE '% and %'))"},
  {"filetitle", "(instr(b.title, ' ') = 0 OR b.title LIKE '%.pdf' OR b.title LIKE '%.djvu'"
                " OR b.title LIKE '%.dvi' OR b.title LIKE '%.tex' OR b.title LIKE '%.ps')"},
  /* a title in capitals (as far as A to Z go): what :titlecase is for */
  {"capstitle", "(b.title = upper(b.title) AND b.title <> lower(b.title) AND length(b.title) > 3)"},
  /* confirmed as right by the user (:good) */
  {"good", "EXISTS(SELECT 1 FROM good g WHERE g.book = b.id)"},
  {"indexed", ANY_FILE("f.status = 1")},
  {"unindexed", ANY_FILE("f.status = 0")},
  {"error", ANY_FILE("f.status = 2")},
  {"missing", "(NOT " ANY_FILE("1") " OR " ANY_FILE("f.status = 3") ")"},
  /* thresholds measured on a maths-heavy library, where sound text scores
   * 0.5-0.8 because formulas are full of one-letter tokens */
  {"needsocr", ANY_FILE("f.status = 1 AND (f.nchars < 200 OR f.quality < 0.4)")},
  {"multiformat", "(SELECT count(*) FROM files f WHERE f.book = b.id) > 1"},
  {"marked", "b.id IN (SELECT id FROM marks)"},
  {"ocr", ANY_FILE("f.text_src = 'ocr'")},
  {"proposed", "b.id IN (SELECT book FROM proposals WHERE status IN ('pending', 'accepted'))"},
  /* byte-identical to another book's file; known once :dupes has hashed them */
  {"dupe", "b.id IN (SELECT f.book FROM files f JOIN hashes h ON h.path = f.path"
           " WHERE f.book > 0 AND h.md5 IN (SELECT h2.md5 FROM hashes h2 JOIN files f2"
           " ON f2.path = h2.path WHERE f2.book > 0 GROUP BY h2.md5 HAVING count(DISTINCT f2.book) > 1))"},
  /* a staged file whose bytes a library book already holds */
  {"inlibrary", "EXISTS(SELECT 1 FROM staged s WHERE s.id = -b.id AND s.twin IS NOT NULL)"},
};

static const struct { const char *name, *sql; } sort_keys[] = {
  {"id", "b.id"},
  {"title", "b.sort COLLATE NOCASE"},
  {"author", "b.author_sort COLLATE NOCASE"},
  {"year", "b.year"},
  {"series", "b.series IS NULL, b.series COLLATE NOCASE, b.series_index"},
  {"added", "b.added"},
  {"modified", "b.modified"},
};

static void add_param(struct query *q, const char *v) {
  if (q->nparams == q->cap) {
    q->cap = q->cap ? q->cap * 2 : 8;
    q->params = xrealloc(q->params, (size_t)q->cap * sizeof *q->params);
  }
  q->params[q->nparams++] = xstrdup(v);
}

/* SQL for "<expr> matches <val>" under the operator prefix of val. */
static void match(struct query *q, sbuf *sql, const char *expr, const char *val) {
  const char *fn = "ihas";
  if (*val == '=') { fn = "ieq"; val++; }
  else if (*val == '^') { fn = "istarts"; val++; }
  else if (*val == '~') { fn = "lmatch"; val++; }
  sb_printf(sql, "%s(%s, ?)", fn, expr);
  add_param(q, val);
}

static int number_term(sbuf *sql, const char *col, const char *val, char **err) {
  /* 12 | 10-20 | >5 | <=9 | comma list of those */
  char *copy = xstrdup(val), *save = NULL;
  int first = 1, rc = 0;
  sb_putc(sql, '(');
  for (char *part = strtok_r(copy, ",", &save); part; part = strtok_r(NULL, ",", &save)) {
    const char *op = NULL;
    if (!strncmp(part, ">=", 2) || !strncmp(part, "<=", 2)) { op = part[0] == '>' ? ">=" : "<="; part += 2; }
    else if (*part == '>' || *part == '<') { op = *part == '>' ? ">" : "<"; part++; }
    char *end;
    long a = strtol(part, &end, 10), b = a;
    if (end == part) { rc = -1; break; }
    if (!op && *end == '-') {
      char *s = end + 1;
      b = strtol(s, &end, 10);
      if (end == s) { rc = -1; break; }
    }
    if (*end) { rc = -1; break; }
    if (!first) sb_puts(sql, " OR ");
    first = 0;
    if (op) sb_printf(sql, "%s %s %ld", col, op, a);
    else if (a == b) sb_printf(sql, "%s = %ld", col, a);
    else sb_printf(sql, "%s BETWEEN %ld AND %ld", col, a, b);
  }
  sb_putc(sql, ')');
  free(copy);
  if (rc || first) {
    *err = xasprintf("bad number '%s' (use 12, 10-20, >5, <=9 or a comma list)", val);
    return -1;
  }
  return 0;
}

static const char *lookup(const void *table, size_t n, size_t stride, const char *name) {
  /* every table above is {name, sql} pairs of pointers */
  for (size_t i = 0; i < n; i++) {
    const char *const *row = (const char *const *)((const char *)table + i * stride);
    if (strcasecmp(row[0], name) == 0) return row[1];
  }
  return NULL;
}
#define LOOKUP(table, name) lookup(table, ARRAY_LEN(table), sizeof(table)[0], name)

static char *names_of(const void *table, size_t n, size_t stride) {
  sbuf b = SBUF_INIT;
  for (size_t i = 0; i < n; i++) {
    const char *const *row = (const char *const *)((const char *)table + i * stride);
    if (i) sb_putc(&b, ' ');
    sb_puts(&b, row[0]);
  }
  return sb_take(&b);
}
#define NAMES(table) names_of(table, ARRAY_LEN(table), sizeof(table)[0])

static int field_term(struct query *q, sbuf *sql, const struct field *f, const char *val,
                      char **err) {
  int none = strcasecmp(val, "none") == 0;
  switch (f->kind) {
    case F_COL:
      if (none) sb_printf(sql, "(%s IS NULL OR %s = '')", f->col, f->col);
      else match(q, sql, f->col, val);
      return 0;
    case F_AUTHOR:
      if (none || strcasecmp(val, "unknown") == 0) {
        sb_puts(sql, UNKNOWN_AUTHOR);
      } else {
        sb_puts(sql, "EXISTS(SELECT 1 FROM book_authors ba JOIN authors a ON a.id = ba.author"
                     " WHERE ba.book = b.id AND ");
        match(q, sql, "a.name", val);
        sb_putc(sql, ')');
      }
      return 0;
    case F_TAG:
    case F_SUBJECT:
      if (none) {
        sb_puts(sql, "b.tags IS NULL");
        return 0;
      }
      sb_puts(sql, "EXISTS(SELECT 1 FROM book_tags bt JOIN tags t ON t.id = bt.tag"
                   " WHERE bt.book = b.id AND ");
      if (f->kind == F_SUBJECT && !strchr("=^~", *val)) {
        sb_puts(sql, "isubject(t.name, ?)");
        add_param(q, val);
      } else {
        match(q, sql, "t.name", val);
      }
      sb_putc(sql, ')');
      return 0;
    case F_FMT:
      sb_puts(sql, ANY_FILE("f.format = upper(?)"));
      add_param(q, val);
      return 0;
    case F_NUM:
      if (none) {
        sb_printf(sql, "%s IS NULL", f->col);
        return 0;
      }
      return number_term(sql, f->col, val, err);
    case F_IDENT:
      sb_puts(sql, "EXISTS(SELECT 1 FROM idents i WHERE i.book = b.id AND i.type = lower(?))");
      add_param(q, val);
      return 0;
    case F_IDTYPE:
      if (none) {
        sb_printf(sql, "NOT EXISTS(SELECT 1 FROM idents i WHERE i.book = b.id AND i.type = '%s')",
                  f->col);
      } else {
        sb_printf(sql, "EXISTS(SELECT 1 FROM idents i WHERE i.book = b.id AND i.type = '%s' AND ",
                  f->col);
        match(q, sql, "i.val", val);
        sb_putc(sql, ')');
      }
      return 0;
    case F_HAS:
    case F_NO: {
      const char *t = LOOKUP(has_tests, val);
      if (!t) {
        char *names = NAMES(has_tests);
        *err = xasprintf("%s:%s is not known; try one of: %s", f->name, val, names);
        free(names);
        return -1;
      }
      sb_printf(sql, f->kind == F_NO ? "NOT (%s)" : "(%s)", t);
      return 0;
    }
    case F_IS: {
      const char *t = LOOKUP(is_tests, val);
      if (!t) {
        char *names = NAMES(is_tests);
        *err = xasprintf("is:%s is not known; try one of: %s", val, names);
        free(names);
        return -1;
      }
      sb_printf(sql, "(%s)", t);
      return 0;
    }
    case F_TEXT:
      if (*val == '~') {
        sb_puts(sql, "b.id IN (SELECT f.book FROM pages p JOIN files f ON f.id = p.file"
                     " WHERE lmatch(p.text, ?))");
        add_param(q, val + 1);
        return 0;
      }
      sb_puts(sql, "b.id IN (SELECT f.book FROM pages_fts JOIN pages p ON p.id = pages_fts.rowid"
                   " JOIN files f ON f.id = p.file WHERE pages_fts MATCH ?)");
      if (*val == '=') {
        add_param(q, val + 1); /* raw FTS5 syntax */
      } else {
        sbuf phrase = SBUF_INIT;
        sb_putc(&phrase, '"');
        for (const char *p = val; *p; p++) {
          if (*p == '"') sb_putc(&phrase, '"');
          sb_putc(&phrase, *p);
        }
        sb_putc(&phrase, '"');
        add_param(q, phrase.s);
        sb_free(&phrase);
      }
      return 0;
    case F_EMB:
      sb_puts(sql, "EXISTS(SELECT 1 FROM files f WHERE f.book = b.id AND ");
      match(q, sql,
            "coalesce(f.emb_title, '') || ' ' || coalesce(f.emb_author, '') || ' ' ||"
            " coalesce(f.emb_subject, '') || ' ' || coalesce(f.emb_keywords, '')",
            val);
      sb_putc(sql, ')');
      return 0;
    case F_IN:
      if (!strcasecmp(val, "library")) q->scope = SCOPE_LIBRARY;
      else if (!strcasecmp(val, "sync")) q->scope = SCOPE_SYNC;
      else if (!strcasecmp(val, "all")) q->scope = SCOPE_ALL;
      else {
        *err = xasprintf("in:%s is not known; try one of: library, sync, all", val);
        return -1;
      }
      sb_puts(sql, "1");
      return 0;
    case F_SORT: {
      int desc = *val == '-';
      const char *t = LOOKUP(sort_keys, val + desc);
      if (!t) {
        char *names = NAMES(sort_keys);
        *err = xasprintf("sort:%s is not known; try one of: %s", val, names);
        free(names);
        return -1;
      }
      free(q->order);
      q->order = xasprintf("%s %s, b.id", t, desc ? "DESC" : "ASC");
      sb_puts(sql, "1");
      return 0;
    }
  }
  return 0;
}

/* Read one token's value: a quoted string (\" escapes a quote) or a run of
 * non-space characters. Returns malloc'd text and advances *pp. */
static char *read_value(const char **pp, char **err) {
  const char *p = *pp;
  sbuf v = SBUF_INIT;
  /* an operator prefix may precede the opening quote: title:~"^The " */
  while (*p && strchr("=^~", *p) && v.len == 0) sb_putc(&v, *p++);
  if (*p == '"') {
    for (p++; *p && *p != '"'; p++) {
      if (*p == '\\' && p[1] == '"') p++;
      sb_putc(&v, *p);
    }
    if (*p != '"') {
      sb_free(&v);
      *err = xstrdup("unterminated quote");
      return NULL;
    }
    p++;
  } else {
    while (*p && !isspace((unsigned char)*p)) sb_putc(&v, *p++);
  }
  *pp = p;
  return sb_take(&v);
}

int query_compile(const char *filter, struct query *q, char **err) {
  return query_compile_in(filter, SCOPE_LIBRARY, q, err);
}

int query_compile_in(const char *filter, int scope, struct query *q, char **err) {
  memset(q, 0, sizeof *q);
  sbuf sql = SBUF_INIT;
  const char *p = filter ? filter : "";
  int terms_in_group = 0, groups = 0;

  sb_putc(&sql, '(');
  for (;;) {
    while (isspace((unsigned char)*p)) p++;
    if (!*p) break;

    int neg = 0;
    if (*p == '-' && p[1] && !isspace((unsigned char)p[1])) { neg = 1; p++; }

    /* field: prefix? */
    const struct field *f = NULL;
    const char *k = p;
    while (isalpha((unsigned char)*k)) k++;
    if (*k == ':' && k > p && *p != '"') {
      char *name = xstrndup(p, (size_t)(k - p));
      for (size_t i = 0; i < ARRAY_LEN(fields); i++)
        if (strcasecmp(fields[i].name, name) == 0) f = &fields[i];
      if (!f) {
        *err = xasprintf("unknown field '%s' (quote the term to search for it literally)", name);
        free(name);
        goto fail;
      }
      free(name);
      p = k + 1;
    }

    char *val = read_value(&p, err);
    if (!val) goto fail;

    if (!f && !neg && strcasecmp(val, "or") == 0) {
      free(val);
      if (terms_in_group) {
        sb_puts(&sql, ") OR (");
        terms_in_group = 0;
        groups++;
      }
      continue;
    }

    if (terms_in_group) sb_puts(&sql, " AND ");
    if (neg) sb_puts(&sql, "NOT ");
    int rc = 0;
    if (f) {
      rc = field_term(q, &sql, f, val, err);
    } else {
      sb_puts(&sql, "(ihas(b.title, ?) OR ihas(b.authors, ?) OR ihas(b.tags, ?))");
      for (int i = 0; i < 3; i++) add_param(q, val);
    }
    free(val);
    if (rc) goto fail;
    terms_in_group++;
  }
  /* an empty filter matches everything; an empty alternative matches nothing */
  if (!terms_in_group) sb_puts(&sql, groups ? "0" : "1");
  sb_putc(&sql, ')');
  /* library books have positive ids, staged files negative ones */
  if (!q->scope) q->scope = scope;
  if (q->scope == SCOPE_LIBRARY) sb_puts(&sql, " AND b.id > 0");
  else if (q->scope == SCOPE_SYNC) sb_puts(&sql, " AND b.id < 0");

  q->where = sb_take(&sql);
  if (!q->order) q->order = xstrdup(q->scope == SCOPE_SYNC ? "b.id DESC" : "b.id");
  return 0;
fail:
  sb_free(&sql);
  query_free(q);
  return -1;
}

void query_words(void (*fn)(const char *word, void *ud), void *ud) {
  char buf[64];
  for (size_t i = 0; i < ARRAY_LEN(fields); i++) {
    if (strlen(fields[i].name) < 2) continue; /* one-letter aliases would only crowd the list */
    snprintf(buf, sizeof buf, "%s:", fields[i].name);
    fn(buf, ud);
  }
  for (size_t i = 0; i < ARRAY_LEN(is_tests); i++) {
    snprintf(buf, sizeof buf, "is:%s", is_tests[i].name);
    fn(buf, ud);
  }
  for (size_t i = 0; i < ARRAY_LEN(has_tests); i++) {
    snprintf(buf, sizeof buf, "has:%s", has_tests[i].name);
    fn(buf, ud);
    snprintf(buf, sizeof buf, "no:%s", has_tests[i].name);
    fn(buf, ud);
  }
  for (size_t i = 0; i < ARRAY_LEN(sort_keys); i++) {
    snprintf(buf, sizeof buf, "sort:%s", sort_keys[i].name);
    fn(buf, ud);
    snprintf(buf, sizeof buf, "sort:-%s", sort_keys[i].name);
    fn(buf, ud);
  }
  fn("in:library", ud);
  fn("in:sync", ud);
  fn("in:all", ud);
}

void query_free(struct query *q) {
  for (int i = 0; i < q->nparams; i++) free(q->params[i]);
  free(q->params);
  free(q->where);
  free(q->order);
  memset(q, 0, sizeof *q);
}

int query_prepare(struct db *db, const struct query *q, const char *cols, int limit,
                  sqlite3_stmt **st, char **err) {
  sbuf sql = SBUF_INIT;
  sb_printf(&sql, "SELECT %s FROM books b WHERE %s ORDER BY %s", cols, q->where, q->order);
  if (limit > 0) sb_printf(&sql, " LIMIT %d", limit);
  int rc = db_prepare(db, sql.s, st, err);
  sb_free(&sql);
  if (rc) return rc;
  for (int i = 0; i < q->nparams; i++)
    sqlite3_bind_text(*st, i + 1, q->params[i], -1, SQLITE_TRANSIENT);
  return 0;
}
