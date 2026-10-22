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

# (all of them: a crash's report goes to the state directory, and lulibre's
# systemd units are found under HOME)
export XDG_DATA_HOME="$t/data" XDG_STATE_HOME="$t/state" XDG_CONFIG_HOME="$t/config" HOME="$t/home"
mkdir -p "$HOME"
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
expect   "nothing is non-catalog to begin with" 0 "$(run query -c is:noncatalog)"
contains "stats counts non-catalog works apart" "non-catalog works" "$(run stats)"
contains "holdout wants confirmed records" "too few to leave some out" "$(run run holdout 2>&1 || true)"

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
# a C module that crashes as it loads is refused, not loaded (one built for another Lua does)
if command -v cc >/dev/null 2>&1; then
  printf 'print(_VERSION:match("%%d+%%.%%d+"))\n' > "$t/v.lua"
  luav=$(run run "$t/v.lua" 2>/dev/null)
  mkdir -p "$t/rocks/lib/lua/$luav"
  printf 'int luaopen_crashmod(void *L) { (void)L; *(volatile int *)0 = 1; return 0; }\n' > "$t/crash.c"
  if cc -shared -fPIC -o "$t/rocks/lib/lua/$luav/crashmod.so" "$t/crash.c" 2>/dev/null; then
    printf 'print(pcall(require, "crashmod"))\n' > "$t/c.lua"
    contains "a C module that crashes is refused" "crashes when it is loaded" "$(run -o rocks_tree="$t/rocks" run "$t/c.lua" 2>&1)"
  fi
fi
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
contains "a command that is a script says what it is with -h" "usage: lulibre enrich" "$(run enrich -h 2>&1)"
contains "from the script's own opening lines" "--plan" "$(run enrich -h 2>&1)"
contains "propose is a command of the command line" "proposal" "$(run propose id:1 2>&1)"

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
contains "a fresh one is not fetched again"  "nothing to fetch" "$(run run arxiv-fetch --with "$t/nokaggle" 2>&1)"

