#!/bin/sh
# The Lua unit checks (test/units.lua): the runtime modules and the API, run
# headless against a small generated library. Touches nothing outside a
# temporary directory.
set -eu

bin=$(realpath "$1")
src=$(cd "$(dirname "$0")" && pwd)
command -v sqlite3 >/dev/null || { echo "units: sqlite3 CLI not found, skipping"; exit 0; }

t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
sh "$src/mklib.sh" "$t/lib"
export XDG_DATA_HOME="$t/data" XDG_CONFIG_HOME="$t/config"
# units.lua runs only on this library (it writes to the index)
export LULIBRE_UNITS_LIBRARY="$t/lib"

"$bin" --clean -L "$t/lib" index >/dev/null 2>&1
out=$("$bin" --clean -L "$t/lib" run "$src/units.lua" 2>&1) || { echo "$out" | tail -20; exit 1; }
echo "Lua unit checks: $(echo "$out" | tail -1)"
case $out in *", 0 failed"*) ;; *) echo "$out" | grep -A3 FAIL; exit 1 ;; esac
# luv must belong to the main Lua state, not to whichever task loaded it
if "$bin" --clean -L "$t/lib" run "$src/luv_probe.lua" >/dev/null 2>&1; then
  out=$("$bin" --clean -L "$t/lib" run "$src/luv_state.lua" 2>&1) || { echo "FAIL  luv callback after its first user ended: $out"; exit 1; }
  case $out in *"callback fired: true"*) echo "ok    a luv callback outlives the task that loaded luv" ;; *) echo "FAIL  $out"; exit 1 ;; esac
else
  echo "skip  luv checks (luv is not installed for this Lua version)"
fi
# your own files used in place of lulibre's (lulibre.overrides): said once,
# in the log, and not of a file of yours that replaces nothing
mkdir -p "$t/cfg/lua/lulibre" "$t/cfg/scripts"
echo 'return {}' > "$t/cfg/lua/lulibre/junk.lua"
echo 'print("mine")' > "$t/cfg/scripts/offline.lua"
echo 'print("mine")' > "$t/cfg/scripts/only-mine.lua"
echo 'print("ran")' > "$t/p.lua"
first=$("$bin" -C "$t/cfg" -L "$t/lib" run "$t/p.lua" 2>&1)
again=$("$bin" -C "$t/cfg" -L "$t/lib" run "$t/p.lua" 2>&1)
case $first in *"your module lulibre.junk"*"your script offline"*) echo "ok    a file of yours used in place of lulibre's is said" ;;
  *) echo "FAIL  overrides not said: $first"; exit 1 ;; esac
case $first in *only-mine*) echo "FAIL  a script of yours alone was said: $first"; exit 1 ;; esac
[ "$again" = "ran" ] && echo "ok    and said once" || { echo "FAIL  said again: $again"; exit 1; }
