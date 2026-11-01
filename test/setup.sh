#!/bin/sh
# Setup: setup/install.sh carrying out a plan, and lulibre-setup making one.
#   setup.sh BUILT_LULIBRE BUILT_LULIBRE_SETUP
# A plan shown without running (-n), a plan with a choice missing, a
# user-level install under a temporary prefix (a library whose name has a
# quote in it, the settings in lua/config/options.lua and an init.lua that
# loads them, a password file open to others), the settings alone (-s), the
# settings written again over files edited since, and the setup screen
# driven through a private tmux server.
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
export HOME="$t/home" XDG_CONFIG_HOME="$t/home/.config" XDG_DATA_HOME="$t/home/.local/share" \
  XDG_STATE_HOME="$t/home/.local/state"

fails=0
expect() { # description, expected, actual
  if [ "$2" = "$3" ]; then echo "ok    $1"; else echo "FAIL  $1: expected '$2', got '$3'"; fails=$((fails + 1)); fi
}
contains() { # description, needle, haystack
  case $3 in *"$2"*) echo "ok    $1" ;; *) echo "FAIL  $1: '$2' not in: $3"; fails=$((fails + 1)) ;; esac
}
lacks() { # description, needle, haystack
  case $3 in *"$2"*) echo "FAIL  $1: '$2' in: $3"; fails=$((fails + 1)) ;; *) echo "ok    $1" ;; esac
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
contains "-n: a value with a quote is shown as the shell takes it" "path.library=$t/home/it's lib" "$out"
expect "-n: nothing is installed" "no" "$([ -e "$t/sys" ] && echo yes || echo no)"
expect "-n: the password file is as it was" "644" "$(stat -c %a "$t/home/.config/calibre/pw")"

printf "LEVEL='user'\nPIXI='no'\n" >"$t/gap.conf"
out=$(sh "$src/setup/install.sh" "$t/gap.conf" 2>&1) && status=0 || status=$?
expect "a choice missing: the script stops" "1" "$status"
contains "and says which" "not set in the plan: library; content server" "$out"

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
printf 'print((package.path:match("^([^;]+)")))\n' >"$t/where.lua"
expect "and finds its files beside it" "$(realpath "$t/user/share/lulibre")/lua/?.lua" \
  "$("$t/user/bin/lulibre" --clean run "$t/where.lua" 2>&1)"
cfg=$t/home/.config/lulibre
options=$(cat "$cfg/lua/config/options.lua" 2>/dev/null || true)
contains "options.lua: through lulib.opt" "local opt = lulib.opt" "$options"
contains "options.lua: the library, quote and all" "opt.path.library = \"$t/home/it's lib\"" "$options"
contains "options.lua: the content server" 'opt.server = "http://127.0.0.1:8080"' "$options"
contains "options.lua: a setting of the plan's, as a number" "opt.pages = 8" "$options"
expect "no init.lua before: setup writes one that loads them" 'require "config.options"' "$(cat "$cfg/init.lua" 2>/dev/null)"
printf 'print(setman.get("pages") .. "|" .. setman.get("server"))\n' >"$t/read.lua"
expect "and lulibre starts with them" "8|http://127.0.0.1:8080" "$("$t/user/bin/lulibre" run "$t/read.lua" 2>&1)"

# again, over an options.lua edited since and an init.lua of the user's
printf 'opt.ocr = "auto"\n' >>"$cfg/lua/config/options.lua"
before=$(cat "$cfg/lua/config/options.lua")
printf -- '-- mine\nsetman.set("mouse", false)\n' >"$cfg/init.lua"
printf 'path.library=%s\nserver=\npages=7\n' "$t/home/it's lib" >"$t/again"
out=$("$bin" --clean run "$src/setup/options.lua" "$t/again" 2>&1) && status=0 || status=$?
expect "written again" "0" "$status"
options=$(cat "$cfg/lua/config/options.lua")
contains "a line of the user's is kept" 'opt.ocr = "auto"' "$options"
contains "a setting's line is replaced" "opt.pages = 7" "$options"
lacks "an empty value takes its line out" "opt.server =" "$options"
expect "options.lua.bak: the file before" "$before" "$(cat "$cfg/lua/config/options.lua.bak")"
expect "an init.lua without the require gets it, at the end" \
  "$(printf -- '-- mine\nsetman.set("mouse", false)\nrequire "config.options"')" "$(cat "$cfg/init.lua")"
