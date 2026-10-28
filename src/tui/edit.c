/* The edit form and undo (design 31, 32): editing works in C, with no Lua.
 *
 * :edit opens a form on the selection (the book under the cursor, or the
 * marked books): a row per field with the value it has (the first book's,
 * when there are several) and the value it is to get. Enter or e edits a
 * row's value; for a list field, "+a, -b" adds a and takes b out and keeps
 * the rest. x drops a row's change, w writes them all as one operation of
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
  struct panel *p;
  long long *books;
  int nbooks;
  char *now[NFIELDS];     /* the first book's values */
  char *pending[NFIELDS]; /* as typed; NULL: no change */
  int editing;            /* the row being typed, or -1 */
};

static void form_free(struct form *f) {
  for (int i = 0; i < NFIELDS; i++) {
    free(f->now[i]);
    free(f->pending[i]);
  }
  free(f->books);
  free(f);
}

static void show(struct form *f) {
  int cur = panel_cursor(f->p);
  panel_clear_rows(f->p);
  for (int i = 0; i < NFIELDS; i++) {
    const char *cells[] = {field_names[i], f->now[i], f->pending[i] ? (*f->pending[i] ? f->pending[i] : "(blank)") : ""};
    panel_add_row(f->p, 3, cells, f->books[0], f->pending[i] ? PSTYLE_ACCENT : PSTYLE_NORMAL);
  }
  panel_set_cursor(f->p, cur < 0 ? 0 : cur);
}

static void typed(struct tui *t, const char *text, void *ud) {
  struct form *f = ud;
  int i = f->editing;
  f->editing = -1;
  if (!text || i < 0 || !panel_is_open(f->p)) return;
  free(f->pending[i]);
  f->pending[i] = xstrdup(text);
  show(f);
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

static void write_form(struct form *f) {
  enum { PER = 64 };
  struct change *ch = xcalloc((size_t)f->nbooks * NFIELDS * PER, sizeof *ch);
  int n = 0;
  for (int b = 0; b < f->nbooks; b++)
    for (int i = 0; i < NFIELDS; i++) {
      if (!f->pending[i]) continue;
      n += changes_of(field_names[i], f->pending[i], f->books[b], ch + n, PER);
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
  panel_close(f->p);
}

static void on_key(struct panel *p, const char *key, int row, void *ud) {
  struct form *f = ud;
  if (!key) { /* closed */
    if (f->editing >= 0) tui_input_cancel(f->t);
    panel_unref(p);
    form_free(f);
    return;
  }
  if (row < 0 || row >= NFIELDS) return;
  if (!strcmp(key, "<CR>") || !strcmp(key, "e")) {
    f->editing = row;
    char label[48];
    snprintf(label, sizeof label, "%s: ", field_names[row]);
    tui_input(f->t, label, f->pending[row] ? f->pending[row] : f->now[row], typed, f);
  } else if (!strcmp(key, "x")) {
    free(f->pending[row]);
    f->pending[row] = NULL;
    show(f);
  } else if (!strcmp(key, "w")) {
    write_form(f);
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
  f->editing = -1;
  f->nbooks = n;
  f->books = xcalloc((size_t)n, sizeof *f->books);
  for (int i = 0; i < n; i++) f->books[i] = ids[i];
  free(ids);
  for (int i = 0; i < NFIELDS; i++) {
    char *err = NULL;
    f->now[i] = field_current(&t->app->db, f->books[0], field_names[i], &err);
    if (!f->now[i]) {
      free(err);
      f->now[i] = xstrdup("");
    }
  }
  f->p = panel_open(t, 0.45f, 'b');
  char title[96];
  if (n == 1) snprintf(title, sizeof title, "edit book %lld", f->books[0]);
  else snprintf(title, sizeof title, "edit %d books (the values shown are the first's)", n);
  panel_set_title(f->p, title);
  panel_set_help(f->p, "<CR>/e edit  x drop the change  w write  q close  (lists: +a, -b)");
  const char *titles[] = {"Field", "Now", "To be"};
  int widths[] = {14, 0, 0};
  panel_set_columns(f->p, 3, titles, widths);
  uint32_t own[4], k[KEYSEQ_MAX];
  int nown = 0;
  const char *keys[] = {"<CR>", "e", "x", "w"};
  for (int i = 0; i < 4; i++)
    if (key_parse(keys[i], k) == 1) own[nown++] = k[0];
  panel_set_own(f->p, nown, own);
  panel_set_dialog(f->p, 1);
  panel_on_event(f->p, on_key, f);
  show(f);
}

/* The last change lulibre made that is not undone, nor itself an undo, nor
 * a review decision that changed nothing. */
static void c_undo(struct tui *t, const char *args) {
  sqlite3_stmt *st;
  char *err = NULL;
  long long batch = 0;
  if (db_prepare(&t->app->db,
                 "SELECT max(batch) FROM history.journal WHERE state = 2 AND undoes IS NULL AND store <> 'review'",
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
  struct job *j = job_new(t->app);
  j->undo = batch;
  queue_post(LOOP_WORK, to_library, j);
}

void edit_commands(void) {
  command_register("edit", c_edit, "the selection's fields, in a form: change them, then w writes");
  command_register("undo", c_undo, "put the last change back");
}
