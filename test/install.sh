#!/bin/sh
# End to end: the version and the install.
#   install.sh BUILT_BINARY VERSION
# Checks that the binary reports the version configure recorded from
# src/version.h, that the Lua API reports the same, and that a staged
# `make install` puts a working lulibre, its runtime and its scripts under
# DESTDIR, where `make uninstall` finds them again. Touches nothing outside
# a temporary directory.
set -eu

bin=$(realpath "$1")
want=$2
src=$(cd "$(dirname "$0")/.." && pwd)
command -v sqlite3 >/dev/null || { echo "install: sqlite3 CLI not found, skipping"; exit 0; }

t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
export XDG_DATA_HOME="$t/data" XDG_CONFIG_HOME="$t/config"

fails=0
expect() { # description, expected, actual
  if [ "$2" = "$3" ]; then echo "ok    $1"; else echo "FAIL  $1: expected '$2', got '$3'"; fails=$((fails + 1)); fi
}
contains() { # description, needle, haystack
  case $3 in *"$2"*) echo "ok    $1" ;; *) echo "FAIL  $1: '$2' not in: $3"; fails=$((fails + 1)) ;; esac
}

# ---- one version, everywhere
header=$(sed -n 's/^#define LULIBRE_VERSION_\(MAJOR\|MINOR\|PATCH\) \([0-9]*\).*/\2/p' "$src/src/version.h" | paste -sd. -)
pre=$(sed -n 's/^#define LULIBRE_VERSION_PRE "\(.*\)".*/\1/p' "$src/src/version.h")
expect   "configure recorded the header's version" "$header$pre" "$want"
expect   "lulibre -V reports it"            "$want" "$("$bin" -V | cut -d' ' -f2)"
contains "-V names the kind of build"       " build " "$("$bin" -V)"
number=$("$bin" -V | sed -n 's/.* build \([0-9][0-9]*\), Lua.*/\1/p')
expect   "and its number, as the build log has it" "$number" "$(sh "$src/tools/build-number.sh" "$want" --log | cut -d' ' -f1 | grep -x "$number" | head -1)"
printf 'print(lulibre.version, lulibre.build.version, lulibre.build.major .. "." .. lulibre.build.minor .. "." .. lulibre.build.patch, lulibre.build.pre)\n' > "$t/v.lua"
sh "$src/test/mklib.sh" "$t/lib"
api=$("$bin" --clean -L "$t/lib" run "$t/v.lua" 2>&1)
expect   "the Lua API reports it"           "$want	$want	${header}	${pre#-}" "$api"
printf 'print(type(lulibre.build.debug), lulibre.build.lua)\n' > "$t/v.lua"
contains "and the build"                    "boolean	5." "$("$bin" --clean -L "$t/lib" run "$t/v.lua" 2>&1)"
grep -q 'LULIBRE_VERSION' "$src/config.h" && r=yes || r=no
expect   "the version is written in one place only" no "$r"

# ---- a staged install
stage=$t/stage
make -C "$src" --no-print-directory DESTDIR="$stage" install >"$t/install.log" 2>&1 || { cat "$t/install.log"; exit 1; }
installed=$(find "$stage" -type f -name lulibre -perm -u+x | head -1)
expect   "install puts a binary under DESTDIR" yes "$([ -n "$installed" ] && echo yes || echo no)"
expect   "the installed binary is this build" "$(md5sum < "$bin")" "$(md5sum < "$installed")"
expect   "the guides are installed, for :help" yes "$([ -n "$(find "$stage" -type f -path '*/lulibre/docs/workflows.md' | head -1)" ] && echo yes || echo no)"
expect   "and the man page"                 yes "$([ -n "$(find "$stage" -type f -path '*/man/man1/lulibre.1' | head -1)" ] && echo yes || echo no)"
expect   "and runs"                         "$want" "$("$installed" -V | cut -d' ' -f2)"
data=$(dirname "$(find "$stage" -type f -path '*/lulibre/lua/lulibre/prelude.lua' | head -1)")
expect   "the runtime is installed"         yes "$([ -f "$data/prelude.lua" ] && echo yes || echo no)"
expect   "every Lua module is installed"    "$(find "$src/lua" -name '*.lua' | wc -l)" "$(find "$stage" -path '*/lulibre/lua/*' -name '*.lua' | wc -l)"
expect   "every script is installed"        "$(find "$src/scripts" -name '*.lua' | wc -l)" "$(find "$stage" -path '*/lulibre/scripts/*' -name '*.lua' | wc -l)"
opf=$(find "$stage" -type f -path '*/lulibre/contrib/calibre-server-opf.py' | head -1)
expect   "calibre's server launcher is installed" yes "$([ -n "$opf" ] && echo yes || echo no)"
unit=$(find "$stage" -type f -path '*/lulibre/systemd/calibre-server.service' | head -1)
contains "and calibre's unit, pointing at where it is installed" "-e ${opf#$stage}" "$(cat "$unit" 2>/dev/null)"
contains "lulibre.service names the installed binary" "ExecStart=$(dirname "${installed#$stage}")/lulibre offline" "$(cat "$(find "$stage" -type f -path '*/lulibre/systemd/lulibre.service' | head -1)" 2>/dev/null)"
# the installed binary with the installed runtime (LULIBRE_RUNTIME says where,
# since the stage is not the prefix it was configured for)
rt=$(dirname "$data")
contains "the installed copy works on a library" "2" "$(LULIBRE_RUNTIME="$rt" "$installed" --clean -L "$t/lib" query -c '' 2>&1)"
printf 'print(#lulibre.ids(""), require("lulibre.edit") ~= nil)\n' > "$t/v.lua"
expect   "and loads its Lua runtime"        "2	true" "$(cd "$t" && LULIBRE_RUNTIME="$rt" "$installed" --clean -L "$t/lib" run "$t/v.lua" 2>&1)"
status=$(PATH="$(dirname "$installed"):$PATH" sh "$src/tools/build-status.sh" "$bin" "$want" /nowhere 2>&1)
contains "the build status finds it on PATH" "the same binary as this build" "$status"
printf '#!/bin/sh\necho "lulibre 0.0.1 (release build, Lua 5.5)"\n' > "$t/lulibre"
chmod +x "$t/lulibre"
contains "and notices another version there" "a different version (0.0.1" "$(PATH="$t:$PATH" sh "$src/tools/build-status.sh" "$bin" "$want" /nowhere 2>&1)"
contains "and a stale configure"            "run ./configure again" "$(sh "$src/tools/build-status.sh" "$bin" 9.9.9 /nowhere 2>&1)"

make -C "$src" --no-print-directory DESTDIR="$stage" uninstall >/dev/null 2>&1
expect   "uninstall removes it all"         0 "$(find "$stage" -type f | wc -l)"

missing=
for doc in $(sed -n 's/.*](\(docs\/[a-z]*\.md\)).*/\1/p' "$src/README.md"); do
  [ -f "$src/$doc" ] || missing="$missing $doc"
done
expect   "every page the README links exists" "" "$missing"
contains "make help lists the targets"      "make distclean" "$(make -C "$src" --no-print-directory help 2>&1)"

[ $fails -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
