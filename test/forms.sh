#!/bin/sh
# End to end, by keystroke: the edit form, review, removal and orphans, typed
# into the interface through a private tmux server and written straight to a
# throwaway library (no content server).
#
# Runs inside a private network namespace, like offline.sh, and skips,
# successfully, where that or calibre or tmux is not to be had. Touches
# nothing outside a temporary directory.
set -eu

bin=$(realpath "$1")
for tool in unshare calibredb tmux; do
  command -v $tool >/dev/null || { echo "forms: $tool not found, skipping"; exit 0; }
done
if [ -z "${LULIBRE_FORMS_NS:-}" ]; then
  unshare -rn true 2>/dev/null || { echo "forms: cannot create a network namespace, skipping"; exit 0; }
  exec unshare -rn env LULIBRE_FORMS_NS=1 sh "$0" "$bin"
fi
"$bin" --clean run "$(dirname "$0")/luv_probe.lua" >/dev/null 2>&1 || {
  echo "forms: the luv rock is not installed for this Lua version, skipping"; exit 0; }

t=$(mktemp -d)
T="tmux -L lulibre-forms-$$"
trap '$T kill-server 2>/dev/null; rm -rf "$t"' EXIT
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
pdf "$t/src/rings.pdf" "Rings" "Sam Poe"
pdf "$t/src/rings2.pdf" "Rings, again" "Sam Poe"
cdb="calibredb --with-library $lib"
$cdb add "$t/src/knots.pdf" --title "Knots" --authors "Ann Lee" --tags "math, topology" >/dev/null 2>&1
$cdb add "$t/src/sieve.pdf" --title "Sieve" --authors "Jane Roe" >/dev/null 2>&1
$cdb add "$t/src/rings.pdf" --title "Rings" --authors "Sam Poe" >/dev/null 2>&1
$cdb add --duplicates "$t/src/rings2.pdf" --title "Rings" --authors "Sam Poe" >/dev/null 2>&1
$cdb add --duplicates "$t/src/knots.pdf" --title "KNOTS, A SECOND COPY" --authors Unknown >/dev/null 2>&1
$cdb set_metadata 1 --field publisher:Acme --field series:Lectures >/dev/null 2>&1

run() { "$bin" --clean -L "$lib" "$@"; }
lua() { printf '%s\n' "$1" > "$t/s.lua"; run run "$t/s.lua" 2>&1; }
field() { lua "local b = lulibre.book($1) print(b and require('lulibre.edit').current(b, '$2') or 'gone')"; }
fails=0
expect() { # description, expected, actual
  if [ "$2" = "$3" ]; then echo "ok    $1"; else echo "FAIL  $1: expected '$2', got '$3'"; fails=$((fails + 1)); fi
}
screen() { $T capture-pane -p -t t 2>/dev/null; }
wait_for() { # pattern
  i=0
  while [ $i -lt 200 ]; do
    screen | grep -q -- "$1" && return 0
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}
shown() { # description, pattern
  if wait_for "$2"; then echo "ok    $1"; else
    echo "FAIL  $1: '$2' is not on the screen:"; screen | grep -v '^ *$' | sed 's/^/        /'; fails=$((fails + 1))
  fi
}
k() { for key; do $T send-keys -t t "$key"; done; }
lit() { $T send-keys -t t -l "$1"; }

run index >/dev/null 2>&1
lua 'lulibre.propose(1, "publisher", "Wrong Press", { source = "test", confidence = 0.9 })
lulibre.propose(2, "title", "Sieve Notes", { source = "test", confidence = 0.9 })
lulibre.propose(3, "title", "Rings and Things", { source = "test", confidence = 0.99 })' >/dev/null

$T new-session -d -s t -x 140 -y 40 "'$bin' --clean -L '$lib' 2>'$t/err'; echo \$? > '$t/rc'"
shown "the interface starts"                  "1/5"

# ---- a narrowed list says that it is, and how to undo it
k "&"; lit "id:2"; k Enter
shown "an active filter is labelled"          "filter id:2"
shown "with how much of the library it shows" "1 of 5"
shown "and how to clear it"                   "<BS> shows all"
k BSpace
shown "Backspace shows everything again"      "all books"

# ---- a title in capitals, put in title case
expect "is:capstitle finds a title in capitals" 1 "$(run query -c is:capstitle 2>/dev/null)"
k "&"; lit "is:capstitle"; k Enter
wait_for "1 of 5"
k g T
shown "gT rewrites it"                        "changed 1 book"
expect "in title case, minor words small"     "Knots, a Second Copy" "$(field 5 title)"
k g T
shown "and has nothing more to do"            "0 of 5"
k BSpace
wait_for "all books"
k Escape
sleep 0.2

