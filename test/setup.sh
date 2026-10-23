#!/bin/sh
# Setup: setup/install.sh carrying out a plan, and lulibre-setup making one.
#   setup.sh BUILT_LULIBRE BUILT_LULIBRE_SETUP
# A plan shown without running (-n), a plan with a choice missing, a
# user-level install under a temporary prefix (a library whose name has a
# quote in it, an init.lua that was there before, a password file open to
# others), and the setup screen driven through a private tmux server.
# Touches nothing outside a temporary directory.
set -eu

bin=$(realpath "$1")
setup=$(realpath "$2")
src=$(cd "$(dirname "$0")/.." && pwd)

t=$(mktemp -d)
trap 'rm -rf "$t"; tmux -L "lulibre-setup-$$" kill-server 2>/dev/null || true' EXIT
mkdir -p "$t/home/it's lib" "$t/home/.config/calibre"
: >"$t/home/it's lib/metadata.db"
echo password >"$t/home/.config/calibre/pw"
chmod 644 "$t/home/.config/calibre/pw"
export HOME="$t/home" XDG_CONFIG_HOME="$t/home/.config" XDG_DATA_HOME="$t/home/.local/share"

fails=0
expect() { # description, expected, actual
  if [ "$2" = "$3" ]; then echo "ok    $1"; else echo "FAIL  $1: expected '$2', got '$3'"; fails=$((fails + 1)); fi
}
contains() { # description, needle, haystack
  case $3 in *"$2"*) echo "ok    $1" ;; *) echo "FAIL  $1: '$2' not in: $3"; fails=$((fails + 1)) ;; esac
}

# ---- the script on a plan
cat >"$t/system.conf" <<EOF
LEVEL='system'
PIXI='yes'
LIBRARY='$t/home/it'\''s lib'
SERVER='yes'
SERVER_URL='http://127.0.0.1:8080'
SERVER_USER='me'
PASSWORD_FILE='$t/home/.config/calibre/pw'
PASSWORD_CHMOD='yes'
PREFIX='$t/sys'
opt 'pages' '8'
EOF
out=$(sh "$src/setup/install.sh" -n "$t/system.conf" 2>&1) || true
contains "-n: a system install goes through sudo" "\$ sudo make -s -C" "$out"
contains "-n: pixi's environment is installed" "\$ pixi install --manifest-path $src/pixi.toml" "$out"
contains "-n: the password file is made mode 600" "\$ chmod 600" "$out"
contains "-n: a value with a quote is shown as the shell takes it" "library=$t/home/it's lib" "$out"
expect "-n: nothing is installed" "no" "$([ -e "$t/sys" ] && echo yes || echo no)"
expect "-n: the password file is as it was" "644" "$(stat -c %a "$t/home/.config/calibre/pw")"

printf "LEVEL='user'\nPIXI='no'\n" >"$t/gap.conf"
out=$(sh "$src/setup/install.sh" "$t/gap.conf" 2>&1) && status=0 || status=$?
expect "a choice missing: the script stops" "1" "$status"
contains "and says which" "not set in the plan: library; content server" "$out"

mkdir -p "$t/home/.config/lulibre"
printf 'local o = lulibre.o\no.pages = 3\n' >"$t/home/.config/lulibre/init.lua"
cat >"$t/user.conf" <<EOF
LEVEL='user'
PIXI='no'
LIBRARY='$t/home/it'\''s lib'
SERVER='yes'
SERVER_URL='http://127.0.0.1:8080'
SERVER_USER='me'
PASSWORD_FILE='$t/home/.config/calibre/pw'
PASSWORD_CHMOD='yes'
PREFIX='$t/user'
opt 'pages' '8'
EOF
out=$(sh "$src/setup/install.sh" "$t/user.conf" 2>&1) && status=0 || status=$?
expect "a user install runs through" "0" "$status"
[ "$status" -eq 0 ] || printf '%s\n' "$out"
expect "lulibre is under the prefix" "yes" "$([ -x "$t/user/bin/lulibre" ] && echo yes || echo no)"
printf 'print(lulibre.settings.paths().installed)\n' >"$t/where.lua"
expect "and finds its files beside it" "$(realpath "$t/user/share/lulibre")" \
  "$("$t/user/bin/lulibre" --clean run "$t/where.lua" 2>&1)"
init=$(cat "$t/home/.config/lulibre/init.lua")
contains "init.lua: the library, quote and all" "o.library = \"$t/home/it's lib\"" "$init"
contains "init.lua: the content server" 'o.server = "http://127.0.0.1:8080"' "$init"
contains "init.lua: an option of the plan's, on the line that set it" "o.pages = 8" "$init"
expect "init.lua.bak: the file before setup" "$(printf 'local o = lulibre.o\no.pages = 3')" \
  "$(cat "$t/home/.config/lulibre/init.lua.bak")"
expect "the password file is mode 600" "600" "$(stat -c %a "$t/home/.config/calibre/pw")"

# ---- where modules are found: mod_tree first, and not in a pixi environment
mkdir -p "$t/mods/share/lua/5.5" "$t/modcfg/lulibre"
lv=$("$bin" -V | sed -n 's/.*Lua \([0-9.]*\)).*/\1/p')
[ "$lv" = 5.5 ] || mv "$t/mods/share/lua/5.5" "$t/mods/share/lua/$lv"
echo 'return "from mod_tree"' >"$t/mods/share/lua/$lv/modprobe.lua"
printf 'lulibre.o.mod_tree = "%s"\n' "$t/mods" >"$t/modcfg/lulibre/init.lua"
printf 'local ok, m = pcall(require, "modprobe") print(ok and m or "not found")\n' >"$t/mod.lua"
expect "mod_tree: a module under it is found" "from mod_tree" \
  "$("$bin" -C "$t/modcfg/lulibre" run "$t/mod.lua" 2>/dev/null)"
expect "in a pixi environment, mod_tree is ignored" "not found" \
  "$(PIXI_ENVIRONMENT_NAME=default "$bin" -C "$t/modcfg/lulibre" run "$t/mod.lua" 2>/dev/null)"

# ---- the screen
if ! command -v tmux >/dev/null; then
  echo "setup: tmux not found, the screen is not tried"
else
  T="tmux -L lulibre-setup-$$"
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
  start() {
    $T new-session -d -s s -x 110 -y 30 "TERM=xterm-256color '$setup' '$t/tui.conf'; sleep 30"
    wait_for "Basic" || true
  }
  start
  contains "the screen: the basic choices, none made" "Level                          not set" "$(screen)"
  $T send-keys -t s Enter
  $T send-keys -t s j Space Space
  wait_for "pixi                           no" || true
  $T send-keys -t s i
  wait_for "to choose first" || true
  contains "Install now with choices missing names them" "to choose first: Library, Content server" "$(screen)"
  $T send-keys -t s q
  sleep 0.5
  plan=$(cat "$t/tui.conf" 2>/dev/null || true)
  contains "the plan keeps the level" "LEVEL='user'" "$plan"
  contains "and pixi" "PIXI='no'" "$plan"
  $T kill-session -t s 2>/dev/null || true
  start
  contains "started again, the choices are there" "Level                          user" "$(screen)"
  $T send-keys -t s q
fi

[ $fails -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
