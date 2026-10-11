#!/bin/sh
# Write-path test: everything that changes a calibre library, against a
# throwaway library and a throwaway authenticated content server.
#
# It runs inside a private network namespace (unshare -rn), because calibre
# allows one server per machine to hold its lock and because the port must
# not collide with a real server. Skips, successfully, where that is not
# possible or calibre is not installed. Touches nothing outside a temporary
# directory.
set -eu

bin=$(realpath "$1")
for tool in unshare calibredb calibre-server curl; do
  command -v $tool >/dev/null || { echo "write: $tool not found, skipping"; exit 0; }
done
if [ -z "${LULIBRE_WRITE_NS:-}" ]; then
  unshare -rn true 2>/dev/null || { echo "write: cannot create a network namespace, skipping"; exit 0; }
  exec unshare -rn env LULIBRE_WRITE_NS=1 sh "$0" "$bin"
fi
"$bin" --clean run "$(dirname "$0")/luv_probe.lua" >/dev/null 2>&1 || {
  echo "write: the luv rock is not installed for this Lua version, skipping"; exit 0; }
ip link set lo up 2>/dev/null || { echo "write: no loopback in the namespace, skipping"; exit 0; }

t=$(mktemp -d)
srv=
trap '[ -n "$srv" ] && kill $srv 2>/dev/null; rm -rf "$t"' EXIT
lib=$t/lib
export XDG_DATA_HOME=$t/data XDG_CONFIG_HOME=$t/config
mkdir -p "$t/src" "$XDG_CONFIG_HOME"

pdf() { # file, title line, second line
  cat > "$1" <<PDF
%PDF-1.4
1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj
2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj
3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 612 792]/Contents 4 0 R/Resources<</Font<</F1 5 0 R>>>>>>endobj
4 0 obj<</Length 200>>stream
BT /F1 24 Tf 72 700 Td ($2) Tj ET
BT /F1 12 Tf 72 660 Td ($3) Tj ET
endstream
endobj
5 0 obj<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>endobj
trailer<</Root 1 0 R/Size 6>>
%%EOF
PDF
}
pdf "$t/src/knots.pdf" "Knots and Links" "Ann Lee"
pdf "$t/src/sieve.pdf" "Sieve Notes" "Jane Roe"
pdf "$t/src/algebra.pdf" "Commutative Algebra" "chapter"
pdf "$t/src/new.pdf" "A New Chapter" "chapter"
pdf "$t/src/lost.pdf" "Lost" "L. Author"
pdf "$t/src/old.pdf" "Commutative Algebra" "an older build"

cdb="calibredb --with-library $lib"
$cdb add "$t/src/knots.pdf" --title knots --authors Unknown >/dev/null 2>&1                           # 1
$cdb add "$t/src/sieve.pdf" --title sieve --authors Unknown >/dev/null 2>&1                           # 2
$cdb add "$t/src/algebra.pdf" --title algebra --authors Unknown >/dev/null 2>&1                       # 3
$cdb add --duplicates "$t/src/knots.pdf" --title "Knots and Links" --authors "Ann Lee" \
  --tags math/topology >/dev/null 2>&1                                                                # 4: same bytes as 1
$cdb add "$t/src/lost.pdf" --title "Lost" --authors "L. Author" >/dev/null 2>&1                      # 5: will lose its file
$cdb add "$t/src/old.pdf" --title "Commutative Algebra" --authors "The Authors" \
  --tags kept/tag >/dev/null 2>&1                                                                     # 6: will lose its file

echo secret > "$t/pw"
echo wrong > "$t/pw-wrong"
calibre-server --userdb "$t/users.sqlite" --manage-users -- add tester secret >/dev/null 2>&1
calibre-server --listen-on 127.0.0.1 --port 18099 --enable-auth --auth-mode basic \
  --userdb "$t/users.sqlite" "$lib" > "$t/server.log" 2>&1 &
srv=$!
i=0
while ! curl -s -o /dev/null -m 1 http://127.0.0.1:18099/; do
  i=$((i + 1))
  [ $i -lt 150 ] || { echo "write: the test server did not start, skipping"; exit 0; }
  sleep 0.1
done

pwfile=$t/pw
run() { "$bin" --clean -L "$lib" -o server=http://127.0.0.1:18099 -o user=tester -o password_file="$pwfile" "$@"; }
lua() { printf '%s\n' "$1" > "$t/s.lua"; run run "$t/s.lua" 2>&1; }
fails=0
expect() { # description, expected, actual
  if [ "$2" = "$3" ]; then echo "ok    $1"; else echo "FAIL  $1: expected '$2', got '$3'"; fails=$((fails + 1)); fi
}
contains() { # description, needle, haystack
  case $3 in *"$2"*) echo "ok    $1" ;; *) echo "FAIL  $1: '$2' not in: $3"; fails=$((fails + 1)) ;; esac
}
field() { lua "local b = lulibre.book($1) print(b and require('lulibre.edit').current(b, '$2') or 'gone')"; }