# ---- the edit form: a field emptied and entered is blanked
k "&"; lit "id:1"; k Enter
wait_for "1 of 5"
k e
shown "the edit form opens"                   "edit  1  Knots"
k j j Enter
shown "the field holds the current value"     "tags: math, topology"
k C-u BSpace BSpace BSpace
shown "backspacing an empty field keeps it open" "^tags: *$"
k Enter
shown "the form shows the blank to be written" "(blank)"
k w
shown "the change is written"                 "changed 1 book"
expect "the tags are gone"                    "" "$(field 1 tags)"
k Escape # clears the message line, so the next "changed" is the next write's
sleep 0.2
k e
shown "the edit form opens again"             "edit  1  Knots"
shown "its hint names the keys"               "c clear"
k j j j c
shown "c blanks the field under the cursor"   "cleared"
k "?"
shown "? lists the form's keys"               "blank the field"
k q w
shown "and the blank is written"              "changed 1 book"
expect "the series is gone"                   "" "$(field 1 series)"
k BSpace
wait_for "all books"

# ---- review: a proposal edited to nothing blanks the field
k g r
shown "review opens"                          "review  3 pending"
shown "with what waits for each book"         "1 to decide, surest 0.99"
first=$(screen | grep -n "▸ 3  Rings" | head -1 | cut -d: -f1)
second=$(screen | grep -n "▸ 1  Knots" | head -1 | cut -d: -f1)
if [ -n "$first" ] && [ -n "$second" ] && [ "$first" -lt "$second" ]; then
  echo "ok    the book with the surest proposal comes first"
else
  echo "FAIL  the book with the surest proposal comes first (rows $first, $second)"; fails=$((fails + 1))
fi
k s
shown "s orders by id instead"                "by id"
shown "on the first proposal"                 "Wrong Press"
k g g j e
shown "the proposal can be edited"            "publisher: Wrong Press"
k C-u Enter
shown "emptied, it proposes a blank"          "(blank)"
shown "and is accepted"                       "1 accepted"
k w
shown "review writes it"                      "changed 1 book"
expect "the publisher is gone"                "" "$(field 1 publisher)"

# ---- a command typed in review acts on the book review shows, never on a
# neighbour the list has fallen back to
k g r
shown "review again"                          "review  2 pending"
k s
shown "by id, book 2 comes first"             "by id"
k g g j
sleep 0.3
shown "its cursor is on book 2"               "│ Sieve"
k :; lit "remove"; k Enter
shown "remove names the book review is on"    "remove book 2, Sieve"
lit "y"; k Enter
shown "it is removed"                         "removed 1 book"
shown "review lets go of the removed book"    "review  1 pending"
if screen | grep -q "Sieve Notes"; then
  echo "FAIL  its proposals are no longer shown"; fails=$((fails + 1))
else
  echo "ok    its proposals are no longer shown"
fi
expect "and no other book was taken"          4 "$(run query -c 2>/dev/null)"
k q

# ---- orphans: what does not fit a column is one key away
lua 'local f = lulibre.files(4)[1]
assert(os.remove(f.path))' >/dev/null
k R
wait_for "reloaded"
k g o
shown "orphans opens"                         "Records with no file  (1)"
shown "with a verdict that fits its column"   "same work as book 3"
k x
shown "x shows the verdict in full"           "book 3 is the same work and has its file"
k x
sleep 0.3
if screen | grep -q "is the same work and has its file"; then
  echo "FAIL  x closes the row again"; fails=$((fails + 1))
else
  echo "ok    x closes the row again"
fi
k X
shown "X opens every row"                     "book 3 is the same work and has its file"
k q

# ---- from duplicates: the edit form for a row's book, and the preview's keys
k g d
shown "duplicates opens"                      "duplicates  1 groups"
shown "its hint offers the edit form"         "e edit"
k e
shown "e opens the edit form for the row's book" "edit  1  Knots"
if screen | grep -q "duplicates  1 groups"; then
  echo "FAIL  the duplicates panel steps aside meanwhile"; fails=$((fails + 1))
else
  echo "ok    the duplicates panel steps aside meanwhile"
fi
k Enter
shown "the title can be typed"                "^title: Knots"
k C-u; lit "Knot Theory"; k Enter w
shown "the change is written from there"      "changed 1 book"
shown "and duplicates comes back, up to date" "✓ *1 *Knot Theory"
k P
shown "P still turns the preview to an image" "── image"
k P
shown "and back to text"                      "── text"
k "?"
shown "? says which of the list's keys work"  "ALSO HERE"
k q q

k q
i=0; while [ ! -s "$t/rc" ] && [ $i -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
expect "the interface exits cleanly"          0 "$(cat "$t/rc" 2>/dev/null)"
expect "and wrote nothing to stderr"          "" "$(cat "$t/err" 2>/dev/null)"

[ $fails -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
