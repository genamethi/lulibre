#!/bin/sh
# OCR that takes a long time, with a stand-in for tesseract that never ends,
# in a private tmux server. While it reads: the database's write lock is free,
# and a sync folder given with :sync is read at once. Quitting: the terminal
# comes back and lulibre ends, without waiting for it; tesseract is stopped,
# and the file it was reading is left to be read the next time.
#   quit.sh BUILT_BINARY
set -eu
bin=$(realpath "$1")
src=$(cd "$(dirname "$0")" && pwd)
if ! command -v tmux >/dev/null || ! command -v sqlite3 >/dev/null; then
  echo "quit: tmux or sqlite3 not found, skipping"
  exit 0
fi
t=$(mktemp -d)
T="tmux -L lulibre-quit-$$"
trap '[ ! -s "$t/pid" ] || kill "$(cat "$t/pid")" 2>/dev/null || true; rm -rf "$t"; $T kill-server 2>/dev/null || true' EXIT
sh "$src/mklib.sh" "$t/lib" >/dev/null 2>&1
mkdir -p "$t/bin" "$t/tmp" "$t/scans" "$t/more"
cat >"$t/bin/tesseract" <<EOF
#!/bin/sh
echo \$\$ >"$t/pid"
exec sleep 600
EOF
chmod +x "$t/bin/tesseract"
# a page with nothing on it: its text is not usable, so OCR reads it
cat >"$t/scans/blank.pdf" <<'EOF'
%PDF-1.4
1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj
2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj
3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 200]>>endobj
trailer<</Root 1 0 R>>
EOF
echo "words in a file of the second folder" >"$t/more/more.txt"

fails=0
check() { # what, then a test
  what=$1
  shift
  if "$@"; then echo "ok    $what"; else echo "FAIL  $what"; $T capture-pane -p -t s | sed 's/^/      /'; fails=$((fails + 1)); fi
}
wait_for() { # up to 10 s for a test to pass
  i=0
  while [ $i -lt 100 ]; do
    if "$@"; then return 0; fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}
reading() { [ -s "$t/pid" ]; }
screen_has() { $T capture-pane -p -t s | grep -q "$1"; }
ended() { screen_has "EXIT="; }

$T new-session -d -s s -x 120 -y 30 "env TERM=xterm-256color TMPDIR='$t/tmp' PATH='$t/bin:$PATH' XDG_CONFIG_HOME='$t/config' XDG_DATA_HOME='$t/data' XDG_STATE_HOME='$t/state' '$bin' -L '$t/lib' -o jobs=2 -o path.sync='$t/scans'; echo EXIT=\$?; sleep 30"
wait_for reading || true
check "tesseract is reading the file" reading
db=$(ls "$t/data/lulibre/"lib-*.db | grep -v '\.\(journal\|custom\|wit\)\.db$')
free() { sqlite3 "$db" "BEGIN IMMEDIATE; COMMIT;" 2>/dev/null; }
wait_for free || true
check "the write lock is free while it reads" free
$T send-keys -t s ":sync $t/more" Enter
wait_for screen_has "is the sync folder for now" || true
check ":sync DIR is read while it reads" screen_has "is the sync folder for now"
start=$(date +%s)
$T send-keys -t s q
wait_for ended || true
check "q: lulibre ends without waiting for tesseract" ended
check "and in moments" [ $(($(date +%s) - start)) -le 5 ]
check "it said why it took a moment" screen_has "stopping the indexer"
check "tesseract is stopped" sh -c "! kill -0 $(cat "$t/pid") 2>/dev/null"
check "its page image is gone" sh -c "[ -z \"\$(ls '$t/tmp')\" ]"
outcome=$(sqlite3 "$db" "SELECT outcome FROM files WHERE path LIKE '%blank.pdf'" 2>/dev/null || true)
check "the file is left to be read, with no verdict from a stopped OCR" [ "${outcome:-0}" = 0 ]

[ $fails -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
