#include "core/registry.h"

#include <stdatomic.h>

static atomic_int filled[REG_KINDS];

int registry_lua(enum registry_kind kind) {
  return atomic_load(&filled[kind]);
}

void registry_set_lua(enum registry_kind kind, int on) {
  atomic_store(&filled[kind], on);
}

void registry_clear_lua(void) {
  for (int i = 0; i < REG_KINDS; i++) atomic_store(&filled[i], 0);
}
