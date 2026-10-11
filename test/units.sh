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
