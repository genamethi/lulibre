#!/bin/sh
# lulibre's setup: installs what the plan (setup.conf) asks for. lulibre-setup
# writes the plan and runs this script in the terminal; it runs on its own too:
#
#   sh setup/install.sh [-n] [PLAN]      -n: show the commands, run none
#
# Every command is shown before it runs. sudo is used only by the steps that
# write outside the user's files: a system-level install, luv in the
# system's luarocks tree.
set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
dry=no
if [ "${1:-}" = -n ]; then
  dry=yes
  shift
fi
plan=${1:-$here/setup.conf}

die() {
  printf 'setup: %s\n' "$*" >&2
  exit 1
}

# the plan sets these, and names lulibre's other options with `opt`
LEVEL= PIXI= LIBRARY= SERVER= SERVER_URL= SERVER_USER= PASSWORD_FILE= PASSWORD_CHMOD=
PREFIX= CONFIRM= LUV_ROCKS=
optfile=$(mktemp "${TMPDIR:-/tmp}/lulibre-setup.XXXXXX")
trap 'rm -f "$optfile"' EXIT
opt() {
  case $2 in *'
'*) die "the value of $1 holds a line break" ;;
  esac
  printf '%s=%s\n' "$1" "$2" >>"$optfile"
}

[ -r "$plan" ] || die "no plan at $plan (build/lulibre-setup writes it)"
. "$plan"

missing=
[ -n "$LEVEL" ] || missing="$missing level;"
[ -n "$PIXI" ] || missing="$missing pixi;"
[ -n "$LIBRARY" ] || missing="$missing library;"
[ -n "$SERVER" ] || missing="$missing content server;"
if [ "$SERVER" = yes ]; then
  [ -n "$SERVER_URL" ] || missing="$missing the server's URL;"
  [ -n "$SERVER_USER" ] || missing="$missing the server's user;"
  [ -n "$PASSWORD_FILE" ] || missing="$missing the password file;"
fi
[ -z "$missing" ] || die "not set in the plan:${missing%;}"
case $LEVEL in user | system) ;; *) die "LEVEL is user or system, not '$LEVEL'" ;; esac
[ -f "$LIBRARY/metadata.db" ] || die "$LIBRARY holds no metadata.db: not a calibre library"
if [ "$SERVER" = yes ] && [ ! -f "$PASSWORD_FILE" ]; then die "no password file at $PASSWORD_FILE"; fi

case $LEVEL in
user) prefix=${PREFIX:-$HOME/.local} ;;
system) prefix=${PREFIX:-/usr/local} ;;
esac
lu=$here/build/lulibre
bin=$prefix/bin/lulibre

# a word as the shell would need it typed
quote() {
  case $1 in
  '' | *[!A-Za-z0-9_./:=@%+,-]*) printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")" ;;
  *) printf '%s' "$1" ;;
  esac
}

show() {
  line='$'
  for a in "$@"; do line="$line $(quote "$a")"; done
  printf '%s\n' "$line"
}

run() {
  show "$@"
  [ "$dry" = no ] || return 0
  if [ "$CONFIRM" = yes ]; then
    printf 'run it? [Y/n/q] '
    read -r answer </dev/tty || answer=q
    case $answer in
    n | N) echo "skipped"; return 0 ;;
    q | Q) die "stopped" ;;
    esac
  fi
  "$@"
}

root() {
  if [ "$(id -u)" -ne 0 ]; then run sudo "$@"; else run "$@"; fi
}

step() {
  printf '\n== %s\n' "$*"
}

step "the build"
[ -x "$lu" ] || die "no build/lulibre: lulibre is built first (./configure && make)"
make -s -C "$here" -q build/lulibre || die "build/lulibre is older than its sources: make builds it again"
echo "build/lulibre is up to date"

if [ "$PIXI" = yes ]; then
  step "pixi"
  if ! command -v pixi >/dev/null 2>&1; then
    if [ -x "$HOME/.pixi/bin/pixi" ]; then
      PATH=$HOME/.pixi/bin:$PATH
    else
      run sh -c 'curl -fsSL https://pixi.sh/install.sh | sh'
      PATH=$HOME/.pixi/bin:$PATH
    fi
  fi
  run pixi install --manifest-path "$here/pixi.toml"
  run pixi run --manifest-path "$here/pixi.toml" rocks
fi

step "lulibre's files, under $prefix"
if [ "$LEVEL" = system ]; then
  root make -s -C "$here" install BINDIR="$prefix/bin" DATADIR="$prefix/share"
else
  run make -s -C "$here" install BINDIR="$prefix/bin" DATADIR="$prefix/share"
fi

case $LUV_ROCKS in
user)
  step "luv, in the user-level luarocks tree"
  run make -s -C "$here" rocks
  ;;
system)
  step "luv, in the system's luarocks tree"
  root make -s -C "$here" rocks ROCKS=
  ;;
esac

if [ "$SERVER" = yes ] && [ "$PASSWORD_CHMOD" = yes ]; then
  step "the password file"
  run chmod 600 "$PASSWORD_FILE"
fi

step "init.lua"
init=$("$lu" --clean config --path)
fresh=
if [ ! -e "$init" ]; then
  run "$lu" --clean config --write
  fresh=new
fi
opt library "$LIBRARY"
if [ "$SERVER" = yes ]; then
  opt server "$SERVER_URL"
  opt user "$SERVER_USER"
  opt password_file "$PASSWORD_FILE"
else
  opt server ''
  opt user ''
  opt password_file ''
fi
echo "the values set in $init (an empty one goes back to lulibre's default):"
sed 's/^/  /' "$optfile"
run "$lu" --clean run "$here/setup/options.lua" "$optfile" $fresh

step "luv"
if [ "$dry" = no ]; then
  if [ "$PIXI" = yes ]; then
    run pixi run --manifest-path "$here/pixi.toml" "$bin" --clean run "$here/setup/luv-check.lua" ||
      echo "lulibre runs without luv; the sync folder, orphans and onboarding need it"
  else
    run "$bin" --clean run "$here/setup/luv-check.lua" ||
      echo "lulibre runs without luv; the sync folder, orphans and onboarding need it"
  fi
fi

if [ "$SERVER" = yes ] && grep -q '^\(server_hook\|opf_writer\|server_restart_at\)=.' "$optfile"; then
  step "systemd units around the content server"
  run "$bin" units apply
fi

step "done"
echo "lulibre: $bin"
case :$PATH: in
*":$prefix/bin:"*) ;;
*) echo "$prefix/bin is not on PATH" ;;
esac
echo "init.lua: $init"
if [ "$PIXI" = yes ]; then
  echo "pixi's environment holds luv and the optional programs: lulibre started with"
  echo "  pixi run --manifest-path $here/pixi.toml lulibre"
fi
