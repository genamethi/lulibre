#include "library/fields.h"

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#include "core/util.h"
#include "db/db.h"
#include "match/fold.h"

const char *const field_names[] = {"title",   "authors", "tags",        "series",    "series_index",
                                   "publisher", "pubdate", "identifiers", "languages", NULL};

int field_is_own(const char *field) {
  return field[0] == '#' && field[1];
}

int field_known(const char *field) {
  if (field_is_own(field)) return 1;
  for (int i = 0; field_names[i]; i++)
    if (!strcmp(field, field_names[i])) return 1;
  return 0;
}

int field_is_list(const char *field) {
  return !strcmp(field, "authors") || !strcmp(field, "tags") || !strcmp(field, "identifiers") ||
         !strcmp(field, "languages") || field_is_own(field);
}

static const char *separator(const char *field) {
  return !strcmp(field, "authors") ? " & " : ", ";
}

/* ---- items ---- */

struct items {
  char **v;
  int n, cap;
};

static void push(struct items *it, const char *s, size_t n) {
  while (n && isspace((unsigned char)*s)) s++, n--;
  while (n && isspace((unsigned char)s[n - 1])) n--;
  if (!n) return;
  if (it->n == it->cap) {
    it->cap = it->cap ? it->cap * 2 : 8;
    it->v = xrealloc(it->v, (size_t)it->cap * sizeof *it->v);
  }
  it->v[it->n++] = xstrndup(s, n);
}

static void items_free(struct items *it) {
  for (int i = 0; i < it->n; i++) free(it->v[i]);
  free(it->v);
}

/* Authors split at " & " or ";", the other lists at commas. */
static void split(const char *field, const char *text, struct items *it) {
  if (!strcmp(field, "authors")) {
    const char *p = text;
    for (;;) {
      const char *amp = strstr(p, " & "), *semi = strchr(p, ';');
      const char *end = amp && (!semi || amp < semi) ? amp : semi;
      if (!end) {
        push(it, p, strlen(p));
        return;
      }
      push(it, p, (size_t)(end - p));
      p = end + (end == amp ? 3 : 1);
    }
  }
  for (const char *p = text;;) {
    const char *comma = strchr(p, ',');
    push(it, p, comma ? (size_t)(comma - p) : strlen(p));
    if (!comma) return;
    p = comma + 1;
  }
}

/* What makes two items one: an identifier's type, else the folded text. */
static char *key_of(const char *field, const char *item) {
  sbuf k = SBUF_INIT;
  if (!strcmp(field, "identifiers")) {
    const char *colon = strchr(item, ':');
    size_t n = colon ? (size_t)(colon - item) : strlen(item);
    for (size_t i = 0; i < n; i++) sb_putc(&k, (char)tolower((unsigned char)item[i]));
  } else {
    fold_utf8(&k, item, strlen(item));
  }
  return sb_take(&k);
}

static int cmp_str(const void *a, const void *b) {
  return strcmp(*(char *const *)a, *(char *const *)b);
}

static char *join(const char *field, struct items *it) {
  if (strcmp(field, "authors") && it->n > 1) qsort(it->v, (size_t)it->n, sizeof *it->v, cmp_str);
  sbuf out = SBUF_INIT;
  for (int i = 0; i < it->n; i++) {
    if (i) sb_puts(&out, separator(field));
    sb_puts(&out, it->v[i]);
  }
  return sb_take(&out);
}

/* ---- the current value ---- */

static char *col_or_empty(sqlite3_stmt *st, int col) {
  const char *s = (const char *)sqlite3_column_text(st, col);
  return xstrdup(s ? s : "");
}

char *field_current(struct db *db, long long book, const char *field, char **err) {
  if (!field_known(field)) {
    *err = xasprintf("no field is called %s", field);
    return NULL;
  }
  sqlite3_stmt *st;
  if (field_is_own(field)) {
    if (db_prepare(db, "SELECT group_concat(value, ', ' ORDER BY ord) FROM custom.data WHERE book = ? AND field = ?",
                   &st, err))
      return NULL;
    sqlite3_bind_int64(st, 1, book);
    sqlite3_bind_text(st, 2, field, -1, SQLITE_STATIC);
    char *v = sqlite3_step(st) == SQLITE_ROW ? col_or_empty(st, 0) : xstrdup("");
    sqlite3_finalize(st);
    return v;
  }
  if (db_prepare(db,
                 "SELECT title, authors, tags, series, series_index, publisher, pubdate, idents, languages"
                 " FROM books WHERE id = ?",
                 &st, err))
    return NULL;
  sqlite3_bind_int64(st, 1, book);
  if (sqlite3_step(st) != SQLITE_ROW) {
    sqlite3_finalize(st);
    *err = xasprintf("no book %lld", book);
    return NULL;
  }
  char *v;
  if (!strcmp(field, "title")) {
    v = col_or_empty(st, 0);
  } else if (!strcmp(field, "authors")) {
    v = col_or_empty(st, 1);
    if (!strcmp(v, "Unknown") || !strcmp(v, "()")) v[0] = '\0';
  } else if (!strcmp(field, "series")) {
    v = col_or_empty(st, 3);
  } else if (!strcmp(field, "series_index")) {
    /* calibre gives every book an index; it means nothing without a series */
    const char *series = (const char *)sqlite3_column_text(st, 3);
    v = series && *series && sqlite3_column_type(st, 4) != SQLITE_NULL ? xasprintf("%.10g", sqlite3_column_double(st, 4))
                                                                       : xstrdup("");
  } else if (!strcmp(field, "publisher")) {
    v = col_or_empty(st, 5);
  } else if (!strcmp(field, "pubdate")) {
    v = col_or_empty(st, 6);
  } else {
    /* tags, identifiers, languages: as one form, sorted */
    int col = !strcmp(field, "tags") ? 2 : !strcmp(field, "identifiers") ? 7 : 8;
    char *raw = col_or_empty(st, col);
    struct items it = {0};
    split(field, raw, &it);
    v = join(field, &it);
    items_free(&it);
    free(raw);
  }
  sqlite3_finalize(st);
  return v;
}

