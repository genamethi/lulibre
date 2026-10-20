#!/bin/sh
# Keys as a terminal sends them, outside tmux (test/terminal.py): plain, and
# in the kitty keyboard protocol that ghostty and kitty speak, where a
# shifted key comes as the key and Shift with the text it types (":" is ";"
# with Shift). Touches nothing outside a temporary directory.
set -eu

bin=$(realpath "$1")
src=$(cd "$(dirname "$0")" && pwd)
command -v python3 >/dev/null || { echo "terminal: python3 not found, skipping"; exit 0; }

t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
sh "$src/mklib.sh" "$t/lib"
export XDG_DATA_HOME="$t/data" XDG_CONFIG_HOME="$t/config"
"$bin" --clean -L "$t/lib" index >/dev/null 2>&1

fails=0
contains() { # description, needle, haystack
  case $3 in *"$2"*) echo "ok    $1" ;; *) echo "FAIL  $1: '$2' not in: $3"; fails=$((fails + 1)) ;; esac
}
# shifted symbols and a capital, typed into the command line after ":"
text='Typed: a?b&c! (x_y) {z}'
for mode in plain kitty; do
  python3 -I "$src/terminal.py" "$bin" "$t/lib" "$t/$mode.log" $mode "$text" ||
    { echo "FAIL  $mode: lulibre did not end well (status $?)"; fails=$((fails + 1)); }
  log=$(cat "$t/$mode.log" 2>/dev/null || true)
  contains "$mode keys: \":\" opens the command line, and shifted keys type what they show" "info  $text" "$log"
  contains "$mode keys: Tab goes to the panels" "no panel is open" "$log"
done
[ $fails -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
