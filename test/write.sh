#!/bin/sh
# The write path against throwaway calibre libraries, inside a private
# network namespace (unshare -rn), where calibre's lock and server are the
# test's own: changes straight to the library folder, the journal, undo,
# and through a content server with embedding; calibre's records read
# again after calibre changes them. Needs calibre and unshare.
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
library.apply({ { book = 1, field = "tags", value = "x, y", op = "add" }, { book = 1, field = "tags", value = "x", op = "remove" } })
say("in order", table.concat(lulibre.book(1).tags, ","))
LUA

cat > "$t/embed.lua" <<'LUA'
local library = require "lulibre.library"
setman.set("embed", true)
print("holder|" .. library.holder())
print("apply|" .. tostring(library.apply({ { book = 1, field = "title", value = "Embedded Title" } })))
local f = lulibre.sql("SELECT emb_title FROM files WHERE book = 1")[1]
print("emb|" .. tostring(f and f.emb_title))
LUA

cat > "$t/review.lua" <<'LUA'
local proposals = require "lulibre.proposals"
local track = require "lulibre.track"
-- a parse of the scan, as the front grammar would give it, stored as proposals
lulibre.store("INSERT INTO proposals(id, book, field, value, parse, alt) VALUES"
  .. " (1, 1, 'title', 'Topics in Additive Combinatorics', 'front', 1),"
  .. " (2, 1, 'authors', 'Terence Tao & Van Vu', 'front', 1)")
print("accept|" .. tostring(proposals.accept(1)))
print("reject|" .. tostring(proposals.reject(2)))
local b = lulibre.book(1)
print("decided|" .. b.title .. "|" .. b.author .. "|" .. #proposals.of(1))
local r = lulibre.sql("SELECT store, field, proposal, source FROM history.journal WHERE batch = 2")[1]
print("rejection|" .. r.store .. "|" .. r.field .. "|" .. r.proposal .. "|" .. r.source)
local rec = track.records(1, 0.7, 0.95)
print(("track|%.3f|%.3f"):format(rec.front.title, rec.front.authors))
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
# calibre's records read again: only the books calibre changed, as a copy of
# every book would have them
(
  export XDG_DATA_HOME=$t/rr
  r=$t/rrlib
  mkdir -p "$r"
  for n in one two three; do calibredb --with-library "$r" add --empty --title $n --authors "A Author" >/dev/null 2>&1; done
  calibredb --with-library "$r" add_custom_column genre Genre text --is-multiple >/dev/null 2>&1
  "$bin" -L "$r" query -c >/dev/null 2>&1
  idx=$(ls "$t"/rr/lulibre/*.db | grep -v 'journal\|custom')
  sqlite3 "$idx" "UPDATE books SET sort = 'untouched' WHERE id = 3"
  calibredb --with-library "$r" set_metadata 1 -f title:Uno -f authors:"B Author & A Author" -f tags:x >/dev/null 2>&1
  calibredb --with-library "$r" set_custom genre 1 "poetry,history" >/dev/null 2>&1
  calibredb --with-library "$r" remove 2 >/dev/null 2>&1
  calibredb --with-library "$r" add --empty --title four --authors "C Author" >/dev/null 2>&1
  "$bin" -L "$r" query -c >/dev/null 2>&1
  echo "reread untouched|$(sqlite3 "$idx" "SELECT sort FROM books WHERE id = 3")"
  sqlite3 "$idx" "UPDATE books SET sort = 'three' WHERE id = 3"
  dump() {
    for q in "SELECT * FROM books" "SELECT * FROM book_authors ORDER BY book, ord" "SELECT * FROM authors" \
      "SELECT * FROM tags" "SELECT * FROM book_tags ORDER BY book, tag" "SELECT rowid, * FROM books_fts ORDER BY rowid" \
      "SELECT * FROM cal_values ORDER BY book, ord"; do sqlite3 "$idx" "$q"; done
  }
  dump >"$t/rr/changed"
  sqlite3 "$idx" "DELETE FROM meta WHERE key = 'calibre_stamp'"
  "$bin" -L "$r" query -c >/dev/null 2>&1
  dump >"$t/rr/every"
  cmp -s "$t/rr/changed" "$t/rr/every" && echo "reread same|yes" || diff "$t/rr/changed" "$t/rr/every"
  echo "reread has|$(sqlite3 "$idx" "SELECT group_concat(title || ':' || authors || ':' || coalesce(tags, ''), ',') FROM books ORDER BY id")|$(sqlite3 "$idx" "SELECT group_concat(value) FROM cal_values")"
)
mkdir -p "$t/lib"
calibredb --with-library "$t/lib" add "$pdf" >/dev/null 2>&1
"$bin" -L "$t/lib" index >/dev/null 2>&1
"$bin" -L "$t/lib" run "$t/review.lua" 2>&1
rm -f "$t"/data/lulibre/*.journal.db
ip link set lo up 2>/dev/null || true
calibre-server --port 8099 --disable-use-bonjour --enable-local-write "$t/lib" >"$t/server.log" 2>&1 &
pid=$!
i=0
while [ $i -lt 60 ] && ! grep -q 'calibre-singleinstance' /proc/net/unix 2>/dev/null; do sleep 0.5; i=$((i + 1)); done
sleep 1
"$bin" -L "$t/lib" -o server=http://127.0.0.1:8099 run "$t/embed.lua" 2>&1
# a copy of the library, under the same folder name: the server holds
# calibre's lock but has the other open
mkdir -p "$t/copy" && cp -a "$t/lib" "$t/copy/lib"
echo 'print("copy holder|" .. require("lulibre.library").holder())' > "$t/holder.lua"
"$bin" -L "$t/copy/lib" -o server=http://127.0.0.1:8099 run "$t/holder.lua" 2>&1
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
expect "two changes to one field apply one after the other" "in order|y"
expect "a proposal accepted is a change with its provenance" "accept|1"
expect "a proposal rejected is a decision in the journal" "reject|2"
expect "the record has the one, not the other" "decided|Topics in Additive Combinatorics|Unknown|0"
expect "a rejection changes nothing but is kept" "rejection|review|authors|2|front"
expect "the track record, from the journal: one accepted, one rejected, near the prior" "track|0.583|0.417"
expect "the content server is seen to hold the library" "holder|server"
expect "a change goes through the server" "apply|1"
expect "a copy of the library the server has open is not reached through it" "copy holder|other"
expect "embedding updates what the index knows of the file" "emb|Embedded Title"
expect "calibre's records read again: a book calibre did not change is not copied again" "reread untouched|untouched"
expect "the books it changed, added and removed are as a copy of every book has them" "reread same|yes"
expect "and as calibre has them" "reread has|Uno:B Author & A Author:x,three:A Author:,four:C Author:|poetry,history"
[ $fails -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
