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
expect   "written at noon UTC, the same day in every time zone" "2004-01-01 12:00:00+00:00" \
  "$(sqlite3 "$lib/metadata.db" 'select pubdate from books where id = 1')"
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

# ---- the opf files, written by calibre after a change straight to the folder;
# and a change waits while calibre's program is open (its lock's name is
# held here by a stand-in: an abstract socket of the namespace's own)
opf1() { cat "$lib"/*/*"(1)"/metadata.opf 2>/dev/null; }
lua "$(printf "$change" 'Knots, Written Through')" >/dev/null
contains "a change straight to the folder has calibre write the book's opf file" \
  "<dc:title>Knots, Written Through</dc:title>" "$(opf1)"
python3 -c 'import socket, os, time
s = socket.socket(socket.AF_UNIX); s.bind("\0calibre-singleinstance-%d-GUI" % os.geteuid()); time.sleep(3)' &
gui=$!
sleep 0.5
began=$(date +%s)
out=$(lua "$(printf "$change" 'Knots, After The Program')")
waited=$(( $(date +%s) - began ))
wait $gui 2>/dev/null
contains "with calibre's program open, a change waits, then is made" "changed 1 book" "$out"
contains "saying why it waited" "paused while calibre's program is open" "$out"
expect   "until the program is closed" yes "$([ $waited -ge 2 ] && echo yes || echo no)"
$cdb set_metadata 1 --field "title:Knots, Marked Only" >/dev/null 2>&1 # calibredb itself only marks the book
contains "lulibre offline, with nothing queued, still has calibre write the opf files" "1 book's opf file written" "$(run offline 2>&1)"
contains "so the book's file has its record" "<dc:title>Knots, Marked Only</dc:title>" "$(opf1)"

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

# "restart now" with lulibre.service installed: starting the server runs
# lulibre offline again (server_start here does what systemd would do). One
# restart makes one copy of calibre's database, not two.
copies() { run -o backup_keep=50 backup 2>&1 | grep -c "before the content server started"; }
before=$(copies)
lua "lulibre.o.backup_keep = 50
  lulibre.o.server_stop = 'true'
  lulibre.o.server_start = '$bin --clean -L $lib -o backup_keep=50 offline > $t/service.log 2>&1'
  local offline = require 'lulibre.offline'
  print(offline.summary(offline.restart()))" >/dev/null
expect   "one restart, one copy of calibre's database" 1 $(( $(copies) - before ))
contains "the run the start set off leaves the copy to the restart" "left to the restart" "$(cat "$t/service.log")"
contains "and a start of its own still makes one" "calibre's database copied" "$(run offline 2>&1)"

# ---- calibre's database checked, and a copy of it put back
contains "calibre's database is checked"        "passes SQLite's integrity check" "$(run backup check 2>&1)"
contains "a copy is checked as it is made"      "ok      a point to go back to" "$(run backup now a point to go back to >/dev/null 2>&1; run backup 2>&1)"
was=$(field 1 title)
$cdb set_metadata 1 --field "title:Knots, Renamed Since" >/dev/null 2>&1 # calibre renames the book's folder
run index >/dev/null 2>&1
out=$(run backup compare 1 2>&1)
contains "compare says what changed"            "1 book changed since, back as it was: title 1" "$out"
contains "and that its folder was renamed"      "1 book's folder renamed since" "$out"
contains "restore shows it and asks"            "(add --yes to do it)" "$(run backup restore 1 2>&1)"
contains "with --yes it waits for the server"   "queued (offline job" "$(run backup restore 1 --yes 2>&1)"
contains "lulibre offline puts it back"         "1 record pointed at the folder as renamed since" "$(run offline 2>&1)"
expect   "the book is as it was"                "$was" "$(field 1 title)"
expect   "its record names the folder that is there" yes \
  "$([ -d "$lib/$(sqlite3 "$lib/metadata.db" 'select path from books where id = 1')" ] && echo yes || echo no)"
expect   "and its file"                         yes "$([ -f "$lib/$(sqlite3 "$lib/metadata.db" "select b.path || '/' || d.name
  || '.' || lower(d.format) from books b join data d on d.book = b.id where b.id = 1")" ] && echo yes || echo no)"
out=$($cdb check_library -r invalid_titles,missing_formats 2>&1)
contains "calibre's own check of the folders runs" "Missing book formats" "$out"
expect   "and finds nothing wrong with the book" "" "$(printf '%s\n' "$out" | grep -i knots)"
contains "what was there before is a copy too"  "before putting back the copy" "$(run backup 2>&1)"
cp "$lib/metadata.db" "$t/good.db"
# damaged: the page that starts books_tags_link no longer says what it is
python3 -I -c 'import sqlite3, sys
db = sys.argv[1]
c = sqlite3.connect(db); root, = c.execute("select rootpage from sqlite_master where name = ?", ("books_tags_link",)).fetchone()
size, = c.execute("pragma page_size").fetchone(); c.close()
with open(db, "r+b") as f:
    f.seek((root - 1) * size); f.write(b"\xff" * 8)' "$lib/metadata.db"
out=$(run backup check 2>&1 || true)
contains "a damaged database is found so"       "FAILS SQLite's integrity check" "$out"
contains "and lulibre still starts"             "lulibre goes on with the library as it last read it" "$out"
contains "a copy made of it says so"            "FAILED" "$(run backup now damaged >/dev/null 2>&1; run backup 2>&1)"
contains "the last good copy outlasts damaged ones" "ok      before putting back" "$(
  for i in 1 2 3; do run -o backup_keep=1 backup now again >/dev/null 2>&1; done
  run backup 2>&1)"
run backup restore 2 --yes >/dev/null 2>&1
contains "the good copy goes back over it"      "the copy is put back" "$(run offline 2>&1 || true)"
contains "and the database is whole"            "passes SQLite's integrity check" "$(run backup check 2>&1)"
expect   "with what it held"                    "$(sqlite3 "$t/good.db" 'select group_concat(book || tag) from books_tags_link')" \
  "$(sqlite3 "$lib/metadata.db" 'select group_concat(book || tag) from books_tags_link')"
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

# ---- calibre's server with calibre's own opf backup (contrib/calibre-server-opf.py).
# It relies on calibre's internals, so this is the check that a calibre update
# has not broken it: a title changed through the server must reach the book's
# metadata.opf, written by calibre's thread in the server.
[ -n "$srv" ] && kill $srv 2>/dev/null; srv=
i=0; while ! calibredb --with-library "$lib" list >/dev/null 2>&1; do i=$((i + 1)); [ $i -lt 100 ] || break; sleep 0.1; done
debug=$(dirname "$(command -v calibre-server)")/calibre-debug
if [ -x "$debug" ]; then
  XDG_STATE_HOME=$t/state "$debug" -e "$(dirname "$0")/../contrib/calibre-server-opf.py" -- --listen-on 127.0.0.1 \
    --port 18098 --enable-local-write "$lib" > "$t/opf-server.log" 2>&1 &
  srv=$!
  i=0
  while ! curl -s -o /dev/null -m 1 http://127.0.0.1:18098/; do
    i=$((i + 1)); [ $i -lt 200 ] || break; sleep 0.1
  done
  contains "calibre's server starts through the launcher, with calibre's metadata backup" \
    "calibre metadata backup running" "$(cat "$t/opf-server.log")"
  contains "and says so in its status file" '"opf_thread": true' "$(cat "$t/state/lulibre/calibre-server.json" 2>/dev/null)"
  calibredb --with-library http://127.0.0.1:18098 set_metadata 1 --field "title:Knots, Kept Current" >/dev/null 2>&1
  i=0; opf=
  while [ $i -lt 150 ]; do
    opf=$(cat "$lib"/*/*"(1)"/metadata.opf 2>/dev/null)
    case $opf in *"Knots, Kept Current"*) break ;; esac
    i=$((i + 1)); sleep 0.1
  done
  contains "a change through the server reaches the book's metadata.opf" "<dc:title>Knots, Kept Current</dc:title>" "$opf"
  kill $srv; wait $srv 2>/dev/null; srv=
  expect   "a clean stop removes the status file" no "$([ -e "$t/state/lulibre/calibre-server.json" ] && echo yes || echo no)"
