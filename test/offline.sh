#!/bin/sh
# End to end, offline: changing a library with no content server running,
# straight through calibredb to the library folder.
#
# Runs inside a private network namespace (unshare -rn), so no calibre
# program of yours can be holding a lock and nothing listens on the ports
# tried. Skips, successfully, where that is not possible or calibre is not
# installed. Touches nothing outside a temporary directory.
set -eu

bin=$(realpath "$1")
for tool in unshare calibredb calibre-server curl; do
  command -v $tool >/dev/null || { echo "offline: $tool not found, skipping"; exit 0; }
done
if [ -z "${LULIBRE_OFFLINE_NS:-}" ]; then
  unshare -rn true 2>/dev/null || { echo "offline: cannot create a network namespace, skipping"; exit 0; }
  exec unshare -rn env LULIBRE_OFFLINE_NS=1 sh "$0" "$bin"
fi
# skipped where luv is missing; any other failure to run a script is a failure
probe=$("$bin" --clean run "$(dirname "$0")/luv_probe.lua" 2>&1) || case $probe in
  *"module 'luv' not found"*) echo "offline: the luv rock is not installed for this Lua version, skipping"; exit 0 ;;
  *) echo "FAIL  offline: lulibre could not run a script: $probe"; exit 1 ;;
esac
ip link set lo up 2>/dev/null || { echo "offline: no loopback in the namespace, skipping"; exit 0; }

t=$(mktemp -d)
srv=
trap '[ -n "$srv" ] && kill $srv 2>/dev/null; rm -rf "$t"' EXIT
lib=$t/lib
export XDG_DATA_HOME=$t/data XDG_CONFIG_HOME=$t/config
mkdir -p "$t/src" "$t/sync" "$XDG_CONFIG_HOME"

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
pdf "$t/sync/arrived.pdf" "Just Arrived" "New Comer"
cdb="calibredb --with-library $lib"
$cdb add "$t/src/knots.pdf" --title knots --authors Unknown >/dev/null 2>&1
$cdb add "$t/src/sieve.pdf" --title sieve --authors Unknown >/dev/null 2>&1

opts=
run() { "$bin" --clean -L "$lib" $opts "$@"; }
lua() { printf '%s\n' "$1" > "$t/s.lua"; run run "$t/s.lua" 2>&1; }
fails=0
expect() { # description, expected, actual
  if [ "$2" = "$3" ]; then echo "ok    $1"; else echo "FAIL  $1: expected '$2', got '$3'"; fails=$((fails + 1)); fi
}
contains() { # description, needle, haystack
  case $3 in *"$2"*) echo "ok    $1" ;; *) echo "FAIL  $1: '$2' not in: $3"; fails=$((fails + 1)) ;; esac
}
field() { lua "local b = lulibre.book($1) print(b and require('lulibre.edit').current(b, '$2') or 'gone')"; }
change='print(require("lulibre.edit").summary(require("lulibre.edit").apply { { id = 1, field = "title", value = "%s" } }))'

contains "index"                          "0 failed" "$(run index 2>&1)"

# ---- no server configured: straight to the folder
expect   "with no server set, the route is direct" "direct	1" "$(lua 'local e = require "lulibre.edit" print(e.route(), e.write_jobs())')"
contains "a change is written"            "changed 2 books" "$(lua '
  local edit = require "lulibre.edit"
  print(edit.summary(edit.apply {
    { id = 1, field = "title", value = "Knots and Links" }, { id = 1, field = "authors", value = "Ann Lee" },
    { id = 1, field = "tags", value = "math/topology", op = "add" }, { id = 1, field = "pubdate", value = "2004" },
    { id = 2, field = "title", value = "Sieve Notes" } }))')"
expect   "title"                          "Knots and Links" "$(field 1 title)"
expect   "authors"                        "Ann Lee" "$(field 1 authors)"
expect   "date"                           "2004-01-01" "$(field 1 pubdate)"
expect   "the second book of the batch"   "Sieve Notes" "$(field 2 title)"
contains "undo"                           "undid 2" "$(lua 'local r = require("lulibre.edit").undo() print("undid " .. r.applied)')"
expect   "undo restores"                  "knots" "$(field 1 title)"

# ---- a server is set but nothing answers there
opts="-o server=http://127.0.0.1:18077 -o user=nobody"
expect   "auto: an unanswering server means direct" direct "$(lua 'print(require("lulibre.edit").route())')"
contains "and the change still lands"     "changed 1 book" "$(lua "$(printf "$change" 'Knots, Offline')")"
expect   "written to the folder"          "Knots, Offline" "$(field 1 title)"
contains "the log says why"               "does not answer; changing the library folder directly" "$(export LULIBRE_LOG="$t/log"; lua 'require("lulibre.edit").route()' >/dev/null; cat "$t/log")"
opts="-o server=http://127.0.0.1:18077 -o write_via=server"
contains "write_via=server insists"       "does not answer" "$(lua '
  local r = require("lulibre.edit").apply { { id = 1, field = "title", value = "never written" } }
  print(r.failed[1] and r.failed[1].error)')"
