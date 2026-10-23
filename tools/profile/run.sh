#!/bin/sh
# Profiles lulibre's headless commands against a calibre library, which is
# only read. Every step writes to a copy of the index in OUT, never to the
# library or to the index lulibre normally uses.
#
#   tools/profile/run.sh [-p time|perf|callgrind|massif] [-i INDEX] LIBRARY OUT [STEP...]
#
# -p: the profiler (time by default: wall, user and system time, peak RSS).
# -i: an existing index to copy instead of indexing from scratch.
# STEP: index query stats dupes orphans grammars refs propose verify census
# (all of them by default, in that order). BIN selects the binary; the
# default is the frame-pointer build libs.sh makes, else build/lulibre. libs.sh builds Lua, SQLite and MuPDF with debug
# info into build/profile-cache/lib, which run.sh then loads.
set -eu

prof=time index_from=
while getopts p:i: o; do
  case $o in
    p) prof=$OPTARG ;;
    i) index_from=$OPTARG ;;
    *) exit 2 ;;
  esac
done
shift $((OPTIND - 1))
[ $# -ge 2 ] || { sed -n '5,13p' "$0"; exit 2; }
lib=$(realpath "$1") out=$2
shift 2
steps=${*:-index query stats dupes orphans grammars refs propose verify census}
# the frame-pointer build libs.sh makes, else the tree's
fp=$(cd "$(dirname "$0")/../.." && pwd)/build/profile-cache/lulibre/build/lulibre
[ -n "${BIN:-}" ] || { [ -x "$fp" ] && BIN=$fp || BIN=build/lulibre; }
bin=$(realpath "$BIN")
here=$(cd "$(dirname "$0")" && pwd)
cache=$(cd "$here/../.." && pwd)/build/profile-cache
export DEBUGINFOD_CACHE_PATH="${DEBUGINFOD_CACHE_PATH:-$cache/debuginfod}" PERF_BUILDID_DIR="${PERF_BUILDID_DIR:-$cache/perf}"
# Lua, SQLite and MuPDF with debug info, when libs.sh has built them
[ -d "$cache/lib" ] && export LD_LIBRARY_PATH="$cache/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

mkdir -p "$out/home"
out=$(realpath "$out")
export HOME="$out/home" XDG_DATA_HOME="$out/home/data" XDG_CONFIG_HOME="$out/home/config" XDG_STATE_HOME="$out/home/state"
idx="$out/index.db"
if [ -n "$index_from" ] && [ ! -e "$idx" ]; then
  sqlite3 "file:$(realpath "$index_from")?mode=ro" ".backup '$idx'"
fi
lu() { "$bin" --clean -L "$lib" -o index="$idx" "$@"; }

args() {
  case $1 in
    index) echo "index --force" ;;
    query) echo "run $here/queries.lua" ;;
    stats) echo "stats" ;;
    dupes) echo "run dupes" ;;
    orphans) echo "run orphans" ;;
    grammars) echo "run grammars" ;;
    refs) echo "run refs all" ;;
    propose) echo "run propose in:library" ;;
    verify) echo "run verify" ;;
    census) echo "run $here/census.lua" ;;
    *) echo "unknown step: $1" >&2; exit 2 ;;
  esac
}

for step in $steps; do
  set -- $(args "$step")
  echo "==> $step ($prof)"
  case $prof in
    time)
      python3 -I "$here/rusage.py" "$out/$step.time" "$bin" --clean -L "$lib" -o index="$idx" "$@" >"$out/$step.out" 2>&1
      cat "$out/$step.time" ;;
    perf)
      perf record -q --debuginfod -F 999 --call-graph fp -o "$out/$step.perf.data" -- \
        "$bin" --clean -L "$lib" -o index="$idx" "$@" >"$out/$step.out" 2>&1
      perf report -q -i "$out/$step.perf.data" --stdio --no-children --percent-limit 0.5 -g none \
        >"$out/$step.self.txt" 2>/dev/null
      perf report -q -i "$out/$step.perf.data" --stdio --children --percent-limit 2 -g caller,0.5,callee \
        >"$out/$step.tree.txt" 2>/dev/null
      head -n 25 "$out/$step.self.txt" ;;
    callgrind)
      valgrind -q --tool=callgrind --callgrind-out-file="$out/$step.callgrind" \
        "$bin" --clean -L "$lib" -o index="$idx" "$@" >"$out/$step.out" 2>&1
      callgrind_annotate "$out/$step.callgrind" >"$out/$step.callgrind.txt"
      head -n 40 "$out/$step.callgrind.txt" ;;
    massif)
      valgrind -q --tool=massif --massif-out-file="$out/$step.massif" \
        "$bin" --clean -L "$lib" -o index="$idx" "$@" >"$out/$step.out" 2>&1
      ms_print "$out/$step.massif" >"$out/$step.massif.txt"
      head -n 45 "$out/$step.massif.txt" ;;
    *) echo "unknown profiler: $prof" >&2; exit 2 ;;
  esac
done
