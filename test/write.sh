#!/bin/sh
# The write path against throwaway calibre libraries, inside a private
# network namespace (unshare -rn), where calibre's lock and server are the
# test's own: changes straight to the library folder, the journal, undo,
# and through a content server with embedding. Needs calibre and unshare.
#   write.sh BUILT_BINARY
set -eu

bin=$(realpath "$1")
src=$(cd "$(dirname "$0")" && pwd)
command -v calibredb >/dev/null || { echo "write: calibredb not found, skipping"; exit 0; }
command -v unshare >/dev/null || { echo "write: unshare not found, skipping"; exit 0; }
unshare -rn true 2>/dev/null || { echo "write: no private namespace (unshare -rn), skipping"; exit 0; }

t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT

cat > "$t/apply.lua" <<'LUA'
local library = require "lulibre.library"
local function say(...) print(table.concat({ ... }, "|")) end
local batch, err = library.apply({
  { book = 1, field = "title", value = "Topics in Additive Combinatorics", proposal = 7,
    proposed = "Topics in Additive Combinatorics", source = "front" },
  { book = 1, field = "authors", value = "Terence Tao & Van Vu" },
  { book = 1, field = "tags", value = "math", op = "add" },
  { book = 1, field = "pubdate", value = "2006" },
  { book = 1, field = "#partof", value = "Cambridge Studies" },
}, "a test")
say("apply", tostring(batch), tostring(err))
local b = lulibre.book(1)
say("record", b.title, b.author, table.concat(b.tags, ","), b.pubdate)
say("same", tostring(library.apply({ { book = 1, field = "title", value = "Topics in Additive Combinatorics" } })))
say("bad", select(2, library.apply({ { book = 1, field = "pubdate", value = "soon" } })))
local r = lulibre.sql("SELECT proposal, source FROM history.journal WHERE field = 'title'")[1]
say("provenance", r.proposal, r.source)
say("undo", tostring(library.undo(batch)))
b = lulibre.book(1)
say("after undo", b.title, b.author)
say("undone", lulibre.sql("SELECT count(*) AS n FROM history.journal WHERE batch = ? AND state = 4", batch)[1].n)
LUA

cat > "$t/embed.lua" <<'LUA'
local library = require "lulibre.library"
setman.set("embed", true)
print("holder|" .. library.holder())
print("apply|" .. tostring(library.apply({ { book = 1, field = "title", value = "Embedded Title" } })))
local f = lulibre.sql("SELECT emb_title FROM files WHERE book = 1")[1]
print("emb|" .. tostring(f and f.emb_title))
LUA

cat > "$t/inside.sh" <<'IN'
#!/bin/sh
# inside the namespace: $1 the folder, $2 the binary, $3 a PDF
t=$1; bin=$2; pdf=$3
export XDG_CONFIG_HOME=$t/config XDG_DATA_HOME=$t/data XDG_STATE_HOME=$t/state HOME=$t
mkdir -p "$t/lib"
calibredb --with-library "$t/lib" add --empty --title paper --authors Unknown >/dev/null 2>&1
"$bin" -L "$t/lib" run "$t/apply.lua" 2>&1
echo "calibre|$(calibredb --with-library "$t/lib" list --fields title --for-machine 2>/dev/null | tr -d '\n ' )"
rm -rf "$t/lib" "$t/data" "$t/state"
mkdir -p "$t/lib"
calibredb --with-library "$t/lib" add "$pdf" >/dev/null 2>&1
"$bin" -L "$t/lib" index >/dev/null 2>&1
ip link set lo up 2>/dev/null || true
calibre-server --port 8099 --disable-use-bonjour --enable-local-write "$t/lib" >"$t/server.log" 2>&1 &
pid=$!
i=0
while [ $i -lt 60 ] && ! grep -q 'calibre-singleinstance' /proc/net/unix 2>/dev/null; do sleep 0.5; i=$((i + 1)); done
sleep 1
"$bin" -L "$t/lib" -o server=http://127.0.0.1:8099 run "$t/embed.lua" 2>&1
kill $pid; wait $pid 2>/dev/null || true
IN

# a PDF with a text layer for embedding to write into
sh "$src/mklib.sh" "$t/seed" >/dev/null 2>&1
out=$(unshare -rn sh "$t/inside.sh" "$t" "$bin" "$t/seed/Unknown/paper (1)/paper - Unknown.pdf")

fails=0
expect() { # description, expected line
  case "$out" in *"$2"*) echo "ok    $1" ;; *) echo "FAIL  $1: '$2' not in:"; echo "$out" | sed 's/^/      /'; fails=$((fails + 1)) ;; esac
}
expect "changes apply straight to the library folder, as one batch" "apply|1|nil"
expect "the record has them" "record|Topics in Additive Combinatorics|Terence Tao & Van Vu|math|2006-01-01"
expect "a change to the value held is no batch" "same|nil"
expect "a malformed value is refused before the journal" "bad|a date is written YYYY or YYYY-MM-DD"
expect "the journal keeps where a value came from" "provenance|7|front"
expect "undo is a batch of its own" "undo|2"
expect "and puts the old values back" "after undo|paper|Unknown"
expect "the batch put back is undone, all five rows" "undone|5"
expect "the content server is seen to hold the library" "holder|server"
expect "a change goes through the server" "apply|1"
expect "embedding updates what the index knows of the file" "emb|Embedded Title"
[ $fails -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