expect   "and writes nothing"             "Knots, Offline" "$(field 1 title)"
opts="-o write_via=server"
contains "write_via=server needs a server" "lulibre.o.server is not set" "$(lua 'require("lulibre.edit").apply { { id = 1, field = "title", value = "x" } }' || true)"

# ---- the sync folder and removal, offline
opts="-o sync_dir=$t/sync"
contains "sync add, directly"             "added 1 to the library" "$(run sync add all 2>&1)"
expect   "the staged file is a book now"  "arrived" "$(lua 'print(lulibre.books("in:library title:arrived")[1].title)')"
contains "remove, directly"               "1" "$(lua 'print((require("lulibre.edit").remove { 2 }))')"
expect   "the book is gone"               gone "$(field 2 title)"

# ---- changes that wait for the server to be stopped (lulibre.offline), and
# the copies of calibre's database made before it starts (lulibre.backup)
opts=
lua 'require("lulibre.custom").declare("#volume", { type = "number" })
     lulibre.apply { { id = 1, field = "#volume", value = "4" } }' >/dev/null
expect   "a column for a custom field waits"   waiting "$(lua 'local c = require "lulibre.custom"
  c.add_column("#volume", { heading = "Volume" }); print(c.state("#volume").state)')"
contains "with nothing holding the library, it can be done now" "nothing has the library open" "$(lua 'require("lulibre.offline").ask()')"
contains "lulibre offline makes it"            "1 done" "$(run offline 2>&1)"
contains "in calibre"                          "volume (" "$($cdb custom_columns 2>&1)"
contains "after a copy of calibre's database"  "before the content server started" "$(lua '
  for _, b in ipairs(require("lulibre.backup").list()) do print(b.reason) end')"
expect   "the copy is whole"                   ok "$(sqlite3 "$(lua 'print(require("lulibre.backup").last().path)')/metadata.db" 'pragma integrity_check')"
expect   "the books' opf files were written first" 0 "$(sqlite3 "$lib/metadata.db" 'select count(*) from metadata_dirtied d join books b on b.id = d.book')"
expect   "its value is not calibre's yet"      1 "$(lua 'print(require("lulibre.custom").state("#volume").differ)')"
contains "push copies it"                      "volume" "$(lua 'require("lulibre.custom").push("#volume")'; $cdb list -f '*volume' 2>&1)"
expect   "so they agree"                       0 "$(lua 'print(require("lulibre.custom").state("#volume").differ)')"
contains "an edit goes to calibre's column too" "7" "$(lua 'lulibre.apply { { id = 1, field = "#volume", value = "7" } }'; $cdb list -f '*volume' 2>&1)"
opts="-o backup_restart=next"
run offline >/dev/null 2>&1
contains "next is spent after one copy"        "nothing was waiting" "$(run offline 2>&1)"
opts="-o backup_keep=2"
run offline >/dev/null 2>&1
expect   "backup_keep copies are kept"         2 "$(lua 'print(#require("lulibre.backup").list())')"
opts=
lua 'print(require("lulibre.custom").remove_column("#volume"))' >/dev/null
run offline >/dev/null 2>&1
expect   "a column's removal waits, then is done" "" "$($cdb custom_columns 2>&1 | grep volume)"
expect   "and lulibre keeps its values"        7 "$(lua 'print(require("lulibre.custom").get(1, "#volume"))')"

# ---- a server that is running: direct access must be refused with a reason,
# and auto must find the server
opts=
echo secret > "$t/pw"
chmod 600 "$t/pw" # as a password file should be: lulibre warns of one others can read
calibre-server --userdb "$t/users.sqlite" --manage-users -- add tester secret >/dev/null 2>&1
calibre-server --listen-on 127.0.0.1 --port 18099 --enable-auth --auth-mode basic \
  --userdb "$t/users.sqlite" "$lib" > "$t/server.log" 2>&1 &
srv=$!
i=0
while ! curl -s -o /dev/null -m 1 http://127.0.0.1:18099/; do
  i=$((i + 1))
  [ $i -lt 150 ] || { echo "offline: the test server did not start; skipping the last checks"; srv_failed=1; break; }
  sleep 0.1
done
if [ -z "${srv_failed:-}" ]; then
  opts="-o write_via=direct"
  contains "direct while a server runs is explained" "has the library open" "$(lua '
    local r = require("lulibre.edit").apply { { id = 1, field = "title", value = "blocked" } }
    print(r.failed[1] and r.failed[1].error)')"
  opts="-o server=http://127.0.0.1:18099 -o user=tester -o password_file=$t/pw"
  expect   "auto finds the running server" server "$(lua 'print(require("lulibre.edit").route())')"
  contains "jobs that need it stopped wait while it runs" "content server is running" "$(lua '
    require("lulibre.offline").queue({ "check_library" }, "a check")
    print(select(2, pcall(require("lulibre.offline").run)))')"
  contains "and writes through it"        "changed 1 book" "$(lua "$(printf "$change" 'Knots, Online')")"
  expect   "through the server"           "Knots, Online" "$(field 1 title)"
  chmod 644 "$t/pw"
  contains "a password file others can read is warned of" "can be read by other users" "$(lua "$(printf "$change" 'Knots, Again')")"
  chmod 600 "$t/pw"
fi

[ $fails -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
