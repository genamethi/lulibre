#ifndef LULIBRE_FIELDS_H
#define LULIBRE_FIELDS_H

/* The write core's values (design 31): a field's current value, the value
 * a change makes of it, and calibredb's spelling of a value.
 *
 * A value is text in one form everywhere: a list field's items joined by
 * its separator (authors " & ", the others ", "), tags, identifiers and
 * languages sorted, identifiers "type:value", a date YYYY-MM-DD. A field
 * of lulibre's own is "#name", kept in the custom database. */

#include "library/library.h"

struct db;

/* calibre's fields a change can name, in the order forms show them;
 * NULL-terminated. */
extern const char *const field_names[];

int field_known(const char *field);    /* one of field_names, or "#name" */
int field_is_list(const char *field);  /* authors, tags, identifiers, languages, "#..." */
int field_is_own(const char *field);   /* "#name": lulibre's own */

/* The book's current value of field, from the index's copy of the records
 * (or the custom database): malloc'd, "" when it has none; NULL and *err
 * when the book or field is unknown. An unknown author is "", and so is a
 * series index without a series. identifier:TYPE is one identifier's
 * value, without its type. */
char *field_current(struct db *db, long long book, const char *field, char **err);

/* The value after a change: set replaces it; add and remove keep a list's
 * other items (an identifier is added or removed by its type). malloc'd,
 * or NULL and *err (a date that is not YYYY or YYYY-MM-DD, an identifier
 * without its type, add or remove on a field of one value). */
char *field_resolve(const char *field, enum change_op op, const char *current, const char *value, char **err);

/* calibredb's spelling of a value, for set_metadata --field; malloc'd. */
char *field_wire(const char *field, const char *value);

#endif
