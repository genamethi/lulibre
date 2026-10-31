#!/bin/sh
# lulibre's systemd units (lua/units.lua) against a user unit of the
# test's own: a calibre-server.service in a home of its own, a systemctl
# that logs what it is asked and shows the unit's files, and private
# process and network namespaces, so that no calibre-server running is
# seen and no systemd of the machine's is asked anything.
#   units.sh BUILT_BINARY
set -eu

bin=$(realpath "$1")
src=$(cd "$(dirname "$0")" && pwd)
command -v unshare >/dev/null || { echo "units: unshare not found, skipping"; exit 0; }
unshare -rnpf --mount-proc true 2>/dev/null || { echo "units: no private namespaces (unshare -rnpf), skipping"; exit 0; }
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
sh "$src/mklib.sh" "$t/lib" >/dev/null 2>&1
mkdir -p "$t/home/.config/systemd/user" "$t/bin"
units=$t/home/.config/systemd/user
cat >"$units/calibre-server.service" <<UNIT
[Unit]
Description=calibre Content server

[Service]
Type=simple
ExecStart=$t/bin/calibre-server --port 8099 $t/lib

[Install]
WantedBy=default.target
UNIT
printf '#!/bin/sh\nexit 0\n' >"$t/bin/calibre-server"
printf '#!/bin/sh\nexit 0\n' >"$t/bin/calibre-debug"
# systemctl: each call logged; cat shows the unit and its drop-ins as systemd does
cat >"$t/bin/systemctl" <<SC
#!/bin/sh
echo "\$*" >>"$t/systemctl.log"
[ "\$1" = --user ] && shift
if [ "\$1" = cat ]; then
  for f in "$units/\$2" "$units/\$2.d"/*.conf; do
    [ -f "\$f" ] || continue
    echo "# \$f"
    cat "\$f"
  done
fi
exit 0
SC
chmod +x "$t/bin/calibre-server" "$t/bin/calibre-debug" "$t/bin/systemctl"

cat >"$t/apply.lua" <<'LUA'
local units = require "units"
for _, s in ipairs { "server_hook", "opf_writer", "server_restart_at" } do
  local v = os.getenv("WANT_" .. s)
  if v then setman.set(s, v) end
end
local p = units.plan()
print(table.concat(units.describe(p), "\n"))
print("--")
print(table.concat(units.apply(p), "\n"))
LUA
run() { # the settings as environment, then lulibre run apply.lua inside the namespaces
  env "$@" HOME="$t/home" PATH="$t/bin:$PATH" XDG_CONFIG_HOME="$t/config" XDG_DATA_HOME="$t/data" \
    XDG_STATE_HOME="$t/state" unshare -rnpf --mount-proc "$bin" -L "$t/lib" run "$t/apply.lua" 2>&1
}

fails=0
contains() { # description, needle, haystack
  case "$3" in *"$2"*) echo "ok    $1" ;; *) echo "FAIL  $1: '$2' in:"; echo "$3" | sed 's/^/      /'; fails=$((fails + 1)) ;; esac
}
has() { # description, file, needle
  if grep -qF -- "$3" "$2" 2>/dev/null; then echo "ok    $1"; else echo "FAIL  $1: '$3' in $2"; fails=$((fails + 1)); fi
}
gone() { # description, file
  if [ -e "$2" ]; then echo "FAIL  $1: $2 is there"; fails=$((fails + 1)); else echo "ok    $1"; fi
}

out=$(run WANT_server_hook=true WANT_opf_writer=server WANT_server_restart_at=04:30)
contains "the server's unit, found by its file" "calibre-server.service (a user unit)" "$out"
contains "the plan says what it writes" "write $units/lulibre.service" "$out"
has "server_hook: lulibre.service runs lulibre offline before the server" "$units/lulibre.service" "ExecStart=$bin offline"
has "and is wanted by the server's unit" "$units/lulibre.service" "WantedBy=calibre-server.service"
has "opf_writer: the drop-in starts the server through calibre-debug and the launcher" \
  "$units/calibre-server.service.d/lulibre-opf-writer.conf" "ExecStart=$t/bin/calibre-debug -e"
has "with calibre-server's own arguments" "$units/calibre-server.service.d/lulibre-opf-writer.conf" "-- --port 8099 $t/lib"
has "server_restart_at: the timer, at that time" "$units/lulibre-restart.timer" "OnCalendar=*-*-* 04:30:00"
has "systemd is told: daemon-reload, enable lulibre.service, enable --now the timer" "$t/systemctl.log" "--user enable lulibre.service"
has "and the timer" "$t/systemctl.log" "--user enable --now lulibre-restart.timer"
again=$(run WANT_server_hook=true WANT_opf_writer=server WANT_server_restart_at=04:30)
contains "as the settings say, nothing more to change" "nothing to change" "$again"

: >"$t/systemctl.log"
off=$(run)
contains "the settings back to their defaults: lulibre's units are taken out" "lulibre.service: done (server_hook = false)" "$off"
gone "lulibre.service is gone" "$units/lulibre.service"
gone "the timer is gone" "$units/lulibre-restart.timer"
has "after systemd was told" "$t/systemctl.log" "--user disable lulibre.service"
has "the server's own unit is left as it was" "$units/calibre-server.service" "ExecStart=$t/bin/calibre-server --port 8099"

sed -i 's/^Type=simple$/Type=simple\nProtectSystem=strict/' "$units/calibre-server.service"
hard=$(run WANT_opf_writer=server)
contains "a hardened unit gets no drop-in: it is shown, left to you" "left to you: it has sandboxing or hardening settings (ProtectSystem)" "$hard"
gone "and none is written" "$units/calibre-server.service.d/lulibre-opf-writer.conf"

[ $fails -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
