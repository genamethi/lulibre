#!/bin/sh
# Smoke test: build a two-book calibre library from scratch, index it, query it.
# Touches nothing outside a temporary directory.
set -eu

bin=$(realpath "$1")
command -v sqlite3 >/dev/null || { echo "smoke: sqlite3 CLI not found, skipping"; exit 0; }

t=$(mktemp -d)
T="tmux -L lulibre-smoke-$$"
# (stop the private tmux server too: a run that fails part-way would leave
# its sessions, and the lulibre in them, running)
trap '$T kill-server 2>/dev/null || true; rm -rf "$t"' EXIT
lib=$t/lib
sh "$(dirname "$0")/mklib.sh" "$lib"

export XDG_DATA_HOME="$t/data"
run() { "$bin" --clean -L "$lib" "$@"; }

fails=0
expect() { # description, expected, actual
  if [ "$2" = "$3" ]; then
    echo "ok    $1"
  else
    echo "FAIL  $1: expected '$2', got '$3'"
    fails=$((fails + 1))
  fi
}
contains() { # description, needle, haystack
  case $3 in
    *"$2"*) echo "ok    $1" ;;
    *) echo "FAIL  $1: '$2' not in output"; fails=$((fails + 1)) ;;
  esac
}

contains "index extracts both files"      "2 ok, 0 failed"     "$(run index 2>&1)"
contains "second run skips unchanged"     "2 already current"  "$(run index 2>&1)"
expect   "empty filter matches all"       2 "$(run query -c)"
expect   "accent-insensitive author"      1 "$(run query -c author:erdos)"
expect   "placeholder author"             1 "$(run query -c author:unknown)"
expect   "hierarchical subject"           1 "$(run query -c subject:number-theory)"
expect   "subject needs whole component"  0 "$(run query -c subject:number)"
expect   "negation"                       1 "$(run query -c -- -subject:math)"
expect   "missing date"                   1 "$(run query -c no:date)"
expect   "year comparison"                1 "$(run query -c 'year:>1990')"
expect   "identifier"                     1 "$(run query -c doi:10.1000)"
expect   "full text, pdf"                 1 "$(run query -c text:sieve)"
expect   "full text, plain text file"     1 "$(run query -c 'text:"additive number theory"')"
expect   "Lua pattern over text"          1 "$(run query -c 'text:~arXiv:%d+%.%d+')"
expect   "Lua pattern over title"         1 "$(run query -c 'title:~^N')"
expect   "or"                             2 "$(run query -c text:sieve or author:erdos)"
expect   "columns"                        "2	1996	Paul Erdős" "$(run query -f id,year,authors id:2)"
contains "title line keeps its font size" "24.0"               "$(run show -l 1)"
contains "bad pattern is reported"        "bad Lua pattern"    "$(run query 'title:~%' 2>&1 || true)"

# Lua: a script against this library (the unit checks are test/units.sh).
cat > "$t/probe.lua" <<'LUA'
local tp = require("lulibre.titlepage").classify(lulibre.lines(1))
local b = lulibre.book(2)
print(tp.title, tp.arxiv, tp.subject, b.authors[1], b.idents.doi, b.year)
LUA
expect   "lua script reads the index" \
  "A Note on Sieve Methods	1012.6008	math/number-theory	Paul Erdős	10.1000/xyz	1996" \
  "$(run run "$t/probe.lua" 2>&1)"
