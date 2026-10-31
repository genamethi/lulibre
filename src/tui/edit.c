/* The edit form and undo (design 31, 32): editing works in C, with no Lua.
 *
 * :edit opens a form on the selection (the book under the cursor, or the
 * marked books): a staged form (panel_set_form), a row per field with the
 * value it has (the first book's, when there are several) and the value it
 * is to get. Its keys are the place form's: edit (Enter or e) a row's
 * value, for a list field "+a, -b" adding a and taking b out and keeping
 * the rest; drop (x) a row's change; write (w) them all as one operation of
 * the library, to every book in the form. :undo puts the last change back. */
#include <stdlib.h>
#include <string.h>

#include "app.h"
#include "core/queue.h"
#include "core/util.h"
#include "library/fields.h"
#include "library/library.h"
#include "tui/tui.h"

enum { NFIELDS = 9 }; /* field_names */

struct form {
  struct tui *t;
  long long *books;
  int nbooks;
};

static void form_free(struct form *f) {
  free(f->books);
  free(f);
}

/* "+a, -b" for a list field: the changes it makes; else one that sets it. */
static int changes_of(const char *field, const char *text, long long book, struct change *out, int max) {
  const char *s = text;
  while (*s == ' ') s++;
  if (!field_is_list(field) || (*s != '+' && *s != '-')) {
    out[0] = (struct change){.book = book, .field = field, .value = text, .op = CHANGE_SET};
    return 1;
  }
  int n = 0;
  for (const char *p = s; *p && n < max;) {
    while (*p == ' ' || *p == ',') p++;
    if (!*p) break;
    enum change_op op = *p == '-' ? CHANGE_REMOVE : CHANGE_ADD;
    if (*p == '+' || *p == '-') p++;
    const char *end = strchr(p, ',');
    size_t len = end ? (size_t)(end - p) : strlen(p);
    out[n++] = (struct change){.book = book, .field = field, .value = xstrndup(p, len), .op = op};
    p += len;
  }
  return n;
}

/* ---- to the library, on the background thread (work.h), and back ---- */

struct job {
  struct op_settings set; /* the settings in effect as it was made */
  struct change *ch; /* its own copies */
  int n;
  long long undo; /* a batch to put back, in place of ch */
  /* the answer */
  long long batch;
  int failed;
  char *err;
};

static void job_free(struct job *j) {
  for (int i = 0; i < j->n; i++) free((char *)j->ch[i].value);
  free(j->ch);
  free(j->err);
  free((char *)j->set.server);
  free((char *)j->set.user);
  free((char *)j->set.password_file);
  free(j);
}

static void told(struct app *app, void *arg) { /* the interface */
  struct job *j = arg;
  struct tui *t = app->tui;
  if (t && j->undo) {
    if (j->failed) tui_msg(t, 1, "undo failed: %s", j->err ? j->err : "?");
    else tui_msg(t, 0, "put back (batch %lld)", j->batch);
  } else if (t) {
    if (j->failed) tui_msg(t, 1, "the change failed: %s", j->err ? j->err : "?");
    else if (!j->batch) tui_msg(t, 0, "nothing to change");
    else tui_msg(t, 0, "changed (batch %lld; :undo puts it back)", j->batch);
  }
  job_free(j);
}

static void written(long long batch, enum op_state state, const char *err, void *ud) { /* the background thread */
  struct job *j = ud;
  j->batch = batch;
  j->failed = state == OP_FAILED;
  j->err = err ? xstrdup(err) : NULL;
  queue_post(LOOP_UI, told, j);
}

static struct job *job_new(struct app *app) { /* the interface */
  struct job *j = xcalloc(1, sizeof *j);
  j->set = (struct op_settings){xstrdup(app_str(app, S_SERVER)), xstrdup(app_str(app, S_USER)),
                                xstrdup(app_str(app, S_PASSWORD_FILE)), app_bool(app, S_EMBED),
                                (int)app_int(app, S_WRITE_JOBS)};
  return j;
}

static void to_library(struct app *app, void *arg) { /* the background thread */
  struct job *j = arg;
  char *err = NULL;
  int rc;
  if (!app->library) {
    rc = -1;
    err = xstrdup("the library is closed");
  } else if (j->undo) {
    rc = library_undo(app->library, j->undo, &j->set, written, j, &err);
  } else {
    struct operation op = {.set = &j->set, .label = "edit", .need = NEED_ANY, .changes = j->ch, .nchanges = j->n};
    rc = library_submit(app->library, &op, written, j, &err);
  }
  if (rc) {
    written(0, OP_FAILED, err, j);
    free(err);
  }
}

