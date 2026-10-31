#!/bin/sh
# test/first.py inside a private network namespace, where the content
# server calibre's default port answers with is the test's own.
#   first.sh BUILT_BINARY
set -eu
src=$(cd "$(dirname "$0")" && pwd)
command -v unshare >/dev/null || { echo "first: unshare not found, skipping"; exit 0; }
unshare -rn true 2>/dev/null || { echo "first: no private namespace (unshare -rn), skipping"; exit 0; }
unshare -rn python3 -I "$src/first.py" "$1"