contains "index"                          "0 failed" "$(run index 2>&1)"

# ---- edit, undo
contains "apply changes several fields"   "changed 1 book" "$(lua '
  local edit = require "lulibre.edit"
  print(edit.summary(edit.apply {
    { id = 2, field = "title", value = "Sieve Notes" }, { id = 2, field = "authors", value = "Jane Roe & A. N. Other" },
    { id = 2, field = "pubdate", value = "1999" }, { id = 2, field = "tags", value = "math/number-theory", op = "add" },
    { id = 2, field = "series", value = "Notes" }, { id = 2, field = "series_index", value = "3" },
    { id = 2, field = "identifiers", value = "doi:10.1000/xyz", op = "add" } }))')"
expect   "title written"                  "Sieve Notes" "$(field 2 title)"
expect   "authors written"                "Jane Roe & A. N. Other" "$(field 2 authors)"
expect   "date written, no day slip"      "1999-01-01" "$(field 2 pubdate)"
expect   "series index written"           "3" "$(field 2 series_index)"
expect   "identifier written"             "doi:10.1000/xyz" "$(field 2 identifiers)"
contains "undo"                           "undid 1 book" "$(lua '
  local r = require("lulibre.edit").undo()
  print(("undid %d book, skipped %d"):format(r.applied, r.skipped))')"
expect   "undo restores the title"        "sieve" "$(field 2 title)"
expect   "undo restores the authors"      "" "$(field 2 authors)"
expect   "undo clears the date"           "" "$(field 2 pubdate)"
expect   "undo clears the series"         "" "$(field 2 series)"
pwfile=$t/pw-wrong
contains "a wrong password is explained"  "password" "$(lua '
  local r = require("lulibre.edit").apply { { id = 2, field = "title", value = "x" } }
  print(r.failed[1] and r.failed[1].error)')"
pwfile=$t/pw
expect   "and nothing was written"        "sieve" "$(field 2 title)"

# ---- proposals from the files, review, write
contains "propose reads the title pages"  "proposals" "$(run run propose 2>&1)"
contains "accepted proposals are written" "changed" "$(lua '
  local proposals = require "lulibre.proposals"
  for _, q in ipairs(proposals.list("pending")) do
    if q.field == "title" and q.book == 2 then proposals.accept(q) end
  end
  print(require("lulibre.edit").summary(proposals.apply_accepted()))')"
expect   "proposal landed"                "Sieve Notes" "$(field 2 title)"

# ---- metadata that comes with the files (.bib beside them)
mkdir "$t/built"
cp "$t/src/algebra.pdf" "$t/src/new.pdf" "$t/built/"
cat > "$t/built/built.bib" <<'BIB'
@incollection{algebra, author = {{The Authors}}, title = {Commutative Algebra}, series = {Project},
  number = {10}, date = {2026-07-28}, keywords = {math/algebra}, file = {algebra.pdf}}
@incollection{new, author = {{The Authors}}, title = {A New Chapter}, series = {Project},
  number = {11}, date = {2026-07-28}, keywords = {math/algebra}, file = {new.pdf}}
BIB
contains "bib-import matches by content"  "1 matched to books (1 by same file)" "$(run run bib-import "$t/built/built.bib" 2>&1)"
lua 'local proposals = require "lulibre.proposals"
  for _, q in ipairs(proposals.list("pending")) do if q.confidence == 1 then proposals.accept(q) end end
  proposals.apply_accepted()' >/dev/null
expect   "imported title"                 "Commutative Algebra" "$(field 3 title)"
expect   "imported corporate author"      "The Authors" "$(field 3 authors)"
expect   "imported series index"          "10" "$(field 3 series_index)"
contains "onboard sees what is there"     "identical to book 3" "$(lua '
  -- the listing is columns; the note is not among them, so ask the module
  print(("identical to book %s"):format(require("lulibre.dupes").twin(arg and arg[1] or "'"$t/built/algebra.pdf"'")))')"
contains "onboard adds only the new file" "added 1" "$(run run onboard "$t/built" --apply 2>&1)"
expect   "onboarded with the .bib's data" "A New Chapter|The Authors|2026-07-28|11" "$(lua '
  local b = lulibre.books([[title:="A New Chapter"]])[1]
  local e = require "lulibre.edit"
  print(table.concat({ b.title, b.author, e.current(b, "pubdate"), e.current(b, "series_index") }, "|"))')"