# duplicates: a third book holding the first one's bytes
contains "no duplicates yet"              ", 0 groups,"        "$(run run dupes 2>&1)"
expect   "is:dupe is empty"               0 "$(run query -c is:dupe 2>&1)"
# a configuration directory of one's own
mkdir -p "$t/conf/scripts"
printf 'lulibre.o.pages = 11\n' > "$t/conf/init.lua"
printf 'print("hello from", lulibre.settings.paths().scripts)\n' > "$t/conf/scripts/hello.lua"
contains "-C chooses the configuration directory" "pages           11" "$("$bin" -C "$t/conf" -L "$lib" -o help 2>&1)"
contains "its scripts are found"          "hello from	$t/conf/scripts" "$("$bin" -C "$t/conf" -L "$lib" run hello 2>&1)"
contains "\$LULIBRE_CONFIG_DIR does the same" "pages           11" "$(LULIBRE_CONFIG_DIR="$t/conf" "$bin" -L "$lib" -o help 2>&1)"
expect   "config --path follows it"       "$t/conf/init.lua" "$("$bin" -C "$t/conf" -L "$lib" config --path 2>&1)"
expect   "--clean still skips init.lua"   "pages           6" "$("$bin" --clean -C "$t/conf" -L "$lib" -o help 2>&1 | grep '^pages ' | cut -c1-17)"
contains "config prints every option"     "o.repair_links"     "$(run config 2>&1)"
contains "config knows the default"       '-- o.pages = 6'     "$(run config 2>&1)"
contains "config shows what was set"      'o.pages = 9'        "$(run -o pages=9 config 2>&1)"
printf 'error("boom")\n' > "$t/bad.lua"
run run "$t/bad.lua" >/dev/null 2>&1 && rc=0 || rc=$?
expect   "failing script exits 1"         1 "$rc"

# looking books up, from what was fetched before: nothing here touches the network
cat > "$t/kept.lua" <<'LUA'
local net = require "lulibre.net"
net.keep("crossref", "10.1000/xyz", 200, [=[{"status":"ok","message":{"DOI":"10.1000/xyz","type":"book",
  "title":["Notes on Additive Number Theory"],"author":[{"given":"Paul","family":"Erdős"}],"publisher":"Example Press",
  "issued":{"date-parts":[[1996,5,1]]},"ISBN":["9780387900407"]}}]=])
net.keep("zbmath", "doi:10.1000/xyz", 200, [=[{"result":[{"contributors":{"authors":[{"name":"Erdős, Paul"}]},
  "identifier":"0001.00001","year":"1996","msc":[{"code":"11B13"}],"title":{"title":"Notes on additive number theory"}}]}]=])
net.keep("openlibrary", "9780387900407", 404)
LUA
run run "$t/kept.lua" >/dev/null 2>&1
out=$(run run enrich --offline id:2 2>&1)
contains "enrich answers from what is kept"   "a record for 1 (crossref 1, zbmath 1); 0 requests made" "$out"
contains "and proposes what the records say"  "proposals" "$out"
expect   "the title, the publisher of a book, the Zbl number" \
  "identifiers:zbl:0001.00001|publisher:Example Press|title:Notes on Additive Number Theory" \
  "$(run query -f id id:2 >/dev/null 2>&1; printf 'for _, p in ipairs(lulibre.sql("SELECT field, value FROM proposals WHERE book = 2 AND status = \x27pending\x27 AND field IN (\x27title\x27, \x27publisher\x27) OR value LIKE \x27zbl:%%\x27 ORDER BY field")) do io.write(p.field, ":", p.value, "|") end\n' > "$t/p.lua"; run run "$t/p.lua" 2>&1 | sed 's/|$//')"
contains "a book with no identifier is passed over" "a record for 0" "$(run run enrich --offline id:1 2>&1)"

# fetching arXiv's snapshot: a stand-in for Kaggle's program, so nothing is asked of Kaggle
cat > "$t/fakekaggle" <<'SH'
#!/bin/sh
# kaggle datasets download Cornell-University/arxiv -p DIR --unzip
[ "$1 $2 $3" = "datasets download Cornell-University/arxiv" ] || { echo "unexpected: $*" >&2; exit 2; }
printf '%s\n' '{"id":"0704.0001","authors":"A. N. Other","title":"A Paper","categories":"math.NT","versions":[{"version":"v1","created":"Mon, 2 Apr 2007 19:18:42 GMT"}],"authors_parsed":[["Other","A. N.",""]]}' > "$5/arxiv-metadata-oai-snapshot.json"
SH
cat > "$t/nokaggle" <<'SH'
#!/bin/sh
echo "401 Client Error: Unauthorized" >&2
exit 1
SH
chmod +x "$t/fakekaggle" "$t/nokaggle"
contains "a fetch that Kaggle refuses says why, and what to do" "put it in ~/.kaggle/" "$(run run arxiv-fetch --with "$t/nokaggle" 2>&1)"
contains "arXiv's snapshot is fetched into the data folder" "arXiv's snapshot fetched" "$(run run arxiv-fetch --with "$t/fakekaggle" 2>&1)"
expect   "where :enrich looks for it"  "$XDG_DATA_HOME/lulibre/arxiv-metadata-oai-snapshot.json" \
  "$(printf 'print(require("lulibre.net").arxiv_snapshot_path())\n' > "$t/sp.lua"; run run "$t/sp.lua" 2>&1)"
