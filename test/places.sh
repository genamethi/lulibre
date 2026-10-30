#!/bin/sh
# Where a screen's views go (scrnman.create's place, tab), in the interface,
# in a private tmux server: a band along the bottom, a column down the
# left, over the list, tiled beside the focused window, a box floating
# above the windows, over all of them; the pager and the picker above the
# windows, giving the focus back; help, the focused screen's first; the
# guides, with links; hints set for lulibre's places; and a tab screen's
# tab in the bar.
#   places.sh BUILT_BINARY
set -eu
bin=$(realpath "$1")
src=$(cd "$(dirname "$0")" && pwd)
if ! command -v tmux >/dev/null; then
  echo "places: tmux not found, skipping"
  exit 0
fi
t=$(mktemp -d)
T="tmux -L lulibre-places-$$"
trap 'rm -rf "$t"; $T kill-server 2>/dev/null || true' EXIT
sh "$src/mklib.sh" "$t/lib" >/dev/null 2>&1
mkdir -p "$t/config/lulibre/docs/more"
# a guide of the user's, in a folder below their docs/, linking to lulibre's
cat >"$t/config/lulibre/docs/more/mine.md" <<'MD'
# Mine

## Plums

Plums are kept [with the keys](keys.md#the-leader-key).
MD
# a script :run finds, by completion and in its picker
mkdir -p "$t/config/lulibre/scripts"
echo 'uiman.notify("quince ran")' >"$t/config/lulibre/scripts/quince.lua"
cat >"$t/config/lulibre/init.lua" <<'LUA'
for _, kind in ipairs { "band", "column", "over", "tiled", "float", "overlay" } do
  scrnman.create("p" .. kind, { place = { kind = kind }, actions = { { "hello", "h", "say hello" } }, hint = { "hello" } })
  cmdman.create("p" .. kind, function() uiman.list { title = "P-" .. kind, screen = "p" .. kind, items = { "row" } } end)
end
keymap.set("pband", "y", "hello", { desc = "greet the row" })
keymap.set("console", "c", "clear", { hidden = true })
scrnman.set("console", { hint = { "close" } })
scrnman.set("pager", { hint = {} })
scrnman.create("ptab", { title = "Tabbed", tab = true })
cmdman.create("ptab", function() uiman.list { title = "P-tab", screen = "ptab", items = { "row" } } end)
LUA

screen() { $T capture-pane -p -t s; }
wait_for() { # text: up to 5 s
  i=0
  while [ $i -lt 50 ]; do
    case $(screen) in *"$1"*) return 0 ;; esac
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}
# the row and column (from 1) where text first is, "0 0" for nowhere
at() {
  screen | awk -v s="$1" '{ i = index($0, s); if (i) { print NR, i; found = 1; exit } } END { if (!found) print 0, 0 }'
}

fails=0
check() { # what, then a test
  what=$1
  shift
  if "$@"; then echo "ok    $what"; else echo "FAIL  $what"; screen | sed 's/^/      /'; fails=$((fails + 1)); fi
}

$T new-session -d -s s -x 120 -y 30 "env TERM=xterm-256color XDG_CONFIG_HOME='$t/config' XDG_DATA_HOME='$t/data' XDG_STATE_HOME='$t/state' '$bin' -L '$t/lib'; sleep 30"
wait_for "Library" || true
sleep 0.5

open() { # a command, then the panel's title appears
  $T send-keys -t s ":$1" Enter
  wait_for "$2" || true
  sleep 0.3
}
close() {
  $T send-keys -t s q
  sleep 0.4
}