# ---- duplicates
dupes=$(run run dupes 2>&1)
contains "dupes finds the identical pair" "1 groups, 1 surplus books" "$dupes"
contains "dupes keeps the better record"  "keep     4" "$dupes"
expect   "is:dupe"                        2 "$(run query -c is:dupe 2>&1)"
contains "dupes --remove"                 "removed 1 books" "$(run run dupes --remove 2>&1)"
expect   "the surplus copy is gone"       gone "$(field 1 title)"
expect   "the kept copy is still there"   "Knots and Links" "$(field 4 title)"
test -d "$lib/.caltrash" && r=yes || r=no
expect   "removal went to the recycle bin" yes "$r"

# ---- orphans: plant one of each kind, using exact paths from the index
lua '
  local uv = require "luv"
  local function file(id) return lulibre.files(id)[1].path end
  local function dir(path) return (path:match("^(.*)/[^/]*$")) end
  local f2, f5, f6 = file(2), file(5), file(6)
  -- 5: its file sits in a folder inside book 2
  assert(uv.fs_mkdir(dir(f2) .. "/Lost (5)", 493))
  assert(uv.fs_rename(f5, dir(f2) .. "/Lost (5)/" .. f5:match("[^/]*$")))
  -- 6: its file is gone; book 3 is the same work
  assert(uv.fs_unlink(f6))
  -- a stray file identical to book 4s file
  assert(uv.fs_copyfile(file(4), dir(f2) .. "/stray copy.pdf"))
  -- a folder of the users own, with a link to where book 2 used to be
  local root = lulibre.o.library
  assert(uv.fs_mkdir(root .. "/To Read", 493))
  assert(uv.fs_symlink("../Unknown/Old Name (2)/old.pdf", root .. "/To Read/moved.pdf"))' >/dev/null
report=$(run run orphans 2>&1)
contains "orphans: file found elsewhere"  "reattach     5" "$report"
contains "orphans: superseded record"     "remove       6" "$report"
contains "orphans: stray duplicate"       "[identical to book 4's file]" "$report"
contains "orphans: broken link"           "relink   To Read/moved.pdf" "$report"
out=$(run run orphans --apply 2>&1)
contains "orphans --apply"                "1 given their files back, 1 records removed, 1 stray files moved out, 1 links repaired" "$out"
contains "the removed record's tag is proposed for its copy" "1 things the removed records knew" "$out"
expect   "the record is gone"             gone "$(field 6 title)"
test -e "$lib/To Read/moved.pdf" && r=yes || r=no
expect   "the link resolves again"        yes "$r"
expect   "book 5 has its file back"       indexed "$(run index >/dev/null 2>&1; lua 'print(lulibre.files(5)[1].status)')"
contains "nothing left to clean"          "re-attach 0, remove 0 records, move 0 files out, repair 0 links" "$(run run orphans 2>&1)"
test -n "$(find "$XDG_DATA_HOME/lulibre/orphans" -name 'stray copy.pdf')" && r=yes || r=no
expect   "the stray file was set aside, not deleted" yes "$r"

