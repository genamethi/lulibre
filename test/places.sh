#!/bin/sh
# Where a screen's views go (scrnman.create's place, tab), in the interface,
# in a private tmux server: a band along the bottom, a column down the
# left, over the list, tiled beside the focused window, a box floating
# above the windows, over all of them; the pager and the picker above the
# windows, giving the focus back; and a tab screen's tab in the bar.
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
mkdir -p "$t/config/lulibre"
cat >"$t/config/lulibre/init.lua" <<'LUA'
for _, kind in ipairs { "band", "column", "over", "tiled", "float", "overlay" } do
  scrnman.create("p" .. kind, { place = { kind = kind }, actions = { { "hello", "h", "say hello" } }, hint = { "hello" } })
  cmdman.create("p" .. kind, function() uiman.list { title = "P-" .. kind, screen = "p" .. kind, items = { "row" } } end)
end
keymap.set("pband", "y", "hello", { desc = "greet the row" })
keymap.set("console", "c", "clear", { hidden = true })
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
check "the bar has a tab for a tab screen" sh -c "$T capture-pane -p -t s | head -1 | grep -q 'Tabbed'"
open ptab P-tab
$T send-keys -t s ":source library" Enter
sleep 0.5
check "and :source library closes it" sh -c "! $T capture-pane -p -t s | grep -q 'P-tab'"
$T send-keys -t s ":q" Enter
[ $fails -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
