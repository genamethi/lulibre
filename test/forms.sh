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
# skipped where luv is missing; any other failure to run a script is a failure
probe=$("$bin" --clean run "$(dirname "$0")/luv_probe.lua" 2>&1) || case $probe in
  *"module 'luv' not found"*) echo "forms: the luv rock is not installed for this Lua version, skipping"; exit 0 ;;
  *) echo "FAIL  forms: lulibre could not run a script: $probe"; exit 1 ;;
esac

t=$(mktemp -d)
T="tmux -L lulibre-forms-$$"
# (|| true: the server may be gone already, and under set -e a failure in the trap becomes the exit status)
trap '$T kill-server 2>/dev/null || true; rm -rf "$t"' EXIT
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
mouse() { $T send-keys -t t -l "$(printf "$@")"; sleep 0.3; }
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
# the first change of the session, with no copy of calibre's database yet
shown "the first change offers a backup"      "no copy of calibre's database yet"
k Enter
shown "back up now makes one"                 "calibre's database copied to"
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
shown "where the list was, what the proposal rests on" "about this proposal"
shown "with the pages' verdict on it"         "verdict .*the pages"
shown "books ordered by how far their pages bear them out" "best borne out first"
k i
shown "i gives the list its place back"       "all books"
# panels and windows are reached by different keys
k Escape "?"
shown "Esc leaves review for the list"        "keys, by what they are for"
k q
shown "and review stays open"                 "review  3 pending"
k C-w w C-w w "?"
shown "<C-w>w goes round the windows, never into a panel" "keys, by what they are for"
k q Tab "?"
shown "Tab goes back into review"             "KEYS HERE"
k q BTab "?"
shown "and so does Shift-Tab, with one panel" "KEYS HERE"
k q
k i
shown "and i brings it back"                  "about this proposal"
k m
shown "m: every proposal a row of its own"    "every proposal"
k m
shown "m again: one row per field"            "one row per field"
first=$(screen | grep -n "▸ 3  Rings" | head -1 | cut -d: -f1)
second=$(screen | grep -n "▸ 1  Knots" | head -1 | cut -d: -f1)
if [ -n "$first" ] && [ -n "$second" ] && [ "$first" -lt "$second" ]; then
  echo "ok    the book with the surest proposal comes first"
else
  echo "FAIL  the book with the surest proposal comes first (rows $first, $second)"; fails=$((fails + 1))
fi
k f t
shown "f then t shows only the title proposals" "review  2 pending.*only title"
k f f
shown "f twice shows all again"               "review  3 pending"
k s
shown "s orders by the sources' confidence"   "surest first"
k s
shown "s puts the most disputed first"        "most disputed first"
k s
shown "s again orders by id"                  "by id"
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
wait_for "surest first"
k s
shown "past the most disputed"                "most disputed first"
k s
shown "by id, book 2 comes first"             "by id"
k g g j
sleep 0.3
shown "its cursor is on book 2"               "│ Sieve"
# copying from the page leaves the cursor in review: the next key is review's
row=$(screen | grep -n '│ Jane Roe' | tail -1 | cut -d: -f1)
before=$(screen | sed -n "${row}p" | sed 's/Jane Roe.*//')
col=$(($(printf '%s' "$before" | LC_ALL=C.UTF-8 wc -m) + 1))
mouse '\033[<0;%d;%dM' "$col" "$row"
mouse '\033[<32;%d;%dM' "$((col + 7))" "$row"
mouse '\033[<0;%d;%dm' "$((col + 7))" "$row"
shown "a drag in the preview copies"          "copied 8 characters"
k e
shown "and e still edits the proposal in review" "^title: Sieve Notes"
k Escape
sleep 0.5
# both clicks in one write: two that arrive a moment apart are not a double click
mouse '\033[<0;%d;%dM\033[<0;%d;%dm\033[<0;%d;%dM\033[<0;%d;%dm' "$col" "$row" "$col" "$row" "$col" "$row" "$col" "$row"
shown "a double click copies a word"          "copied 4 characters"
k e
shown "and leaves the cursor in review too"   "^title: Sieve Notes"
k Escape
sleep 0.5
k a
shown "on a proposal, a accepts it"           "review  1 pending, 1 accepted"
k a
shown "on a book's line, a accepts all of the book's" "accepted 1 for book 3"
shown "so that nothing is left pending"       "review  0 pending, 2 accepted"
k a
shown "and again takes them back"             "review  1 pending, 1 accepted"
k g g j a
shown "as it does on a single proposal"       "review  2 pending, 0 accepted"
k g g j
sleep 0.3
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
k g g j N
shown "N rejects for good"                    "nothing left to review"
expect "and bars the value"                   "barred" "$(lua 'print(lulibre.store("SELECT status FROM proposals ORDER BY id DESC LIMIT 1")[1].status)')"

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
k gg Space
shown "Space on a heading sets every row under it" "1 of 1 rows set to keep"
k Space
shown "and again, to the next action"         "1 of 1 rows set to remove record"
k q

