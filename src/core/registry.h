#ifndef LULIBRE_REGISTRY_H
#define LULIBRE_REGISTRY_H

/* Replaceable parts (design 48).
 *
 * A named entry has C's own implementation; Lua may register a function in
 * its place, and unregister the function again. A call to an entry Lua has
 * filled goes by the queue to the Lua thread, and the answer comes back the
 * same way. With no lua_State up (during :restart-scripts), the call waits
 * in the queue. C never calls Lua and waits. */

struct app;

enum registry_kind {
  REG_STORE,  /* where a change is written (design 28): args is a struct operation */
  REG_READER, /* how a file's page images become text (design 37): args is a struct ocr_job */
};

typedef void registry_done(void *result, const char *err, void *ud);
typedef void registry_fn(struct app *app, void *args, registry_done *done, void *ud);

/* C's own implementation of an entry. */
void registry_add(enum registry_kind kind, const char *name, registry_fn *fn);

/* A Lua function in the entry's place (a reference in the lua_State's
 * registry); LUA_NOREF puts C's own back. */
void registry_set_lua(struct app *app, enum registry_kind kind, const char *name, int ref);

/* Calls the entry; done fires on the calling thread's loop. */
void registry_call(struct app *app, enum registry_kind kind, const char *name, void *args, registry_done *done,
                   void *ud);

#endif