contains "a fresh one is not fetched again"  "arXiv renews it about weekly" "$(run run arxiv-fetch --with "$t/nokaggle" 2>&1)"

# a binary run from a source tree that has since become another version says so
mkdir -p "$t/tree/build" "$t/tree/src"
cp "$bin" "$t/tree/build/lulibre"
ln -s "$(cd "$(dirname "$0")/.." && pwd)/lua" "$t/tree/lua"
ln -s "$(cd "$(dirname "$0")/.." && pwd)/scripts" "$t/tree/scripts"
cp "$(dirname "$0")/../src/version.h" "$t/tree/src/version.h"
tree() { "$t/tree/build/lulibre" --clean -L "$lib" "$@"; }
expect   "a tree of the binary's own version is fine" "2" "$(tree query -c 2>&1)"
sed -i 's/define LULIBRE_VERSION_MINOR .*/define LULIBRE_VERSION_MINOR 99/' "$t/tree/src/version.h"
contains "a tree of another version is named at start" "is now 0.99." "$(tree query -c 2>&1)"
contains "and when a script fails there"  "Quit, run make there" "$(tree run "$t/bad.lua" 2>&1 || true)"

# The interactive interface, driven through a private tmux server.
if command -v tmux >/dev/null; then
  screen() { $T capture-pane -p -t t 2>/dev/null; }
  wait_for() { # pattern
    i=0
    while [ $i -lt 100 ]; do
      screen | grep -q -- "$1" && return 0
      sleep 0.05
      i=$((i + 1))
    done
    return 1
  }
  shown() { wait_for "$2" && echo "ok    $1" || { echo "FAIL  $1"; fails=$((fails + 1)); }; }
  $T new-session -d -s t -x 120 -y 30 \
    "XDG_DATA_HOME='$t/data' '$bin' --clean -L '$lib'; echo \$? > '$t/rc'"
  shown "tui starts"                 "NORMAL"
  shown "tui lists both books"       "1/2"
  shown "tui previews indexed text"  "A Note on Sieve Methods"
  $T send-keys -t t / ; $T send-keys -t t -l "erdos" ; $T send-keys -t t Enter
  shown "tui / jumps to the match"   "/erdos: 1   2/2"
  $T send-keys -t t n
  shown "tui n wraps around"         "continuing at the top"
  $T send-keys -t t Escape "&" ; $T send-keys -t t -l "author:erdos"
  shown "tui & narrows as you type"  "1/1"
  $T send-keys -t t Enter Space
  shown "tui marks"                  "1 marked"
  $T send-keys -t t : ; $T send-keys -t t -l "mark none" ; $T send-keys -t t Enter
  $T send-keys -t t g a ; $T send-keys -t t -l "unk" ; $T send-keys -t t Enter
  shown "tui picker sets a filter"   'author:="Unknown"'
  $T send-keys -t t Escape : ; $T send-keys -t t -l 'lua lulibre.count("")' ; $T send-keys -t t Enter
  shown "tui :lua"                   "^2 *$"
  # the command line: completion and history
  $T send-keys -t t : ; $T send-keys -t t -l "so"
  shown "commands complete by prefix"    "source "
  $T send-keys -t t Tab ; $T send-keys -t t -l " -y"
  shown "and so do their arguments"      " [-]year "
  $T send-keys -t t Tab
  shown "Tab takes the completion"       "^:sort -year"
  $T send-keys -t t Enter
  $T send-keys -t t : ; $T send-keys -t t -l "set oc" ; $T send-keys -t t Tab ; $T send-keys -t t -l "a" ; $T send-keys -t t Tab
  shown "options and their values complete" "^:set ocr=auto"
  $T send-keys -t t Escape
  sleep 0.2
  $T send-keys -t t '&' ; $T send-keys -t t C-u ; $T send-keys -t t -l "is:mar" ; $T send-keys -t t Tab
  shown "the filter language completes"  "^&is:marked"
  $T send-keys -t t Escape
  sleep 0.2
  $T send-keys -t t : ; $T send-keys -t t -l "echo first one" ; $T send-keys -t t Enter
  $T send-keys -t t : ; $T send-keys -t t -l "echo second" ; $T send-keys -t t Enter
  $T send-keys -t t : ; $T send-keys -t t Up
  shown "Up recalls the last command"    "^:echo second"
  $T send-keys -t t Up
  shown "and the one before"             "^:echo first one"
  $T send-keys -t t C-u ; $T send-keys -t t -l "so" ; $T send-keys -t t Up
  shown "Up finds what starts as typed"  "^:sort -year"
  $T send-keys -t t Escape
  sleep 0.2

  # the mouse: select text in the preview, paste it into a field
  mouse() { $T send-keys -t t -l "$(printf "$@")"; sleep 0.3; }
  row=$($T capture-pane -p -t t | grep -n 'A Note on Sieve' | head -1 | cut -d: -f1)
  before=$($T capture-pane -p -t t | sed -n "${row}p" | sed 's/Sieve.*//')
  col=$(($(printf '%s' "$before" | LC_ALL=C.UTF-8 wc -m) + 1))
  # both clicks in one write: two that arrive a moment apart are not a double click
  mouse '\033[<0;%d;%dM\033[<0;%d;%dm\033[<0;%d;%dM\033[<0;%d;%dm' "$col" "$row" "$col" "$row" "$col" "$row" "$col" "$row"
  expect "double click copies the word"  "Sieve" "$($T show-buffer 2>/dev/null)"
  sleep 0.6 # or the next press would be a third click, which takes the line
  mouse '\033[<0;%d;%dM' "$col" "$row"
  mouse '\033[<32;%d;%dM' "$((col + 12))" "$row"
  mouse '\033[<0;%d;%dm' "$((col + 12))" "$row"
  expect "a drag copies what it covers"  "Sieve Methods" "$($T show-buffer 2>/dev/null)"
  shown "and says so"                    "copied 13 characters"
  $T send-keys -t t : ; $T send-keys -t t -l "echo " ; $T send-keys -t t C-v
  shown "C-v pastes into the line being typed" ":echo Sieve Methods"
  $T send-keys -t t Enter
  shown "the pasted line runs"           "^Sieve Methods *$"
  $T send-keys -t t y y
  i=0; while [ "$($T show-buffer 2>/dev/null)" = "Sieve Methods" ] && [ $i -lt 40 ]; do sleep 0.05; i=$((i + 1)); done
  expect "yy copies the title"           "paper" "$($T show-buffer 2>/dev/null)"

  # outside the preview's text a drag selects what is drawn: the list, a line being typed
  row=$($T capture-pane -p -t t | grep -n '^ *— *paper' | head -1 | cut -d: -f1)
  before=$($T capture-pane -p -t t | sed -n "${row}p" | sed 's/paper.*//')
  col=$(($(printf '%s' "$before" | LC_ALL=C.UTF-8 wc -m) + 1))
  mouse '\033[<0;%d;%dM' "$col" "$row"
  mouse '\033[<32;%d;%dM' "$((col + 2))" "$row"
  mouse '\033[<0;%d;%dm' "$((col + 2))" "$row"
  expect "a drag in the list copies what it covers" "pap" "$($T show-buffer 2>/dev/null)"
  sleep 0.6
  $T send-keys -t t : ; $T send-keys -t t -l "echo hello world"
  wait_for "^:echo hello world"; row=$($T capture-pane -p -t t | grep -n '^:echo hello world' | head -1 | cut -d: -f1)
  mouse '\033[<0;7;%dM' "$row"
  mouse '\033[<32;11;%dM' "$row"
  mouse '\033[<0;11;%dm' "$row"
  expect "and in the line being typed"       "hello" "$($T show-buffer 2>/dev/null)"
  $T send-keys -t t C-u ; $T send-keys -t t -l "echo " ; $T send-keys -t t C-v
  shown "which can be pasted back into it"   "^:echo hello *$"
  $T send-keys -t t Escape
  sleep 0.6
  row=$($T capture-pane -p -t t | grep -n 'NORMAL' | head -1 | cut -d: -f1)
  mouse '\033[<0;4;%dM\033[<0;4;%dm\033[<0;4;%dM\033[<0;4;%dm' "$row" "$row" "$row" "$row"
  expect "a double click takes the word under it" "NORMAL" "$($T show-buffer 2>/dev/null)"
  sleep 0.6

  # a paste from the terminal is text, whatever is in it
  $T set-buffer "$(printf 'echo two\nlines ZZ')"
  $T send-keys -t t : ; $T paste-buffer -p -t t
  shown "a pasted line break does not submit" ":echo two lines ZZ"
  $T send-keys -t t Enter
  shown "the pasted text is one line"    "^two lines ZZ *$"
  $T set-buffer "ZZ"
  $T paste-buffer -p -t t
  shown "a paste outside a field runs nothing" "pasted text goes into a field"
  $T send-keys -t t : ; $T send-keys -t t -l "echo typed" ; $T send-keys -t t Escape
  sleep 0.2
  $T send-keys -t t : ; $T send-keys -t t -l "echo after escape" ; $T send-keys -t t Enter
  shown "Escape still cancels"           "^after escape *$"

  # windows are resized by dragging the line between them, or from the keyboard
  dcol() { screen | sed -n 5p | sed 's/│.*//' | LC_ALL=C.UTF-8 wc -m; }
  was=$(dcol)
  mouse '\033[<0;%d;5M' "$was"
  mouse '\033[<32;%d;5M' "$((was - 10))"
  mouse '\033[<0;%d;5m' "$((was - 10))"
  expect "dragging the line between windows moves it" "$((was - 10))" "$(dcol)"
  $T send-keys -t t M-Right
  sleep 0.3
  expect "Alt+Right moves it two columns right"  "$((was - 8))" "$(dcol)"
  $T send-keys -t t -l '\' ; $T send-keys -t t Left
  sleep 0.3
  expect "<Leader> and an arrow do the same"     "$((was - 10))" "$(dcol)"
  $T send-keys -t t '`'
  shown "the console opens"                      "console  "
  brow() { screen | grep -n '^ *console  ' | head -1 | cut -d: -f1; }
  was=$(brow)
  mouse '\033[<0;60;%dM' "$was"
  mouse '\033[<32;60;%dM' "$((was - 4))"
  mouse '\033[<0;60;%dm' "$((was - 4))"
  expect "dragging a window's bar up makes it taller" "$((was - 4))" "$(brow)"
  $T send-keys -t t '`'
  sleep 0.6

  # closing a window must leave nothing pointing at it (a sanitizer build
  # stops here if something does)
  $T send-keys -t t : ; $T send-keys -t t -l "only" ; $T send-keys -t t Enter
  $T send-keys -t t '`'
  shown "the console opens beside the only window" "console  "
  $T send-keys -t t '`' j
  $T send-keys -t t : ; $T send-keys -t t -l "echo list alive" ; $T send-keys -t t Enter
  shown "and closes without taking the list along" "^list alive *$"
  $T send-keys -t t : ; $T send-keys -t t -l 'lua lulibre.spawn(function() lulibre.spawn(function() lulibre.sleep(200) lulibre.exec("prompt command") end) lulibre.notify("answer: " .. tostring(lulibre.input{prompt="question: "})) end)'
  $T send-keys -t t Enter
  shown "a script asks a question"   "^question:"
  sleep 0.5
  $T send-keys -t t Escape
  shown "a question replaced by another prompt is answered" "^answer: nil"

  $T send-keys -t t g t
  shown "tui tree browser opens"     "browse  "
  $T send-keys -t t : ; $T send-keys -t t -l "only" ; $T send-keys -t t Enter
  sleep 0.3
  $T send-keys -t t q
  i=0; while screen | grep -q "browse  " && [ $i -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  shown "a panel closed as the only window gives way to the list" "Author  *Title"
  $T send-keys -t t q
  i=0; while [ ! -s "$t/rc" ] && [ $i -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  expect "tui exits cleanly" 0 "$(cat "$t/rc" 2>/dev/null)"

  # keys from init.lua: a leader, a screen's own keys, and reading the file again
  mkdir -p "$t/conf3"
  cat > "$t/conf3/init.lua" <<'LUA'
lulibre.o.leader = ","
lulibre.map("n", "<Leader>e", "echo the leader works")
lulibre.map("browse", "o", "open")
lulibre.map("n", "gz", "echo zed", "a key of my own, described")
lulibre.map("n", "gy", "echo why", false)
lulibre.map("line", "<C-g>", "cancel")
lulibre.map("panel", "<C-x>", "close")
LUA
  $T new-session -d -s t -x 120 -y 30 \
    "XDG_DATA_HOME='$t/data' '$bin' -C '$t/conf3' -L '$lib'; echo \$? > '$t/rc3'"
  shown "tui starts with a configuration"  "NORMAL"
  $T send-keys -t t , e
  shown "a <Leader> binding runs"          "^the leader works *$"
  $T send-keys -t t : ; $T send-keys -t t -l 'lua lulibre.notify("bound to " .. lulibre.key("echo the leader works"))'
  $T send-keys -t t Enter
  shown "and is named by the key it is on" "^bound to ,e *$"
  $T send-keys -t t "?"
  shown "? opens the help"                 "KEYS"
  # page down to the end of the keys, where bindings made later are listed
  found=no hidden=ok
  for n in 1 2 3 4 5 6 7 8 9 10 11 12 13 14; do
    screen | grep -q "gz  *a key of my own, described" && found=yes
    screen | grep -q "echo why" && hidden=shown
    $T send-keys -t t Space; sleep 0.15
  done
  expect "a binding's own description is listed" yes "$found"
  expect "a hidden binding stays out of the help" ok "$hidden"
  $T send-keys -t t q
  $T send-keys -t t g t
  shown "the tree browser opens"           "browse  "
  $T send-keys -t t "?"
  shown "? lists the screen's keys"        "KEYS HERE"
  shown "a remapped key first, with what it does" "o  l  .*open the branch"
  $T send-keys -t t q C-x
  i=0; while screen | grep -q "browse  " && [ $i -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  expect "a key put on the panels' close closes one" "" "$(screen | grep -o 'browse  ' | head -1)"
  $T send-keys -t t : ; $T send-keys -t t -l "echo not this" ; $T send-keys -t t C-g
  sleep 0.3
  $T send-keys -t t : ; $T send-keys -t t -l "echo but this" ; $T send-keys -t t Enter
  shown "a key put on the line's cancel cancels" "^but this *$"
  printf 'lulibre.map("n", "<Leader>e", "echo read again")\n' > "$t/conf3/init.lua"
  $T send-keys -t t , R
  shown "<Leader>R reads init.lua again"   "read .*init.lua again"
  $T send-keys -t t , e
  shown "and its bindings are the ones in force" "^read again *$"
  $T send-keys -t t q
  i=0; while [ ! -s "$t/rc3" ] && [ $i -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  expect "and exits cleanly" 0 "$(cat "$t/rc3" 2>/dev/null)"

  # with a sync folder set, a tab line says which of the two the list shows
  if "$bin" --clean -L "$lib" run "$(dirname "$0")/luv_probe.lua" >/dev/null 2>&1; then
    mkdir -p "$t/incoming"
    printf 'A text file waiting to be added\n' > "$t/incoming/note.txt"
    $T new-session -d -s t -x 120 -y 30 \
      "XDG_DATA_HOME='$t/data' '$bin' --clean -L '$lib' -o sync_dir='$t/incoming' -o sync_propose=never; echo \$? > '$t/rc2'"
    shown "source tabs appear"           " 1  Library  2 "
    $T send-keys -t t : ; $T send-keys -t t Up
    shown "history is kept between sessions" "^:echo but this"
    $T send-keys -t t Escape
    sleep 0.2
    shown "and name the sync folder"     " 2  Sync folder  0 "
    $T send-keys -t t 2
    shown "2 shows the sync folder"      " SYNC "
    shown "which now holds the file"     " 2  Sync folder  1 "
    shown "and lists it"                 "note"
    $T send-keys -t t 1
    shown "1 goes back to the library"   "all books"
    $T send-keys -t t -l "$(printf '\033[<0;24;1M\033[<0;24;1m')"
    shown "a click on the tab switches too" " SYNC "
    $T send-keys -t t q
    i=0; while [ ! -s "$t/rc2" ] && [ $i -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
    expect "and exits cleanly" 0 "$(cat "$t/rc2" 2>/dev/null)"
  else
    echo "skip  sync folder tabs (luv is not installed for this Lua version)"
  fi
  $T kill-server 2>/dev/null || true
else
  echo "skip  tui tests (tmux not found)"
fi

[ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