# the databases for looking books up offline: what there is, and the question
out=$(run datasets list 2>&1)
contains "datasets says what there is"        "Useful if you have books with an ISBN" "$out"
contains "and what is on this machine already" "arxiv        arXiv's records  [on this machine:" "$out"
contains "and what is not"                    "openlibrary  Open Library's editions and authors  [not on this machine]" "$out"
contains "asked which to fetch, nothing is"   "nothing fetched" "$(printf '\n' | run datasets 2>&1)"
contains "an answer that is none of them"     "'9' is not one of them" "$(printf '9\n' | run datasets 2>&1)"
contains "one that is here is left alone"     "nothing to fetch" "$(printf '1\n' | run datasets --with "$t/nokaggle" 2>&1)"
contains "a name that is none"                "there is no dataset" "$(run datasets fetch nope 2>&1)"

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
contains "and when a script fails there"  "Quit, run make in that tree" "$(tree run "$t/bad.lua" 2>&1 || true)"

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
    "XDG_DATA_HOME='$t/data' '$bin' --clean -L '$lib' 2>'$t/err'; echo \$? > '$t/rc'"
  shown "tui starts"                 "NORMAL"
  shown "tui lists both books"       "1/2"
  shown "tui previews indexed text"  "A Note on Sieve Methods"

  # the list as a tree
  $T send-keys -t t : ; $T send-keys -t t -l "group subject" ; $T send-keys -t t Enter
  shown "the list grouped by subject"            "all books, by subject"
  shown "subjects nest, a short list shown open"  "▾ number-theory"
  shown "the books stand under their headings"    "▾ additive"
  shown "what has no subject, last"               "▾ (none)"
  $T send-keys -t t g g h
  shown "a heading closes"                        "▸ math"
  expect "and what was under it is put away" "" "$(screen | grep -o '[▾▸] number-theory' | head -1)"
  $T send-keys -t t Space
  shown "Space on a heading marks its books"      "1 marked"
  $T send-keys -t t : ; $T send-keys -t t -l "mark none" ; $T send-keys -t t Enter
  $T send-keys -t t g g Enter
  shown "Enter opens it again"                    "▾ math"
  $T send-keys -t t z M
  shown "zM closes them all"                      "▸ (none)"
  $T send-keys -t t z R
  shown "zR opens them all"                       "▾ additive"
  $T send-keys -t t "/" ; $T send-keys -t t -l "paper" ; $T send-keys -t t Enter
  shown "a search finds a book under a heading"   "› .*paper"
  $T send-keys -t t Escape
  $T send-keys -t t : ; $T send-keys -t t -l "group folder" ; $T send-keys -t t Enter
  shown "grouped as the library is filed on disk" "▾ Paul Erdos"
  $T send-keys -t t g h
  shown "gh asks what to group by"                "group the list by"
  $T send-keys -t t Escape
  $T send-keys -t t s
  shown "s asks what to sort by"                  "sort the books by"
  $T send-keys -t t Escape
  $T send-keys -t t g H
  shown "gH gives the plain list back"            "the plain list"
  expect "with no headings" "" "$(screen | grep -o '▾' | head -1)"

  # the propose-and-review dialog, and the weights of the sources
  $T send-keys -t t : ; $T send-keys -t t -l 'lua local _ = lulibre.store("DELETE FROM proposals")' ; $T send-keys -t t Enter
  sleep 0.3
  $T send-keys -t t '\' p r
  shown "Leader pr opens the dialog"              "propose, then review"
  shown "with what is asked, as boxes"            "\[x\]  the files themselves"
  shown "what is not there greyed, with why"      "(nothing learned yet"
  $T send-keys -t t G
  shown "and what review will show"               "show nothing below a confidence of"
  $T send-keys -t t g g j
  $T send-keys -t t l
  shown "a choice steps on"                       "everything the list shows (2)"
  $T send-keys -t t w
  shown "w proposes, and review opens"            "review  [0-9]* pending"
  shown "on the run, a tab beside all that waits" "books ([0-9]*)   all waiting ([0-9]*)"
  shown "which says how to be rid of it"          "drops what this run added"
  $T send-keys -t t s
  shown "review can put the most disputed first"  "most disputed first"
  $T send-keys -t t l
  i=0; while screen | grep -q "drops what this run added" && [ $i -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  expect "l goes to everything that waits" "" "$(screen | grep -o 'drops what this run added' | head -1)"
  $T send-keys -t t h
  shown "h comes back to the run"                 "drops what this run added"
  $T send-keys -t t D
  shown "D asks before dropping the run"          "proposals* this run added? (deleted, not rejected"
  $T send-keys -t t y Enter
  shown "and with the run gone nothing is left"   "nothing left to review"
  $T send-keys -t t : ; $T send-keys -t t -l 'lua lulibre.status("t", "BUSY HERE", "warn")' ; $T send-keys -t t Enter
  shown "a script can keep a badge in the status line" "NORMAL  *BUSY HERE"
  $T send-keys -t t : ; $T send-keys -t t -l 'lua lulibre.status("t")' ; $T send-keys -t t Enter
  i=0; while screen | grep -q "BUSY HERE" && [ $i -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  expect "and take it away" "" "$(screen | grep -o 'BUSY HERE' | head -1)"
  i=0; while screen | grep -q "review  " && [ $i -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  $T send-keys -t t : ; $T send-keys -t t -l 'lua local _ = lulibre.store("DELETE FROM proposals")' ; $T send-keys -t t Enter
  sleep 0.3
  $T send-keys -t t : ; $T send-keys -t t -l "weigh" ; $T send-keys -t t Enter
  shown ":weigh measures the sources"             "each source measured against"
  $T send-keys -t t '\' w
  shown "Leader w shows what each is believed"    "how much each source is believed"
  $T send-keys -t t q
  i=0; while screen | grep -q "how much each source" && [ $i -lt 100 ]; do sleep 0.05; i=$((i + 1)); done

  # dialogs over what lulibre already does
  $T send-keys -t t g g j '\' e
  shown "Leader e: what a lookup would ask"       "look up 1 book"
  shown "service by service"                      "crossref  *[0-9]* works* to ask about"
  $T send-keys -t t q
  i=0; while screen | grep -q "look up 1 book" && [ $i -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  $T send-keys -t t '\' c
  shown "Leader c: one change to every selected book" "change 1 book at once"
  shown "with a line for each thing to set"       "add the subject"
  $T send-keys -t t w
  shown "nothing filled in changes nothing"       "nothing was filled in"
  $T send-keys -t t '\' d
  shown "Leader d: the databases, with boxes"     "databases for looking books up"
  shown "and what is on this machine"            "arxiv  *arXiv's records  *on this machine:"
  $T send-keys -t t q
  i=0; while screen | grep -q "databases for looking" && [ $i -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  $T send-keys -t t g g Space Space
  shown "two books marked"                        "2 marked"
  $T send-keys -t t g g Space
  shown "unmarking one says how many are still marked" "^1 marked"
  $T send-keys -t t g g Space
  $T send-keys -t t '\' Space
  shown "Leader Space unmarks them all, and says how many" "^2 unmarked"
  $T send-keys -t t '\' Space
  shown "with nothing marked, it says so"         "^no books were marked"
  $T send-keys -t t g g

  # selecting text in the preview with the keys
  $T send-keys -t t g g v
  shown "v puts a cursor in the preview"          "^select: "
  $T send-keys -t t V y
  shown "V and y copy a line"                     "^copied [0-9]* characters"
  expect "what was copied is the page's first line" "A Note on Sieve Methods" "$($T show-buffer 2>/dev/null | head -1)"
  $T send-keys -t t v w v w w y
  shown "v ... v ... y copies a stretch"          "^copied [0-9]* characters"
  expect "from where it began to the cursor" "Note on S" "$($T show-buffer 2>/dev/null | head -1)"
  $T send-keys -t t v
  sleep 0.2
  $T send-keys -t t Escape # (alone: Escape with a key right behind it reads as Alt and that key)
  sleep 0.3
  $T send-keys -t t j
  shown "Esc leaves, and the keys are the list's again" "2/2"
  $T send-keys -t t k

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
  # (where a sanitizer build reports, too: an error or a leak at exit)
  expect "and writes nothing to stderr" "" "$(cat "$t/err" 2>/dev/null)"

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
    "XDG_DATA_HOME='$t/data' '$bin' -C '$t/conf3' -L '$lib' 2>'$t/err3'; echo \$? > '$t/rc3'"
  shown "tui starts with a configuration"  "NORMAL"
  $T send-keys -t t , e
  shown "a <Leader> binding runs"          "^the leader works *$"
  $T send-keys -t t : ; $T send-keys -t t -l 'lua lulibre.notify("bound to " .. lulibre.key("echo the leader works"))'
  $T send-keys -t t Enter
  shown "and is named by the key it is on" "^bound to ,e *$"
  $T send-keys -t t "?"
  shown "? opens the help, under headings"  "▾ Getting started"
  shown "the others closed, with their counts" "▸ Windows   ([0-9]*)"
  $T send-keys -t t "/"
  shown "/ searches the keys"               "^search the keys and commands:"
  $T send-keys -t t -l "my own"
  shown "a binding's own description is found" "gz  *a key of my own, described"
  $T send-keys -t t C-u ; $T send-keys -t t -l "why"
  shown "the search follows what is typed"  "matching 'why'"
  expect "a hidden binding stays out of the help" "" "$(screen | grep -o 'echo why' | head -1)"
  $T send-keys -t t C-u ; $T send-keys -t t -l "leave lulibre" ; $T send-keys -t t Enter
  shown "a key is found by what it does"    "q  *ZZ  *leave lulibre"
  $T send-keys -t t BSpace
  shown "Backspace shows everything again"  "keys, by what they are for"
  $T send-keys -t t C
  shown "C closes every heading"            "▸ Getting started"
  $T send-keys -t t g g Enter
  shown "Enter opens the one under the cursor" "▾ Getting started"
  $T send-keys -t t q
  i=0; while screen | grep -q "Getting started" && [ $i -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  $T send-keys -t t : ; $T send-keys -t t -l "help filters" ; $T send-keys -t t Enter
  shown ":help with a guide's name shows it" "help: filters"
  $T send-keys -t t q
  sleep 0.2
  $T send-keys -t t : ; $T send-keys -t t -l "help enrich" ; $T send-keys -t t Enter
  shown ":help with a word shows the part about it" "LOOKING BOOKS UP"
  $T send-keys -t t q
  sleep 0.2
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
  expect "writing nothing to stderr" "" "$(cat "$t/err3" 2>/dev/null)"

  # with a sync folder set, a tab line says which of the two the list shows
  if "$bin" --clean -L "$lib" run "$(dirname "$0")/luv_probe.lua" >/dev/null 2>&1; then
    mkdir -p "$t/incoming"
    printf 'A text file waiting to be added\n' > "$t/incoming/note.txt"
    $T new-session -d -s t -x 120 -y 30 \
      "XDG_DATA_HOME='$t/data' '$bin' --clean -L '$lib' -o sync_dir='$t/incoming' -o sync_propose=never 2>'$t/err2'; echo \$? > '$t/rc2'"
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
    $T send-keys -t t '\' s
    shown "Leader s: what to do with the waiting files" "1 file waiting in the sync folder"
    shown "add, move or drop, as a choice"        "add to the library; the files stay"
    $T send-keys -t t q
    i=0; while screen | grep -q "waiting in the sync folder" && [ $i -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
    # a staged file is edited like a book, before it is in calibre
    $T send-keys -t t e
    shown "e edits a staged file"        "edit .*note"
    $T send-keys -t t q
    sleep 0.3
    # the sync folder in a column beside the library
    $T send-keys -t t 1
    shown "back in the library"          "all books"
    $T send-keys -t t g b
    shown "gb puts the sync folder beside the library" "sync folder beside the library   1 file, 1 new"
    shown "the waiting file in its column" "new  *note"
    shown "and the library's list beside it" "Paul Erd"
    $T send-keys -t t "?"
    shown "its keys are listed"          "add this file to the library"
    $T send-keys -t t q
    sleep 0.2
    $T send-keys -t t e
    shown "e edits the file from there"  "edit .*note"
    $T send-keys -t t q
    sleep 0.3
    $T send-keys -t t q
    i=0; while screen | grep -q "beside the library" && [ $i -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
    expect "q closes the column" "" "$(screen | grep -o 'beside the library' | head -1)"
    $T send-keys -t t q
    i=0; while [ ! -s "$t/rc2" ] && [ $i -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
    expect "and exits cleanly" 0 "$(cat "$t/rc2" 2>/dev/null)"
    expect "writing nothing to stderr" "" "$(cat "$t/err2" 2>/dev/null)"
  else
    echo "skip  sync folder tabs (luv is not installed for this Lua version)"
  fi
  $T kill-server 2>/dev/null || true
else
  echo "skip  tui tests (tmux not found)"
fi

[ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
