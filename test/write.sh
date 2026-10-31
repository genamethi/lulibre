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

cat > "$t/sql.lua" <<'LUA'
local sql, sqlite3 = require "sql", require "lsqlite3"
-- rows of a query of the file a path setting names: "indexdb", "journaldb"
local function q(file, query, ...)
  local db = sql.open(setman.get("path." .. file), sqlite3.OPEN_READONLY)
  local rows = sql.run(db, query, ...)
  db:close()
  return rows
end
return q
LUA

cat > "$t/apply.lua" <<'LUA'
local q = dofile(os.getenv("T") .. "/sql.lua")
local store = require "store"
local bookman = require "bookman"
local function say(...) print(table.concat({ ... }, "|")) end
local batch, err = store.apply({
  { book = 1, field = "title", value = "Topics in Additive Combinatorics", proposal = 7,
    proposed = "Topics in Additive Combinatorics", source = "front" },
  { book = 1, field = "authors", value = "Terence Tao & Van Vu" },
  { book = 1, field = "tags", value = "math", op = "add" },
  { book = 1, field = "pubdate", value = "2006" },
  { book = 1, field = "#partof", value = "Cambridge Studies" },
}, "a test")
say("apply", tostring(batch), tostring(err))
local b = bookman.get(1)
say("record", b.title, b.author, table.concat(b.tags, ","), b.pubdate)
say("same", tostring(store.apply({ { book = 1, field = "title", value = "Topics in Additive Combinatorics" } })))
say("bad", select(2, store.apply({ { book = 1, field = "pubdate", value = "soon" } })))
local r = q("journaldb", "SELECT proposal, source FROM journal WHERE field = 'title'")[1]
say("provenance", r.proposal, r.source)
say("undo", tostring(store.undo(batch)))
b = bookman.get(1)
say("after undo", b.title, b.author)
say("undone", q("journaldb", "SELECT count(*) AS n FROM journal WHERE batch = ? AND state = 4", batch)[1].n)
store.apply({ { book = 1, field = "tags", value = "x, y", op = "add" }, { book = 1, field = "tags", value = "x", op = "remove" } })
say("in order", table.concat(bookman.get(1).tags, ","))
LUA

cat > "$t/embed.lua" <<'LUA'
local q = dofile(os.getenv("T") .. "/sql.lua")
local store = require "store"
setman.set("embed", true)
print("holder|" .. store.holder())
print("apply|" .. tostring(store.apply({ { book = 1, field = "title", value = "Embedded Title" } })))
local f = q("indexdb", "SELECT emb_title FROM files WHERE book = 1")[1]
print("emb|" .. tostring(f and f.emb_title))
LUA

cat > "$t/review.lua" <<'LUA'
local q = dofile(os.getenv("T") .. "/sql.lua")
local wit = require "wit"
local trust = require "trust"
local bookman = require "bookman"
-- a parse of the scan, as the front grammar would give it, kept as wits
wit.set(1, { { field = "title", value = "Topics in Additive Combinatorics", source = "front" },
             { field = "authors", value = "Terence Tao & Van Vu", source = "front" } })