open pband P-band
set -- $(at P-band)
check "band: along the bottom, across the screen" test "$1" -gt 12 -a "$2" -le 3
close
open pcolumn P-column
set -- $(at P-column)
check "column: down the left, from the top" test "$1" -le 3 -a "$2" -le 3
close
open pover P-over
set -- $(at P-over)
check "over: in the list's place, the list's window" test "$1" -le 3 -a "$2" -le 3
close
open ptiled P-tiled
set -- $(at P-tiled)
check "tiled: beside the focused window, which it splits" test "$1" -le 3 -a "$2" -gt 10 -a "$2" -lt 70
close
open pfloat P-float
set -- $(at P-float)
frame=$(screen | sed -n "$(($1 - 1))p")
check "float: a box above the windows, framed" test "$1" -gt 3 -a "$2" -gt 10
check "with its frame above it" sh -c "case '$frame' in *╭*) exit 0 ;; *) exit 1 ;; esac"
check "and its rows, without columns given" sh -c "$T capture-pane -p -t s | grep -q '│ row'"
check "and the action's hint in its bar" sh -c "screen() { $T capture-pane -p -t s; }; screen | grep -q 'h hello'"
close
open poverlay P-overlay
set -- $(at P-overlay)
check "overlay: over every window, from the top left" test "$1" -le 3 -a "$2" -le 3
check "and none of them shows through" sh -c "! $T capture-pane -p -t s | grep -q 'Notes'"
close
# the pager and the picker are floating windows too, which take every key
$T send-keys -t s "?"
wait_for "COMMANDS" || true
check "? opens the pager over the windows" sh -c "$T capture-pane -p -t s | grep -q 'KEYS'"
$T send-keys -t s x
sleep 0.4
check "and a key it has no action for closes it" sh -c "! $T capture-pane -p -t s | grep -q 'COMMANDS'"
open pband P-band
$T send-keys -t s ":pick books" Enter
wait_for "books" || true
sleep 0.3
check "the picker opens over a panel" sh -c "$T capture-pane -p -t s | grep -q '╭'"
$T send-keys -t s Escape
sleep 0.4
$T send-keys -t s q
sleep 0.4
check "and closing it gives the focus back to the panel: q closes the panel" sh -c "! $T capture-pane -p -t s | grep -q 'P-band'"
# ? shows the focused screen's keys first, under headings that open and close
open pband P-band
$T send-keys -t s "?"
wait_for "KEYS" || true
check "? in a screen's panel: its actions first, open" sh -c "screen() { $T capture-pane -p -t s; }; screen | grep -A1 ' pband ' | grep -q 'greet the row'"
check "then a panel's movement, open" sh -c "$T capture-pane -p -t s | grep -q 'down a row'"
check "and the global keys closed" sh -c "! $T capture-pane -p -t s | grep -q 'move +1'"
$T send-keys -t s z M
sleep 0.3
check "zM closes every heading" sh -c "! $T capture-pane -p -t s | grep -q 'greet the row'"
$T send-keys -t s / g r e e t Enter
sleep 0.3
check "/ finds a line under a closed heading and opens it" sh -c "$T capture-pane -p -t s | grep -q '› .*greet the row'"
$T send-keys -t s q
sleep 0.3
check "q leaves help for the panel" sh -c "$T capture-pane -p -t s | grep -q 'P-band' && ! $T capture-pane -p -t s | grep -q 'KEYS'"
close
$T send-keys -t s "?"
wait_for "KEYS" || true
check "from the list: its keys first, open" sh -c "$T capture-pane -p -t s | grep -q 'move +1'"
check "and pband's heading closed, as it was left" sh -c "! $T capture-pane -p -t s | grep -q 'greet the row'"
$T send-keys -t s q
sleep 0.3
$T send-keys -t s ":help-plain" Enter
wait_for "KEYS" || true
$T send-keys -t s / f o r g e t Enter
sleep 0.3
check "an action keymap.set hid is left out" sh -c "$T capture-pane -p -t s | grep -q 'no line holds it'"
$T send-keys -t s q
sleep 0.3
# the guides, as vim's help
$T send-keys -t s ":help 'ocr'" Enter
wait_for "help: configuration" || true
check ":help 'ocr' opens the setting's line in configuration.md, at the top" sh -c "$T capture-pane -p -t s | sed -n 3p | grep -q 'ocr .*never'"
check "and scrnman.set took the overlay's hint away" sh -c "! $T capture-pane -p -t s | sed -n 2p | grep -q 'toggle'"
$T send-keys -t s q
sleep 0.3
$T send-keys -t s ":help plums" Enter
wait_for "help: more/mine" || true
check "a guide in docs/ under the configuration folder, found by its heading" sh -c "$T capture-pane -p -t s | grep -q 'Plums are kept'"
$T send-keys -t s j j K
wait_for "help: keys" || true
check "K follows its link into lulibre's keys.md, at the heading" sh -c "$T capture-pane -p -t s | sed -n 3p | grep -q 'THE LEADER KEY'"
$T send-keys -t s C-t
sleep 0.3
check "<C-t> goes back" sh -c "$T capture-pane -p -t s | grep -q 'help: more/mine'"
$T send-keys -t s Tab
sleep 0.3
check "<Tab> forward again" sh -c "$T capture-pane -p -t s | grep -q 'help: keys'"
$T send-keys -t s q
sleep 0.3
$T send-keys -t s "?"
wait_for "KEYS" || true
$T send-keys -t s j K
sleep 0.4
check "on ?, K on a key: what the guides say of it" sh -c "$T capture-pane -p -t s | grep -q 'help: keys'"
$T send-keys -t s q
sleep 0.3
$T send-keys -t s ":help xylograph" Enter
sleep 0.4
check "a word no guide has: said" sh -c "$T capture-pane -p -t s | grep -q 'say nothing about'"
$T send-keys -t s ":help calibredb" Enter
wait_for "MENTION IT" || true
check "a word without a tag: the lines that mention it" sh -c "$T capture-pane -p -t s | grep -q 'api:[0-9]'"
$T send-keys -t s j K
wait_for "help: api" || true
check "K on one: the guide, that line at the top" sh -c "$T capture-pane -p -t s | sed -n 3,4p | grep -qi 'calibredb'"
$T send-keys -t s q
sleep 0.3
# Markdown from a script, laid out as the guides are
$T send-keys -t s ':lua uiman.pager("notes", "# Hello\n\nSome **bold** and a [link](keys.md#the-leader-key)\n", {markdown = true})' Enter
wait_for "HELLO" || true
check "uiman.pager lays Markdown out" sh -c "$T capture-pane -p -t s | grep -q 'Some bold and a link' && ! $T capture-pane -p -t s | grep -q '\\*\\*'"
$T send-keys -t s j j K
wait_for "help: keys" || true
check "and its links lead into the guides" sh -c "$T capture-pane -p -t s | sed -n 3p | grep -q 'THE LEADER KEY'"
$T send-keys -t s q
sleep 0.3
$T send-keys -t s ":run qui" Tab
sleep 0.4
check ":run completes a script's name" sh -c "$T capture-pane -p -t s | tail -1 | grep -q ':run quince'"
$T send-keys -t s Escape
sleep 0.2
$T send-keys -t s ":run" Enter
sleep 0.4
$T send-keys -t s q u i n Enter
wait_for "quince ran" || true
check "and :run alone picks one, which runs" sh -c "$T capture-pane -p -t s | grep -q 'quince ran'"
$T send-keys -t s ":help plu" Tab
sleep 0.4
check "Tab completes a tag" sh -c "$T capture-pane -p -t s | tail -1 | grep -q ':help Plums'"
$T send-keys -t s Escape
sleep 0.2
$T send-keys -t s '`'
sleep 0.4
check "the console's bar shows the hint scrnman.set gave it" sh -c "$T capture-pane -p -t s | grep 'console' | grep -q 'q close' && ! $T capture-pane -p -t s | grep -q 'e errors'"
$T send-keys -t s '`'
sleep 0.3
check "the bar has a tab for a tab screen" sh -c "$T capture-pane -p -t s | head -1 | grep -q 'Tabbed'"
open ptab P-tab
$T send-keys -t s ":source library" Enter
sleep 0.5
check "and :source library closes it" sh -c "! $T capture-pane -p -t s | grep -q 'P-tab'"
$T send-keys -t s ":q" Enter
[ $fails -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
