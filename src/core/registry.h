#ifndef LULIBRE_REGISTRY_H
#define LULIBRE_REGISTRY_H

/* Replaceable parts (design 48).
 *
 * An entry is a part C does with its own code unless Lua has put a
 * function in its place. Lua does so the way it overrides anything
 * (design 6): by redefining the function in the packaged module that
 * stands for the entry (lulibre.ocr.read for the OCR reader). C then calls
 * the entry by the queue: the module's function runs as a task on the Lua
 * thread, through the module's table at the time of the call, and the
 * answer comes back as a message. C never calls Lua and waits. */

enum registry_kind {
  REG_READER, /* how a file's page images become text (design 37): lulibre.ocr.read */
  REG_STORE,  /* how a book's changes reach calibre (design 28): lulibre.stores.calibre */
  REG_KINDS
};

/* Whether Lua has put a function in the entry's place. Any thread. */
int registry_lua(enum registry_kind kind);
/* The Lua thread, as the module's function is set or cleared; every entry
 * goes back to C's own when the lua_State is torn down. */
void registry_set_lua(enum registry_kind kind, int on);
void registry_clear_lua(void);

#endif