/* the panel's changes, to every book in the form, as one operation */
static void write_form(struct form *f, struct panel *p) {
  enum { PER = 64 };
  struct change *ch = xcalloc((size_t)f->nbooks * NFIELDS * PER, sizeof *ch);
  int n = 0;
  for (int b = 0; b < f->nbooks; b++)
    for (int i = 0; i < NFIELDS; i++) {
      const char *change, *field = panel_field(p, i, &change);
      if (field && change) n += changes_of(field_names[i], change, f->books[b], ch + n, PER);
    }
  if (!n) {
    tui_msg(f->t, 0, "no change to write");
    free(ch);
    return;
  }
  /* the job owns its values: an add's or remove's are copies already */
  for (int i = 0; i < n; i++)
    if (ch[i].op == CHANGE_SET) ch[i].value = xstrdup(ch[i].value);
  struct job *j = job_new(f->t->app);
  j->ch = ch;
  j->n = n;
  queue_post(LOOP_WORK, to_library, j);
  panel_close(p);
}

static void on_event(struct panel *p, const char *key, int row, const char *value, void *ud) {
  struct form *f = ud;
  if (!key) { /* closed */
    panel_unref(p);
    form_free(f);
  } else if (!strcmp(key, "write")) {
    write_form(f, p);
  }
}

static void c_edit(struct tui *t, const char *args) {
  if (!t->app->library) {
    tui_msg(t, 1, "no library is open");
    return;
  }
  int n;
  sqlite3_int64 *ids = rows_selection(t, &n);
  if (!n) {
    free(ids);
    tui_msg(t, 1, "no book to edit");
    return;
  }
  struct form *f = xcalloc(1, sizeof *f);
  f->t = t;
  f->nbooks = n;
  f->books = xcalloc((size_t)n, sizeof *f->books);
  for (int i = 0; i < n; i++) f->books[i] = ids[i];
  free(ids);
  char *now[NFIELDS];
  for (int i = 0; i < NFIELDS; i++) {
    char *err = NULL;
    now[i] = field_current(&t->app->db, f->books[0], field_names[i], &err);
    if (!now[i]) {
      free(err);
      now[i] = xstrdup("");
    }
  }
  struct panel *p = panel_open(t, 0.45f, 'b');
  char title[128];
  if (n == 1) snprintf(title, sizeof title, "edit book %lld   lists take +a, -b", f->books[0]);
  else snprintf(title, sizeof title, "edit %d books (the values shown are the first's)   lists take +a, -b", n);
  panel_set_title(p, title);
  panel_set_form(p, FORM_STAGED);
  panel_set_fields(p, NFIELDS, field_names, field_names, (const char *const *)now, NULL);
  for (int i = 0; i < NFIELDS; i++) free(now[i]);
  panel_set_dialog(p, 1);
  panel_on_event(p, on_event, f);
  panel_set_cursor(p, 0);
}

/* The last change lulibre made that is not undone, nor itself an undo, nor
 * a review decision that changed nothing. */
static void c_undo(struct tui *t, const char *args) {
  sqlite3_stmt *st;
  char *err = NULL;
  long long batch = 0;
  if (db_prepare(&t->app->db,
                 "SELECT max(batch) FROM history.journal WHERE state = 2 AND undoes IS NULL AND field IS NOT NULL AND store NOT IN ('review', 'outside')",
                 &st, &err) == 0) {
    if (sqlite3_step(st) == SQLITE_ROW) batch = sqlite3_column_int64(st, 0);
    sqlite3_finalize(st);
  } else {
    free(err);
    err = NULL;
  }
  if (!batch) {
    tui_msg(t, 0, "nothing to undo");
    return;
  }
  /* removed books come back through Lua: from calibre's recycle bin */
  int removed = 0;
  if (db_prepare(&t->app->db, "SELECT EXISTS(SELECT 1 FROM history.journal WHERE batch = ? AND state = 2 AND field = '(removed)')",
                 &st, &err) == 0) {
    sqlite3_bind_int64(st, 1, batch);
    if (sqlite3_step(st) == SQLITE_ROW) removed = sqlite3_column_int(st, 0);
    sqlite3_finalize(st);
  } else {
    free(err);
    err = NULL;
  }
  if (removed) {
    char *line = xasprintf("restore-removed %lld", batch);
    tui_exec(t, line);
    free(line);
    return;
  }
  struct job *j = job_new(t->app);
  j->undo = batch;
  queue_post(LOOP_WORK, to_library, j);
}

void edit_commands(void) {
  command_register("edit", c_edit, "the selection's fields, in a form: change them, then w writes");
  command_register("undo", c_undo, "put the last change back");
}