# ---- the configuration window (a configuration of the test's own: $XDG_CONFIG_HOME)
run config --write >/dev/null 2>&1
init=$XDG_CONFIG_HOME/lulibre/init.lua
k g C
shown "gC opens the configuration window"     "configuration .*comments: full"
shown "as the bar's tab 3"                      "3  Configuration"
shown "with what the option does under it"    "what it does"
if screen | grep -q "Author .*Title"; then
  echo "FAIL  in the list's place"; fails=$((fails + 1))
else
  echo "ok    in the list's place"
fi
# down to `pages`: as many rows as the options above it and their headings
# (the window shows lulibre's options in order, a heading where a group
# begins, the cursor on the first option), counted from lulibre itself
steps=$(lua 'local n, group, row = 0, nil, 0
  for _, name in ipairs(lulibre.settings.names()) do
    local g = lulibre.settings.info(name).group or "lulibre"
    if g ~= group then group, row = g, row + 1 end
    row = row + 1
    if name == "pages" then n = row - 2 break end
  end
  print(n)')
for _ in $(seq "$steps"); do k j; done
k Enter
wait_for "pages = "
k C-u 9 Enter
shown "a value changed there takes effect"   "pages = 9, and written to init.lua"
expect "and is written to init.lua"           "o.pages = 9" "$(grep -o '^o.pages = 9' "$init")"
k d
shown "d puts it back"                        "pages back to its default"
expect "commented out with its default"       "-- o.pages = 6" "$(grep -o -- '-- o.pages = 6' "$init")"
expect "the file was kept before each write"  yes "$(test -e "$init.bak" && echo yes || echo no)"
k 1
shown "1 goes back to the list"               "Author .*Title"
if screen | grep -q "configuration .*comments"; then
  echo "FAIL  and closes the window"; fails=$((fails + 1))
else
  echo "ok    and closes the window"
fi
k 3
shown "3 opens it again"                      "configuration .*comments: full"
k 3
k q
wait_for "all books"
expect "once"                                 0 "$(screen | grep -c 'configuration .*comments')"

# ---- the snapshot browser
k g z
shown "gz opens the snapshot browser"         "no snapshots yet"
k n
wait_for "name for the snapshot"
k "first point" Enter
shown "n takes one"                           'took snapshot 1, "first point"'
shown "and the plan for it shows where the list was" "going back"
k q
wait_for "all books"

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
k q
k j t
shown "t offers the other copy's values to the kept one" "review  [0-9]* pending"
shown "saying where each comes from"          "book 5"
k q
shown "and comes back to duplicates"          "duplicates  1 groups"
k q

# ---- the preview stays on the book a panel is about, and the list's place shows it
k "&"; lit "id:1"; k Enter
wait_for "filter id:1"
k g d
shown "where the list was, the copies side by side" "the 2 copies, field by field"
k j
shown "the preview shows the row's book, though the list leaves it out" "unknown author"
k e
shown "e opens the edit form for it"              "edit  5  "
shown "where the list was, what its pages say"    "what the pages of book 5 say"
shown "and the preview stays on the book being edited" "unknown author"
k Escape
sleep 0.2
k q
k BSpace
wait_for "all books"

# ---- known good: the records by score, confirmed one at a time or in bulk
k g k
shown "known good opens, best records first"  "known good  0 confirmed of"
k Space
shown "Space confirms a record"               "known good  1 confirmed of"
k v
shown "v shows the confirmed ones"            "showing: confirmed"
k q
expect "is:good finds it"                     1 "$(run query -c is:good 2>/dev/null)"
k :; lit "learn"; k Enter
shown "learn reads the library"               "confirmed books"
k :; lit "terms"; k Enter
shown "with too few confirmed books, nothing is learned" "nothing has been learned"

# ---- one change to every selected book, from a dialog
before=$(run query -c tag:from-the-dialog 2>/dev/null)
k :; lit "mark all"; k Enter
k '\\' c
shown "the change dialog opens for the marked books" "change [0-9]* books at once"
k Enter; lit "from-the-dialog"; k Enter
shown "a subject typed into its line"         "add the subject  *from-the-dialog"
k w
shown "w writes it to all of them"            "changed [0-9]* book"
expect "none had the subject before"          0 "$before"
expect "and now every book has it"            "$(run query -c 2>/dev/null)" "$(run query -c tag:from-the-dialog 2>/dev/null)"
k Escape
sleep 0.2
k u
shown "one undo takes it back"                "undid"
expect "from every book"                      0 "$(run query -c tag:from-the-dialog 2>/dev/null)"
k '\\' Space

# ---- the edit form for several books: where they differ, what they hold
k "&"; lit "id:1,3,4"; k Enter
shown "the filter narrows the list to three" "3 of 4"
k :; lit "mark all"; k Enter
k e
shown "the edit form opens for the marked books" "edit  3 books"
shown "a field they differ in shows each value and how many hold it" "Sam Poe (2) · Ann Lee (1)"
shown "the preview names no book while several are edited" "3 books selected"
shown "and where the list was, what they share and where they differ" "3 books: what they share"
k Escape
sleep 0.2
k '\\' Space
k BSpace
wait_for "all books"

k q
i=0; while [ ! -s "$t/rc" ] && [ $i -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
expect "the interface exits cleanly"          0 "$(cat "$t/rc" 2>/dev/null)"
expect "and wrote nothing to stderr"          "" "$(cat "$t/err" 2>/dev/null)"

[ $fails -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