expect "init.lua.bak: the file before" "$(printf -- '-- mine\nsetman.set("mouse", false)')" "$(cat "$cfg/init.lua.bak")"
contains "and setup says so" 'now loads them' "$out"
printf -- '--[[ a note ]]\n--require "config.options"\n' >"$cfg/init.lua"
"$bin" --clean run "$src/setup/options.lua" "$t/again" >/dev/null 2>&1
expect "the require commented out comes alive, where it is" \
  "$(printf -- '--[[ a note ]]\nrequire "config.options"')" "$(cat "$cfg/init.lua")"
printf 'pages=many\n' >"$t/bad"
out=$("$bin" --clean run "$src/setup/options.lua" "$t/bad" 2>&1) && status=0 || status=$?
contains "a value refused: nothing is written" "nothing written: pages: many is not a whole number" "$out"
expect "and options.lua is as it was" "$options" "$(cat "$cfg/lua/config/options.lua")"
expect "the password file is mode 600" "600" "$(stat -c %a "$t/home/.config/calibre/pw")"

# the settings alone: no level, no pixi, nothing installed
mv "$cfg" "$t/cfg.before"
cat >"$t/settings.conf" <<EOF
LIBRARY='$t/home/it'\''s lib'
SERVER='no'
PREFIX='$t/none'
opt 'pages' '9'
EOF
out=$(sh "$src/setup/install.sh" -s "$t/settings.conf" 2>&1) && status=0 || status=$?
expect "-s: runs without a level or pixi" "0" "$status"
[ "$status" -eq 0 ] || printf '%s\n' "$out"
expect "-s: nothing is installed" "no" "$([ -e "$t/none" ] && echo yes || echo no)"
contains "-s: options.lua" "opt.pages = 9" "$(cat "$cfg/lua/config/options.lua" 2>/dev/null)"
expect "-s: and an init.lua that loads it" 'require "config.options"' "$(cat "$cfg/init.lua" 2>/dev/null)"
rm -rf "$cfg"
mv "$t/cfg.before" "$cfg"

