#!/bin/sh
# test/first.py inside private process and network namespaces, where the
# only calibre-server running is the test's own.
#   first.sh BUILT_BINARY
set -eu
src=$(cd "$(dirname "$0")" && pwd)
command -v unshare >/dev/null || { echo "first: unshare not found, skipping"; exit 0; }
unshare -rnpf --mount-proc true 2>/dev/null || { echo "first: no private namespaces (unshare -rnpf), skipping"; exit 0; }
unshare -rnpf --mount-proc python3 -I "$src/first.py" "$1"
