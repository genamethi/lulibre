# lulibre -- run ./configure first; `make help` lists the targets.

ifeq ($(wildcard config.mk),)
ifeq ($(filter help distclean,$(MAKECMDGOALS)),)
$(error config.mk not found -- run ./configure)
endif
endif
-include config.mk

BIN  := build/lulibre
SRC  := $(wildcard src/*.c src/*/*.c)
OBJ  := $(SRC:%.c=build/%.o)
LUA  := $(shell find lua scripts -name '*.lua' 2>/dev/null)
# everything but main(), for the C unit tests to link against
LIBOBJ := $(filter-out build/src/main.o,$(OBJ))
UNIT := build/test/unit

WARN     := -Wall -Wextra -Wno-unused-parameter
CPPFLAGS += -D_GNU_SOURCE -I. -Isrc
ALL_CFLAGS := -std=c11 $(WARN) $(CFLAGS) $(DEP_CFLAGS)

all: $(BIN)
	@sh tools/build-status.sh $(BIN) $(VERSION) $(BINDIR)

help:
	@echo "lulibre $(or $(VERSION),(not configured yet: run ./configure)) $(if $(BUILD),($(BUILD) build) )-- targets:"
	@echo
	@echo "  make                 build build/lulibre, then say what was built and how it"
	@echo "                       compares with the lulibre on PATH (version and md5)"
	@echo "  make status          only that comparison"
	@echo
	@echo "  make check           unit tests and the quick end-to-end test (no calibre needed)"
	@echo "  make unit            unit tests: C (build/test/unit) and Lua (test/units.lua)"
	@echo "  make e2e             every end-to-end test: the interface, an install into a"
	@echo "                       stage, writes without and with a content server"
	@echo "  make check-offline   only: writes straight to a library (needs calibre, unshare)"
	@echo "  make check-write     only: writes through a content server (the same needs)"
	@echo
	@echo "  make install         install under PREFIX ($(PREFIX)); DESTDIR=dir stages it"
	@echo "  make uninstall       remove what install put there"
	@echo
	@echo "  make clean           remove what make built; keeps the configuration"
	@echo "  make distclean       also remove what ./configure wrote: back to a bare source tree"
	@echo
	@echo "  ./configure --help   prefix, --debug (symbols, no optimisation, trace in the"
	@echo "                       log console), --sanitize=address,undefined | thread"
	@echo "  The version is written once, in src/version.h."

# configure's results go stale when the version or configure itself changes;
# make runs it again the way it was last run, then starts over.
ifeq ($(filter help distclean,$(MAKECMDGOALS)),)
config.mk: configure src/version.h
	@if [ -x ./config.status ]; then echo "re-running configure"; ./config.status >/dev/null; \
	 else echo "run ./configure"; exit 1; fi
endif

$(BIN): $(OBJ)
	$(CC) -o $@ $(OBJ) $(LDFLAGS) -rdynamic $(DEP_LIBS) -lm -ldl

build/%.o: %.c config.h
	@mkdir -p $(dir $@)
	$(CC) $(CPPFLAGS) $(ALL_CFLAGS) -MMD -MP -c -o $@ $<

config.h: config.mk

-include $(OBJ:.o=.d)

status: $(BIN)
	@sh tools/build-status.sh $(BIN) $(VERSION) $(BINDIR)

# ---- tests ----

$(UNIT): test/unit.c $(LIBOBJ)
	@mkdir -p $(dir $@)
	$(CC) $(CPPFLAGS) $(ALL_CFLAGS) -o $@ test/unit.c $(LIBOBJ) $(LDFLAGS) -rdynamic $(DEP_LIBS) -lm -ldl

unit: $(BIN) $(UNIT)
	$(UNIT)
	sh test/units.sh $(BIN)

check: unit
	sh test/smoke.sh $(BIN)

check-offline: $(BIN)
	sh test/offline.sh $(BIN)

check-write: $(BIN)
	sh test/write.sh $(BIN)

e2e: $(BIN)
	sh test/smoke.sh $(BIN)
	sh test/install.sh $(BIN) $(VERSION)
	sh test/offline.sh $(BIN)
	sh test/write.sh $(BIN)

# ---- installing ----

install: $(BIN)
	install -d $(DESTDIR)$(BINDIR) $(DESTDIR)$(DATADIR)/lulibre
	install -m 755 $(BIN) $(DESTDIR)$(BINDIR)/lulibre
	@for f in $(LUA); do \
	  install -D -m 644 $$f $(DESTDIR)$(DATADIR)/lulibre/$$f || exit 1; \
	done
	@echo "installed lulibre $(VERSION) ($(BUILD)) in $(DESTDIR)$(BINDIR)"

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/lulibre
	rm -rf $(DESTDIR)$(DATADIR)/lulibre

# ---- cleaning ----

# what make built, nothing else: the next make rebuilds without ./configure
clean:
	rm -rf build/src build/test $(BIN)

# what ./configure wrote as well
distclean:
	rm -rf build config.mk config.h config.status

.PHONY: all help status unit check check-offline check-write e2e install uninstall clean distclean