# what is pending against the file, which is kept as it is written
cat >"$cfg/lua/config/options.lua" <<'EOF'
local opt = lulib.opt
opt.pages = 8 -- more than the default
opt.path.log = os.getenv("HOME") .. "/x.log"
-- opt.ocr_pages = 3
EOF
printf 'require "config.options"\n' >"$cfg/init.lua"
cat >"$t/pending.lua" <<'EOF'
local options = require "lulib._options"
local function pending()
  taskman.sleep(20)
  local out = {}
  for _, it in ipairs(options.pending()) do out[#out + 1] = it.name .. "=" .. tostring(it.value) end
  return table.concat(out, ",")
end
print("as loaded:" .. pending())
setman.set("pages", 9)
setman.set("ocr_pages", 5)
setman.set("path.log", nil)
print("changed:" .. pending())
options.write(options.pending())
print("written:" .. pending())
options.write({}, { defaults = true })
print(options.loads())
EOF
out=$("$bin" -L "$t/home/it's lib" run "$t/pending.lua" 2>&1 | grep -v '^$') || true
contains "the file loaded, the command line's left out: nothing is pending" "as loaded:
" "$out
"
contains "changes are pending, and a setting at its default against its line" "changed:" "$out"
contains "  pages" "pages=9" "$out"
contains "  ocr_pages" "ocr_pages=5" "$out"
contains "  path.log, back at its default" "path.log=nil" "$out"
contains "once written, nothing" "written:
" "$out
"
contains "init.lua loads it" "true" "$out"
options=$(cat "$cfg/lua/config/options.lua")
contains "a comment on a line goes when its value changes" "opt.pages = 9" "$options"
lacks "a line back at its default goes" "x.log" "$options"
contains "a line commented out takes the value, in its place" "opt.ocr_pages = 5" "$options"
lacks "and isn't left as well" "-- opt.ocr_pages" "$options"
contains "every default, commented out" "-- opt.blitter = \"auto\"" "$options"
contains "  a number as a number" "-- opt.jobs = 0" "$options"
contains "  a true or false as one" "-- opt.mouse = true" "$options"
printf 'opt.pages = 8\n' >"$cfg/lua/config/options.lua"
printf 'require "config.options"\n' >"$cfg/init.lua"

# ---- where modules are found: mod_tree first, and not in a pixi environment
mkdir -p "$t/mods/share/lua/5.5" "$t/modcfg/lulibre"
lv=$("$bin" -V | sed -n 's/.*Lua \([0-9.]*\)).*/\1/p')
[ "$lv" = 5.5 ] || mv "$t/mods/share/lua/5.5" "$t/mods/share/lua/$lv"
echo 'return "from mod_tree"' >"$t/mods/share/lua/$lv/modprobe.lua"
printf 'setman.set("path.modtree", "%s")\n' "$t/mods" >"$t/modcfg/lulibre/init.lua"
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
  $T send-keys -t s w
  wait_for "to choose first" || true
  contains "w with choices missing: only those for the settings" "to choose first: Library, Content server" "$(screen)"
  $T send-keys -t s q
  sleep 0.5
  plan=$(cat "$t/tui.conf" 2>/dev/null || true)
  contains "the plan keeps the level" "LEVEL='user'" "$plan"
  contains "and pixi" "PIXI='no'" "$plan"
  $T kill-session -t s 2>/dev/null || true
  start
  contains "started again, the choices are there" "Level                          user" "$(screen)"
  # the library from the browser: a path typed after /, then its first row
  $T send-keys -t s j j Enter
  wait_for "choose this folder" || true
  $T send-keys -t s /
  $T send-keys -t s C-u
  $T send-keys -t s -l "$t/home/it's lib"
  $T send-keys -t s Enter
  sleep 0.3
  $T send-keys -t s g Enter
  wait_for "a calibre library" || true
  contains "the browser: a folder chosen, shown under ~" "~/it's lib   a calibre library" "$(screen)"
  # a value with a quote in it, typed
  $T send-keys -t s j Space j j Enter
  $T send-keys -t s -l "o'brien"
  $T send-keys -t s Enter
  wait_for "o'brien" || true
  $T send-keys -t s q
  sleep 0.5
  plan=$(cat "$t/tui.conf" 2>/dev/null || true)
  contains "the plan: the folder chosen" "LIBRARY='$t/home/it'\\''s lib'" "$plan"
  contains "the plan: a quote kept as the shell reads it" "SERVER_USER='o'\\''brien'" "$plan"
  # w on the screen: the settings alone, with no level or pixi chosen
  cat >"$t/w.conf" <<EOF
LIBRARY='$t/home/it'\''s lib'
SERVER='no'
opt 'pages' '6'
EOF
  mv "$cfg" "$t/cfg.before"
  $T kill-session -t s 2>/dev/null || true
  $T new-session -d -s s -x 110 -y 30 "TERM=xterm-256color '$setup' '$t/w.conf'; sleep 30"
  wait_for "Basic" || true
  $T send-keys -t s w
  wait_for "Enter goes back" || true
  contains "the screen: w writes options.lua" "opt.pages = 6" "$(cat "$cfg/lua/config/options.lua" 2>/dev/null)"
  expect "and an init.lua that loads it" 'require "config.options"' "$(cat "$cfg/init.lua" 2>/dev/null)"
  $T kill-session -t s 2>/dev/null || true
  rm -rf "$cfg"
  mv "$t/cfg.before" "$cfg"
  printf '. "%s"\nprintf "%%s|%%s" "$LIBRARY" "$SERVER_USER"\n' "$t/tui.conf" >"$t/read.sh"
  expect "and the shell reads the values back" "$t/home/it's lib|o'brien" "$(opt() { :; }; . "$t/read.sh")"
fi

[ $fails -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