else
  echo "offline: no calibre-debug beside calibre-server, skipping the launcher's checks"
fi

# ---- lulibre server-unit, on a unit of a home of the test's own: systemctl is
# a stand-in that reads the unit's files there, and the checks run in a pid
# namespace of their own, so no calibre-server of the machine's is seen
home=$t/home
units=$home/.config/systemd/user
mkdir -p "$units" "$t/bin"
cat > "$t/bin/systemctl" <<'SC'
#!/bin/sh
[ "$1" = "--user" ] && shift
case $1 in
  cat)
    f=$HOME/.config/systemd/user/$2
    [ -f "$f" ] || { echo "No files found for $2." >&2; exit 1; }
    echo "# $f"; cat "$f"
    for d in "$f.d"/*.conf; do [ -f "$d" ] && { echo; echo "# $d"; cat "$d"; }; done
    exit 0 ;;
  daemon-reload|restart) echo "$*" >> "$HOME/systemctl.log"; exit 0 ;;
esac
exit 1
SC
chmod +x "$t/bin/systemctl"
server=$(command -v calibre-server)
plain() { # a user unit as calibre's manual writes it, plus what is given
  printf '[Unit]\nDescription=calibre Content server\nAfter=network.target\n\n[Service]\nType=simple\n%sExecStart=%s --listen-on 127.0.0.1 "%s"\n\n[Install]\nWantedBy=default.target\n' \
    "$1" "$server" "$lib" > "$units/calibre-server.service"
}
su() { # lulibre server-unit ARGS, answering yes
  yes | unshare --pid --fork --mount-proc env HOME="$home" PATH="$t/bin:$PATH" "$bin" --clean -L "$lib" server-unit "$@" 2>&1
}
plain ""
contains "server-unit finds the unit that starts calibre-server" "calibre-server.service (a user unit" "$(su)"
contains "and says what its ExecStart would be" "would: ExecStart=$debug -e " "$(su)"
su apply >/dev/null
dropin=$units/calibre-server.service.d/lulibre-opf.conf
contains "apply writes a drop-in that replaces ExecStart" "ExecStart=
ExecStart=$debug -e " "$(cat "$dropin" 2>/dev/null)"
contains "with the unit's own arguments after --" "-- --listen-on 127.0.0.1 \"$lib\"" "$(cat "$dropin" 2>/dev/null)"
expect   "and leaves the unit's file as it was" no "$(grep -q calibre-debug "$units/calibre-server.service" && echo yes || echo no)"
contains "then reloads systemd" "daemon-reload" "$(cat "$home/systemctl.log" 2>/dev/null)"
contains "a second look sees it done" "through calibre-server-opf.py already" "$(su)"
su remove >/dev/null
expect   "remove takes the drop-in away" no "$([ -e "$dropin" ] && echo yes || echo no)"
plain "ProtectSystem=strict
"
contains "a hardened unit is not changed" "Not changed by lulibre: it has sandboxing or hardening settings (ProtectSystem)" "$(su apply)"
expect   "nothing is written for it" no "$([ -e "$dropin" ] && echo yes || echo no)"
contains "what to add is shown instead" "ExecStart=$debug -e " "$(su)"

[ $fails -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
