# lulibre -- run ./configure first; `make help` lists the targets.

ifeq ($(wildcard config.mk),)
ifeq ($(filter help distclean,$(MAKECMDGOALS)),)
$(error config.mk not found -- run ./configure)
endif
endif
-include config.mk

BIN  := build/lulibre
SRC  := $(filter-out src/setup/%,$(wildcard src/*.c src/*/*.c))
# libraries carried as their authors wrote them (vendor/*/README.md)
VENDOR := vendor/lsqlite3/lsqlite3.c
OBJ  := $(SRC:%.c=build/%.o) $(VENDOR:%.c=build/%.o)
LUA  := $(shell find lua scripts -name '*.lua' 2>/dev/null)
# the guides, which :help reads
DOCS := $(wildcard docs/*.md)
# everything but main(), for the C unit tests to link against
LIBOBJ := $(filter-out build/src/main.o,$(OBJ))
UNIT := build/test/unit
CORE := build/test/core
# lulibre-setup: its own sources, and the parts of lulibre's it shares (the
# drawing, the settings' definitions)
SETUP := build/lulibre-setup
SETUP_OBJ := $(patsubst %.c,build/%.o,$(wildcard src/setup/*.c)) \
  build/src/tui/draw.o build/src/match/fold.o build/src/core/util.o build/src/core/log.o \
  build/src/core/settings.o build/src/core/setdefs.o

WARN     := -Wall -Wextra -Wno-unused-parameter
CPPFLAGS += -D_GNU_SOURCE -I. -Isrc
ALL_CFLAGS := -std=c11 $(WARN) $(CFLAGS) $(DEP_CFLAGS)

all: $(BIN) $(SETUP)
	@sh tools/build-status.sh $(BIN) $(VERSION) $(BINDIR)

help:
	@echo "lulibre $(or $(VERSION),(not configured yet: run ./configure)) $(if $(BUILD),($(BUILD) build) )-- targets:"
	@echo
	@echo "  make                 build build/lulibre and build/lulibre-setup, then say what was"
	@echo "                       built and how it compares with the lulibre on PATH (version and md5)"
	@echo "  make status          only that comparison"
	@echo "  make builds          the log of builds: number, time, commit, branch, checkout"
	@echo
	@echo "  make check           unit tests and the setup test (no calibre needed)"
	@echo "  make unit            unit tests: C (build/test/unit, build/test/core)"
	@echo "  make e2e             every end-to-end test"
	@echo
	@echo "  make install         install under PREFIX ($(PREFIX)); DESTDIR=dir stages it"
	@echo "  make uninstall       remove what install put there"
	@echo "  make datasets        optional: fetch databases for looking books up offline"
	@echo "  make rocks           install the Lua rocks lulibre needs (LUA_VERSION, ROCKS to override)"
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

# Every build has a number (tools/build-number.sh): given here, when the
# binary is linked, which is whenever anything it is made of has changed.
# The Lua runtime and the bundled scripts count as part of it, so a change
# to them is a new build too, though the C is the same.
$(BIN): $(OBJ) $(LUA) tools/build-number.sh
	@mkdir -p build
	@set -e; b=$$(sh tools/build-number.sh $(VERSION)); \
	  printf 'const char lulibre_build_number[] = "%s";\nconst char lulibre_build_commit[] = "%s";\n' $${b%% *} $${b#* } > build/buildno.c; \
	  echo "build $${b%% *} of $(VERSION), from commit $${b#* }"
	$(CC) $(ALL_CFLAGS) -c -o build/buildno.o build/buildno.c
	$(CC) -o $@ $(OBJ) build/buildno.o $(LDFLAGS) -rdynamic $(DEP_LIBS) -lm -ldl

$(SETUP): $(SETUP_OBJ)
	$(CC) -o $@ $(SETUP_OBJ) $(LDFLAGS) $(DEP_LIBS) -lm

# the log of builds: number, time, version, commit, branch, checkout
builds:
	@sh tools/build-number.sh $(VERSION) --log

build/%.o: %.c config.h
	@mkdir -p $(dir $@)
	$(CC) $(CPPFLAGS) $(ALL_CFLAGS) -MMD -MP -c -o $@ $<

# their code, their warnings
build/vendor/lsqlite3/lsqlite3.o: vendor/lsqlite3/lsqlite3.c
	@mkdir -p $(dir $@)
	$(CC) -std=c11 -w $(CFLAGS) $(DEP_CFLAGS) -DLSQLITE_VERSION='"0.9.7"' -MMD -MP -c -o $@ $<

config.h: config.mk

-include $(OBJ:.o=.d) $(SETUP_OBJ:.o=.d)

status: $(BIN)
	@sh tools/build-status.sh $(BIN) $(VERSION) $(BINDIR)

# ---- tests ----

$(UNIT): test/unit.c $(LIBOBJ)
	@mkdir -p $(dir $@)
	$(CC) $(CPPFLAGS) $(ALL_CFLAGS) -o $@ test/unit.c $(LIBOBJ) $(LDFLAGS) -rdynamic $(DEP_LIBS) -lm -ldl

$(CORE): test/core.c $(LIBOBJ)
	@mkdir -p $(dir $@)
	$(CC) $(CPPFLAGS) $(ALL_CFLAGS) -o $@ test/core.c $(LIBOBJ) $(LDFLAGS) -rdynamic $(DEP_LIBS) -lm -ldl

unit: $(BIN) $(UNIT) $(CORE)
	$(UNIT)
	$(CORE)

check: unit $(SETUP)
	sh test/lint.sh
	sh test/runtime.sh $(BIN)
	sh test/net.sh $(BIN)
	sh test/curl.sh $(BIN)
	sh test/first.sh $(BIN)
	sh test/setup.sh $(BIN) $(SETUP)
	sh test/places.sh $(BIN)

e2e: $(BIN) $(SETUP)
	sh test/lint.sh
	sh test/runtime.sh $(BIN)
	sh test/net.sh $(BIN)
	sh test/curl.sh $(BIN)
	sh test/first.sh $(BIN)
	sh test/setup.sh $(BIN) $(SETUP)
	sh test/places.sh $(BIN)
	sh test/write.sh $(BIN)
	python3 -I test/tasks.py $(BIN)
	python3 -I test/screens.py $(BIN)

# ---- the API reference (LDoc: config.ld) ----

LDOC ?= ldoc
api:
	@command -v $(firstword $(LDOC)) >/dev/null || { echo "LDoc not found: luarocks --local install ldoc, or make api LDOC='lua path/to/ldoc.lua'"; exit 1; }
	rm -rf build/api
	$(LDOC) .
	@echo "the API reference is in build/api/index.html"

# ---- installing ----

install: $(BIN)
	install -d $(DESTDIR)$(BINDIR) $(DESTDIR)$(DATADIR)/lulibre
	install -m 755 $(BIN) $(DESTDIR)$(BINDIR)/lulibre
	@for f in $(LUA) $(DOCS); do \
	  install -D -m 644 $$f $(DESTDIR)$(DATADIR)/lulibre/$$f || exit 1; \
	done
	install -D -m 644 man/lulibre.1 $(DESTDIR)$(DATADIR)/man/man1/lulibre.1
	install -d $(DESTDIR)$(DATADIR)/lulibre/systemd
	sed -e 's|@DATADIR@|$(DATADIR)|g' contrib/calibre-server.service.in \
	  > $(DESTDIR)$(DATADIR)/lulibre/systemd/calibre-server.service
	install -D -m 644 contrib/calibre-server-opf.py $(DESTDIR)$(DATADIR)/lulibre/contrib/calibre-server-opf.py
	@for f in examples/grammars/*.lua; do \
	  install -D -m 644 $$f $(DESTDIR)$(DATADIR)/lulibre/$$f || exit 1; \
	done
	@echo "installed lulibre $(VERSION) ($(BUILD)) in $(DESTDIR)$(BINDIR)"
	@echo "optional: 'lulibre datasets' (or 'make datasets') fetches databases for looking books up offline; it can be run again whenever"

# the databases for looking books up offline: says what there is and asks
# which to fetch (into ~/.local/share/lulibre, never under the prefix)
datasets: $(BIN)
	$(BIN) datasets

# Installs lulibre-dev-1.rockspec's dependencies, built against the Lua
# headers ./configure pinned (build/lua-inc).
LUA_VERSION = $(LUA_VER)
ROCKS = --local
ROCKS_INCDIR = $(if $(and $(filter $(LUA_VER),$(LUA_VERSION)),$(wildcard build/lua-inc/lua.h)),LUA_INCDIR=$(CURDIR)/build/lua-inc)
rocks:
	luarocks $(ROCKS) --lua-version $(LUA_VERSION) install --deps-only lulibre-dev-1.rockspec $(ROCKS_INCDIR)

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/lulibre
	rm -rf $(DESTDIR)$(DATADIR)/lulibre
	rm -f $(DESTDIR)$(DATADIR)/man/man1/lulibre.1

# ---- cleaning ----

# what make built, nothing else: the next make rebuilds without ./configure
clean:
	rm -rf build/src build/test $(BIN)

# what ./configure wrote as well
distclean:
	rm -rf build config.mk config.h config.status

.PHONY: all help status builds api unit check e2e install datasets rocks uninstall clean distclean