/* ---- the value after a change ---- */

static int is_digits(const char *s, size_t n) {
  for (size_t i = 0; i < n; i++)
    if (!isdigit((unsigned char)s[i])) return 0;
  return 1;
}

char *field_resolve(const char *field, enum change_op op, const char *current, const char *value, char **err) {
  if (!field_known(field)) {
    *err = xasprintf("no field is called %s", field);
    return NULL;
  }
  if (!field_is_list(field)) {
    if (op != CHANGE_SET) {
      *err = xasprintf("%s holds one value: it is set, not added to or removed from", field);
      return NULL;
    }
    struct items it = {0};
    push(&it, value, strlen(value));
    char *v = it.n ? xstrdup(it.v[0]) : xstrdup("");
    items_free(&it);
    if (!strcmp(field, "pubdate") && *v) {
      size_t n = strlen(v);
      if (n == 4 && is_digits(v, 4)) {
        char *full = xasprintf("%s-01-01", v); /* a bare year: the first of January */
        free(v);
        v = full;
      } else if (n != 10 || !is_digits(v, 4) || v[4] != '-' || !is_digits(v + 5, 2) || v[7] != '-' ||
                 !is_digits(v + 8, 2)) {
        free(v);
        *err = xstrdup("a date is written YYYY or YYYY-MM-DD");
        return NULL;
      }
    }
    if (!strcmp(field, "series_index") && *v) {
      char *end;
      double x = strtod(v, &end);
      if (*end) {
        free(v);
        *err = xstrdup("a series index is a number");
        return NULL;
      }
      free(v);
      v = xasprintf("%.10g", x);
    }
    return v;
  }
  struct items now = {0}, given = {0};
  split(field, value, &given);
  if (!strcmp(field, "identifiers"))
    for (int i = 0; i < given.n; i++) {
      const char *colon = strchr(given.v[i], ':');
      if ((!colon || colon == given.v[i] || !colon[1]) && !(op == CHANGE_REMOVE && !colon)) {
        items_free(&given);
        *err = xstrdup("identifiers are written type:value, for example doi:10.1000/xyz");
        return NULL;
      }
    }
  if (op == CHANGE_SET) {
    char *v = join(field, &given);
    items_free(&given);
    return v;
  }
  split(field, current, &now);
  for (int i = 0; i < given.n; i++) {
    char *k = key_of(field, given.v[i]);
    int at = -1;
    for (int j = 0; j < now.n && at < 0; j++) {
      char *kj = key_of(field, now.v[j]);
      if (!strcmp(k, kj)) at = j;
      free(kj);
    }
    if (op == CHANGE_ADD) {
      if (at >= 0) { /* the same tag, or a new value for that identifier */
        free(now.v[at]);
        now.v[at] = xstrdup(given.v[i]);
      } else {
        push(&now, given.v[i], strlen(given.v[i]));
      }
    } else if (at >= 0) {
      free(now.v[at]);
      memmove(&now.v[at], &now.v[at + 1], (size_t)(now.n - at - 1) * sizeof *now.v);
      now.n--;
    }
    free(k);
  }
  char *v = join(field, &now);
  items_free(&now);
  items_free(&given);
  return v;
}

char *field_wire(const char *field, const char *value) {
  if (!strcmp(field, "tags") || !strcmp(field, "identifiers") || !strcmp(field, "languages")) {
    sbuf out = SBUF_INIT;
    for (const char *p = value; *p; p++) {
      if (*p == ',') {
        sb_putc(&out, ',');
        while (p[1] == ' ') p++;
      } else {
        sb_putc(&out, *p);
      }
    }
    return sb_take(&out);
  }
  if (!strcmp(field, "series_index") && !*value) return xstrdup("1"); /* calibre's default */
  if (!strcmp(field, "pubdate")) {
    /* A complete UTC time: left to fill in a time of day, calibre takes the
     * current one, which can land on the next day; noon UTC is the same day
     * everywhere. An empty date is calibre's "no date". */
    if (!*value) return xstrdup("0101-01-01T00:00:00+00:00");
    if (strlen(value) == 10) return xasprintf("%sT12:00:00+00:00", value);
  }
  return xstrdup(value);
}
