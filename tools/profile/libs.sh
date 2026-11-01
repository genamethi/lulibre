#!/bin/sh
# Builds Lua, SQLite and MuPDF with debug info and frame pointers, as the
# system's versions, into build/profile-cache/lib, and lulibre with frame
# pointers into build/profile-cache/lulibre. run.sh uses both, so perf and
# valgrind name the functions inside those libraries.
#
#   tools/profile/libs.sh LUA_SRC SQLITE_AMALGAMATION_ZIP MUPDF_SOURCE_TARBALL
#
# The versions must be the system's: liblua.so.5.5 (Lua 5.5.1, Arch's
# luaconf.h), libsqlite3.so.0 (3.54.0, the system's compile options),
# libmupdf.so.28.5 (1.28.5).
set -eu
[ $# -eq 3 ] || { sed -n '6,10p' "$0"; exit 2; }
root=$(cd "$(dirname "$0")/../.." && pwd)/build/profile-cache
lib=$root/lib work=$root/build
mkdir -p "$lib" "$work"
flags="-O2 -g -fno-omit-frame-pointer -fPIC"
jobs=$(nproc 2>/dev/null || echo 4)

# Lua
rm -rf "$work/lua" && cp -a "$1" "$work/lua"
cp /usr/include/luaconf.h "$work/lua/src/luaconf.h"
(cd "$work/lua/src" && rm -f ./*.o ./*.a ./*.so* && for f in *.c; do
  case $f in lua.c|luac.c) continue ;; esac
  cc $flags -DLUA_USE_LINUX -c "$f" -o "${f%.c}.o"
done && cc -shared -Wl,-soname,liblua.so.5.5 -o "$lib/liblua.so.5.5" *.o -lm)

# SQLite
rm -rf "$work/sqlite" && mkdir -p "$work/sqlite"
(cd "$work/sqlite" && unzip -q -j "$2" '*/sqlite3.c' '*/sqlite3.h' && cc $flags -DSQLITE_THREADSAFE=1 \
  -DSQLITE_ENABLE_COLUMN_METADATA -DSQLITE_ENABLE_DBSTAT_VTAB -DSQLITE_ENABLE_FTS3 -DSQLITE_ENABLE_FTS3_PARENTHESIS \
  -DSQLITE_ENABLE_FTS4 -DSQLITE_ENABLE_FTS5 -DSQLITE_ENABLE_MATH_FUNCTIONS -DSQLITE_ENABLE_PERCENTILE \
  -DSQLITE_ENABLE_PREUPDATE_HOOK -DSQLITE_ENABLE_RTREE -DSQLITE_ENABLE_SESSION -DSQLITE_ENABLE_STAT4 \
  -DSQLITE_ENABLE_STMTVTAB -DSQLITE_ENABLE_UNLOCK_NOTIFY -DSQLITE_SECURE_DELETE -DSQLITE_DEFAULT_RECURSIVE_TRIGGERS=1 \
  -DSQLITE_MAX_VARIABLE_NUMBER=250000 -shared -Wl,-soname,libsqlite3.so.0 -o "$lib/libsqlite3.so.0" sqlite3.c -lm)

# MuPDF, against the system's third-party libraries
rm -rf "$work/mupdf" && mkdir -p "$work/mupdf"
tar -xzf "$3" -C "$work/mupdf" --strip-components=1
make -s -C "$work/mupdf" -j"$jobs" shared=yes build=release USE_SYSTEM_LIBS=yes XCFLAGS="$flags" libs
cp "$work/mupdf/build/shared-release/libmupdf.so.28.5" "$lib/"

# lulibre itself with frame pointers, from the tree's committed state
src=$(cd "$(dirname "$0")/../.." && pwd)
rm -rf "$root/lulibre" && git clone -q --shared "$src" "$root/lulibre"
git -C "$root/lulibre" checkout -q "$(git -C "$src" rev-parse HEAD)"
(cd "$root/lulibre" && ./configure CFLAGS="$flags" >/dev/null && make -s -j"$jobs")
ls -l "$lib" "$root/lulibre/build/lulibre"