local id = {}
for _, f in ipairs(wit.get(1)) do id[f.field] = f.alts[1].id end
print("filter|" .. #bookman.ids("is:proposed"))
print("accept|" .. tostring(wit.accept(id.title)))
print("reject|" .. tostring(wit.reject(id.authors)))
print("marked|" .. bookman.get(1).title .. "|" .. #wit.get(1) .. "|" .. wit.get(1)[1].alts[1].decision)
-- another review of its own, which writing the first leaves as it is
local first = wit.current()
local other = wit.new("other")
wit.set(1, { { field = "title", value = "Another Title", source = "front" } })
print("reviews|" .. #wit.reviews() .. "|" .. wit.reviews()[1].name .. "|" .. wit.get(1)[1].alts[1].value)
wit.open(first)
print("write|" .. table.concat({ wit.write() }, "|"))
local b = bookman.get(1)
print("decided|" .. b.title .. "|" .. b.author .. "|" .. #wit.get(1) .. "|" .. #bookman.ids("is:proposed"))
print("other kept|" .. wit.get(1, { review = other })[1].alts[1].value)
local r = q("journaldb", "SELECT store, field, proposal, source FROM journal WHERE batch = 1 AND field = 'authors'")[1]
print("rejection|" .. r.store .. "|" .. r.field .. "|" .. tostring(r.proposal ~= nil) .. "|" .. r.source)
wit.discard(other)
print("discarded|" .. #wit.reviews() .. "|" .. #bookman.ids("is:proposed"))
local rec = trust.records(1, 0.7, 0.95)
print(("track|%.3f|%.3f"):format(rec.front.title, rec.front.authors))
-- an identifier's wit, accepted: added to the record's identifiers
wit.set(1, { { field = "identifier:isbn", value = "9780387900407", source = "lex" } })
wit.accept(wit.get(1)[1].alts[1].id)
print("ident accept|" .. tostring(wit.write() ~= nil))
print("ident|" .. bookman.get(1, "identifier:isbn") .. "|" .. bookman.get(1, "authors") .. "|" .. tostring(bookman.get(99, "title")))
LUA

cat > "$t/sync.lua" <<'LUA'
local sync = require "lulib._sync"
local bookman = require "bookman"
local store = require "store"
local wit = require "wit"
local function say(...) local p = {} for i = 1, select("#", ...) do p[i] = tostring(select(i, ...)) end print(table.concat(p, "|")) end
store.reload()
local files = bookman.ids("in:sync")
table.sort(files, function(a, b) return a > b end)
say("sync waiting", #files)
local a, b = files[1], files[2]
store.apply({ { book = a, field = "title", value = "A Waiting Book" }, { book = a, field = "publisher", value = "Some House" } })
wit.set(a, { { field = "series", value = "Waiting Series", source = "front" } })
local out = sync.add({ a })
say("sync add", out.added, out.held, #out.failed, out.failed[1])
store.reload()
local added = bookman.ids("title:\"A Waiting Book\" in:library")
local id = added[1]
say("sync added", #added, bookman.get(id, "title"), bookman.get(id, "publisher"), wit.get(id)[1] and wit.get(id)[1].alts[1].value)
say("sync undo", store.undo(out.batch) ~= nil)
store.reload()
say("sync undone", #bookman.ids("title:\"A Waiting Book\" in:library"))
-- dropped, the file gone and its record with it; undone, both back
store.apply({ { book = b, field = "title", value = "A Dropped Book" } })
local path = sync.staged(b).path
local d = sync.drop { b }
say("sync drop", d.dropped, #d.failed, sync.staged(b) == nil, io.open(path) == nil)
say("sync undrop", store.undo(d.batch) ~= nil, io.open(path) ~= nil, sync.staged(b) and sync.staged(b).title)
LUA

cat > "$t/remove.lua" <<'LUA'
local remove = require "lulib._remove"
local bookman = require "bookman"
local store = require "store"
local function say(...) local p = {} for i = 1, select("#", ...) do p[i] = tostring(select(i, ...)) end print(table.concat(p, "|")) end
-- a book removed, its record kept, and :undo's way back
local ids = bookman.ids('title:"Book To Remove"')
local n, err, batch = remove.remove(ids)
say("removed", n, err, #bookman.ids('title:"Book To Remove"'))
say("restored", store.undo(batch) ~= nil)
store.reload()
local back = bookman.ids('title:"Book To Remove"')
say("back", #back, bookman.get(back[1], "tags"), back[1] ~= ids[1])
-- what orphans finds, and does
local orphans = require "lulib._orphans"
local found = orphans.scan()
say("orphans", #found.strays, found.strays[1] and found.strays[1].action, found.strays[1] and found.strays[1].rel:match("[^/]+$"))
for _, s in ipairs(found.strays) do s.action = "move" end
local out = orphans.apply(found)
say("orphans moved", out.moved, #out.failed, io.open(found.strays[1].path) == nil, out.holding ~= nil)
-- the columns, made once nothing holds the library
local columns = require "lulib._columns"
local offline = require "lulib._offline"
columns.run("")
for _ = 1, 150 do
  taskman.sleep(100)
  if #offline.jobs() == 0 then break end
end
store.reload()
local db = require("sql").open(setman.get("path.indexdb"), require("lsqlite3").OPEN_READONLY)
say("columns", #require("sql").run(db, "SELECT label FROM cal_columns WHERE label IN ('partof','part','parts')"), #offline.jobs())
db:close()
store.apply({ { book = back[1], field = "#partof", value = "A Whole" } })
say("push", columns.push("partof"))
LUA

cat > "$t/snap.lua" <<'LUA'
local snapshots = require "lulib._snapshots"
local bookman = require "bookman"
local store = require "store"
local function say(...) local p = {} for i = 1, select("#", ...) do p[i] = tostring(select(i, ...)) end print(table.concat(p, "|")) end
local book = bookman.ids('title:"Snap Book"')[1]
store.apply({ { book = book, field = "title", value = "Title Then" } })
local s = snapshots.take("plain")
say("snap taken", s.id > 0 and 1 or 0, s.name)
store.apply({ { book = book, field = "title", value = "Title Now" } })
local plan = snapshots.plan(s)
say("snap plan", #plan.changes, plan.changes[1] and plan.changes[1].value == "Title Then" and "Title Now" or "?", #plan.restore)
local out = snapshots.rollback(s)
say("snap back", out.applied, bookman.get(book, "title"), out.before and out.before.name:find("before going back") and "Title Now")
snapshots.rollback(out.before)
say("snap forward", bookman.get(book, "title"))
-- a field changed outside
local s2 = snapshots.take("second")
os.execute(("calibredb --with-library %q set_metadata %d -f publisher:Outsider >/dev/null 2>&1"):format(setman.get("path.library"), book))
store.reload()
local p2 = snapshots.plan(s2)
local p3 = snapshots.plan(s2, { exact = true })
say("snap outside", p2.kept.outside, #p2.changes, #p3.changes)
-- a book removed since
local s3 = snapshots.take("third")
local remove = require "lulib._remove"
remove.remove({ book })
local back = snapshots.rollback(s3)
store.reload()
say("snap restored", #back.restored, #bookman.ids('title:"Title Now"'))
-- from a copy of calibre's database
local si, n = snapshots.import(os.getenv("T") .. "/copy.db", "old copy")
say("snap import", si and si.id > 0 and 2 or si, n and n.values and n.values > 0)
local h = require("lulib._history").batches()
say("history", h[1].batch > h[#h].batch)
LUA

cat > "$t/queued.lua" <<'LUA'
local offline = require "lulib._offline"
local store = require "store"
local function say(...) local p = {} for i = 1, select("#", ...) do p[i] = tostring(select(i, ...)) end print(table.concat(p, "|")) end
-- a command that needs the library closed waits while the server holds it
local done
taskman.spawn(function() done = { store.command({ "add_custom_column", "waiting", "Waiting", "text" }, { label = "the column #waiting" }) } end)
taskman.sleep(500)
local jobs = offline.jobs()
say("offline waits", #jobs, jobs[1] and jobs[1].state, jobs[1] and jobs[1].label)
say("offline cancel", offline.cancel(jobs[1].batch) ~= nil, #offline.jobs())
taskman.sleep(200)
say("offline answered", done and done[1], done and done[2])
LUA

cat > "$t/inside.sh" <<'IN'
#!/bin/sh
# inside the namespace: $1 the folder, $2 the binary, $3 a PDF
t=$1; bin=$2; pdf=$3
export XDG_CONFIG_HOME=$t/config XDG_DATA_HOME=$t/data XDG_STATE_HOME=$t/state HOME=$t T=$t
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
  idx=$(ls "$t"/rr/lulibre/*-*.db | grep -v '\.[a-z]*\.db$')
  sqlite3 "$idx" "UPDATE books SET sort = 'untouched' WHERE id = 3"
  calibredb --with-library "$r" set_metadata 1 -f title:Uno -f authors:"B Author & A Author" -f tags:x >/dev/null 2>&1
  calibredb --with-library "$r" set_custom genre 1 "poetry,history" >/dev/null 2>&1
  calibredb --with-library "$r" remove 2 >/dev/null 2>&1
  calibredb --with-library "$r" add --empty --title four --authors "C Author" >/dev/null 2>&1
  "$bin" -L "$r" query -c >/dev/null 2>&1
  echo "reread untouched|$(sqlite3 "$idx" "SELECT sort FROM books WHERE id = 3")"
  jr=$(ls "$t"/rr/lulibre/*.journal.db)
  echo "outside title|$(sqlite3 "$jr" "SELECT store, label, old, new FROM journal WHERE book = 1 AND field = 'title'")"
  echo "outside removed|$(sqlite3 "$jr" "SELECT label, json_extract(old, '\$.title') FROM journal WHERE book = 2 AND field = '(removed)'")"
  echo "outside added|$(sqlite3 "$jr" "SELECT label, json_extract(new, '\$.title') FROM journal WHERE field = '(added)'")"
  echo "outside fresh|$(sqlite3 "$jr" "SELECT count(*) FROM journal WHERE book = 3")"
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
mkdir -p "$t/inbox"
{ cat "$pdf"; echo "% one"; } > "$t/inbox/one.pdf"
{ cat "$pdf"; echo "% another"; } > "$t/inbox/two.pdf"
"$bin" -L "$t/lib" -o "path.sync=$t/inbox" run "$t/sync.lua" 2>&1
calibredb --with-library "$t/lib" add --empty --title "Book To Remove" --authors "Some Writer" --tags kept >/dev/null 2>&1
for f in "$t"/lib/*/*/*.pdf; do stray=$(dirname "$f"); done
echo "stray bytes" > "$stray/stray.pdf"
"$bin" -L "$t/lib" run "$t/remove.lua" 2>&1
calibredb --with-library "$t/lib" add --empty --title "Snap Book" --authors "Some Writer" >/dev/null 2>&1
cp "$t/lib/metadata.db" "$t/copy.db"
calibredb --with-library "$t/lib" set_metadata "$(calibredb --with-library "$t/lib" list -s 'title:"Snap Book"' -f id --for-machine | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["id"])')" -f tags:changed >/dev/null 2>&1
"$bin" -L "$t/lib" run "$t/snap.lua" 2>&1
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
echo 'print("copy holder|" .. require("store").holder())' > "$t/holder.lua"
"$bin" -L "$t/copy/lib" -o server=http://127.0.0.1:8099 run "$t/holder.lua" 2>&1
"$bin" -L "$t/lib" -o server=http://127.0.0.1:8099 run "$t/queued.lua" 2>&1
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
expect "a book with wits is proposed" "filter|1"
expect "accepting a wit only marks it" "accept|true"
expect "rejecting a wit only marks it" "reject|true"
expect "the marks are kept and the record is as it was" "marked|paper|2|reject"
expect "a second review has its own proposals" "reviews|2|other|Another Title"
expect "writing is one batch of what is marked" "write|1|2"
expect "the record has the one, not the other, and the wits are gone" "decided|Topics in Additive Combinatorics|Unknown|0|1"
expect "writing in one review leaves another's proposals" "other kept|Another Title"
expect "a rejection changes nothing but is kept" "rejection|review|authors|true|front"
expect "a discarded review's proposals go" "discarded|1|0"
expect "a book removed" "removed|1|nil|0"
expect "and undo brings it back" "restored|true"
expect "under a new id, its record with it" "back|1|kept|true"
expect "orphans finds a file with no record" "orphans|1|keep|stray.pdf"
expect "and moves it out of the library" "orphans moved|1|0|true|true"
expect "the columns are made once nothing holds the library" "columns|3|0"
expect "and lulibre's values copied into them" "push|1"
expect "a command that needs the library closed waits while the server holds it" "offline waits|1|waiting|the column #waiting"
expect "and can be cancelled" "offline cancel|true|0"
expect "whoever waited for it is told" "offline answered|nil|cancelled"
expect "a change made outside lulibre is logged, field by field" "outside title|outside|outside|one|Uno"
expect "a book removed outside lulibre, with its record" "outside removed|outside|two"
expect "a book added outside lulibre" "outside added|outside|four"
expect "a book nobody changed has nothing" "outside fresh|0"
expect "a snapshot's position" "snap taken|1|plain"
expect "a plan says what going back would do" "snap plan|1|Title Now|0"
expect "and going back does it" "snap back|1|Title Then|Title Now"
expect "a rollback's own snapshot rolls forward" "snap forward|Title Now"
expect "what changed outside is left, unless exact" "snap outside|1|0|1"
expect "a removed book comes back by a rollback" "snap restored|1|1"
expect "a snapshot from a copy of calibre's database holds what the journal didn't see" "snap import|2|true"
expect "history lists batches, newest first" "history|true"
expect "the sync folder's files are waiting" "sync waiting|2"
expect "a file is added, with what lulibre knows of it" "sync add|1|0|0"
expect "with what calibredb add can't take too, and its proposals follow" "sync added|1|A Waiting Book|Some House|Waiting Series"
expect "undo takes it back out" "sync undo|true"
expect "of the library" "sync undone|0"
expect "dropped, the file leaves the folder and the list" "sync drop|1|0|true|true"
expect "undo brings it back, with its record" "sync undrop|true|true|A Dropped Book"
expect "the track record, from the journal: one accepted, one rejected, near the prior" "track|0.583|0.417"
expect "an identifier's wit accepted is added to the record's identifiers" "ident accept|true"
expect "bookman.get gives one identifier by its type, an unknown author as nothing, no book as nil" "ident|9780387900407||nil"
expect "the content server is seen to hold the library" "holder|server"
expect "a change goes through the server" "apply|1"
expect "a copy of the library the server has open is not reached through it" "copy holder|other"
expect "embedding updates what the index knows of the file" "emb|Embedded Title"
expect "calibre's records read again: a book calibre did not change is not copied again" "reread untouched|untouched"
expect "the books it changed, added and removed are as a copy of every book has them" "reread same|yes"
expect "and as calibre has them" "reread has|Uno:B Author & A Author:x,three:A Author:,four:C Author:|poetry,history"
[ $fails -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