# ---- links in the user's own folders are repaired when a change renames a book's folder
lua '
  local uv = require "luv"
  local f = lulibre.files(2)[1].path
  uv.fs_unlink(lulibre.o.library .. "/To Read/moved.pdf")
  assert(uv.fs_symlink("../" .. f:sub(#lulibre.o.library + 2), lulibre.o.library .. "/To Read/two.pdf"))' >/dev/null
test -e "$lib/To Read/two.pdf" && r=yes || r=no
expect   "a link to book 2"               yes "$r"
contains "a rename with repair_links=never" "changed 1 book" "$(lua '
  lulibre.o.repair_links = "never"
  print(require("lulibre.edit").summary(require("lulibre.edit").apply { { id = 2, field = "title", value = "Sieve Notes II" } }))')"
test -e "$lib/To Read/two.pdf" && r=yes || r=no
expect   "leaves the link broken"         no "$r"
contains "ask, with nobody to ask, says so" "lulibre orphans --apply" "$(lua '
  lulibre.o.repair_links = "ask"
  require("lulibre.edit").apply { { id = 2, field = "title", value = "Sieve Notes III" } }')"
contains "auto repairs it"                "repaired 1 link" "$(lua '
  lulibre.o.repair_links = "auto"
  print(require("lulibre.edit").summary(require("lulibre.edit").apply { { id = 2, field = "title", value = "Sieve Notes IV" } }))')"
test -e "$lib/To Read/two.pdf" && r=yes || r=no
expect   "the link follows the book"      yes "$r"

# ---- the sync folder
mkdir "$t/sync" "$t/sync/sub"
pdf "$t/sync/fresh paper.pdf" "On Fresh Things" "Nora New"
pdf "$t/sync/sub/with-bib.pdf" "Body Text" "x"
cp "$t/src/knots.pdf" "$t/sync/already.pdf"
cat > "$t/sync/sub/meta.bib" <<'BIB'
@book{b, author = {Dee, Bea and Eff, Cy}, title = {Told by the Bib}, year = {2001}, publisher = {Bib Press},
  keywords = {from/bib}, file = {with-bib.pdf}}
BIB
srun() { run -o sync_dir="$t/sync" "$@"; }
slua() { printf '%s\n' "$1" > "$t/s.lua"; srun run "$t/s.lua" 2>&1; }
listing=$(srun sync 2>&1)
contains "sync lists the folder"          "3 files, 3 new, 1 already in the library" "$listing"
contains "sync: the .bib names its file"  "Told by the Bib" "$listing"
contains "sync: a file the library has"   "= book 4" "$listing"
expect   "staged files are not library books" 5 "$(srun query -c '' 2>&1)"
expect   "in:sync"                        3 "$(srun query -c in:sync 2>&1)"
expect   "in:all"                         8 "$(srun query -c in:all 2>&1)"
expect   "is:inlibrary"                   1 "$(srun query -c 'in:sync is:inlibrary' 2>&1)"
expect   "filters work on staged files"   1 "$(srun query -c 'in:sync author:"bea dee" tag:from/bib year:2001' 2>&1)"
contains "staged files are indexed"       "0 failed" "$(srun index 2>&1)"
expect   "and searchable"                 1 "$(srun query -c 'in:sync text:fresh' 2>&1)"
contains "propose reads staged title pages" "proposals" "$(srun run propose in:sync 2>&1)"
fresh=$(slua 'print(lulibre.ids([[in:sync title:="fresh paper"]])[1])')
contains "editing a staged file"          "changed 1 book" "$(slua "
  local edit = require 'lulibre.edit'
  print(edit.summary(edit.apply {
    { id = $fresh, field = 'title', value = 'On Fresh Things' }, { id = $fresh, field = 'authors', value = 'Nora New' },
    { id = $fresh, field = 'tags', value = 'math/fresh', op = 'add' }, { id = $fresh, field = 'pubdate', value = '2020' } }))")"
expect   "the edit is in the staged record" "On Fresh Things|Nora New|math/fresh|2020-01-01" "$(slua "
  local b, e = lulibre.book($fresh), require 'lulibre.edit'
  print(table.concat({ b.title, b.author, e.current(b, 'tags'), e.current(b, 'pubdate') }, '|'))")"
contains "undo works on staged files"     "fresh paper" "$(slua "require('lulibre.edit').undo() print(lulibre.book($fresh).title)")"
slua "local e = require 'lulibre.edit' e.apply { { id = $fresh, field = 'title', value = 'On Fresh Things' },
  { id = $fresh, field = 'authors', value = 'Nora New' }, { id = $fresh, field = 'pubdate', value = '2020' } }" >/dev/null
expect   "nothing reached calibre yet"    0 "$(srun query -c 'author:"nora new"' 2>&1)"
contains "sync add"                       "added 2 to the library, 1 already there" "$(srun sync add all 2>&1)"
expect   "added with the staged metadata" "On Fresh Things|Nora New|2020-01-01" "$(slua '
  local b, e = lulibre.books([[in:library author:"nora new"]])[1], require "lulibre.edit"
  print(table.concat({ b.title, b.author, e.current(b, "pubdate") }, "|"))')"
expect   "added with the .bib's metadata" "Told by the Bib|Bea Dee & Cy Eff|Bib Press|from/bib" "$(slua '
  local b, e = lulibre.books([[in:library title:="Told by the Bib"]])[1], require "lulibre.edit"
  print(table.concat({ b.title, b.author, e.current(b, "publisher"), e.current(b, "tags") }, "|"))')"
test -e "$t/sync/fresh paper.pdf" && r=yes || r=no
expect   "sync add leaves the files"      yes "$r"
expect   "which now all count as held"    3 "$(srun query -c 'in:sync is:inlibrary' 2>&1)"
contains "sync move"                      "3 already there, 3 files removed from the sync folder" "$(srun sync move all 2>&1)"
expect   "the sync folder is empty"       0 "$(find "$t/sync" -name '*.pdf' | wc -l)"
expect   "and nothing is staged"          0 "$(srun query -c in:sync 2>&1)"
expect   "the library gained two books"   7 "$(srun query -c '' 2>&1)"
contains "the config prints as Lua"       'o.sync_dir = "' "$(srun config 2>&1)"
contains "and names the policies"         "auto | ask | never" "$(srun config 2>&1)"
contains "a bad policy value is refused"  "is one of auto|ask|never" "$(run -o repair_links=maybe query -c '' 2>&1 || true)"

[ $fails -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
