# Development

## Building

    ./configure [--prefix=DIR] [--debug] [--sanitize=LIST] [--lua=5.4|5.5] [--lua-inc=DIR]
    make
    make help

Dependencies are found with pkgconf. configure checks that the Lua headers
the compiler picks match the library it links, and pins the right ones if a
stale set is earlier on the include path (`--lua-inc` says where, if it
cannot tell).

| Build | |
|---|---|
| release (default) | `-O2 -g`: optimised, with symbols so a crash log resolves to lines |
| `--debug` | `-O0 -g3`, and the trace level of the log |
| `--sanitize=address,undefined` · `--sanitize=thread` | a debug build with that sanitizer |

`make clean` removes what make built and keeps the configuration;
`make distclean` also removes what configure wrote. `make install` honours
`DESTDIR`, and never needs to be run as root to build.

After building, `make` prints the version built and the binary's md5 next to
those of the `lulibre` on PATH (`make status` alone does the same).

## Version

Semantic versioning. The version is written once, in `src/version.h`:

```c
#define LULIBRE_VERSION_MAJOR 0
#define LULIBRE_VERSION_MINOR 1
#define LULIBRE_VERSION_PATCH 0
#define LULIBRE_VERSION_PRE ""           /* "-alpha", "-beta", "-rc.1" before a release */
```

configure reads it, refuses anything that is not a semantic version, and
hands it to make. Editing the header makes the next `make` re-run configure
as it was last run. To release: change the header, `make check e2e`, commit,
tag `vX.Y.Z[-pre]`.

## Builds

While a version is in the making its builds are numbered: 001, 002, ... in
the order they are made. `make` gives the binary the next number whenever it
links it, which is whenever anything it is made of has changed, the Lua
runtime and the bundled scripts included. The number is for telling one
build from another when something is reported; it is not part of the
version.

    lulibre -V          lulibre 0.2.0-dev (debug build 007, Lua 5.5)
    make builds         the log: number, time, version, commit, branch, checkout

```
007  2026-10-12 21:40  0.2.0-dev  3b3ddb3+  0.2.0-dev  /media/servd/staging/lulibre-0.2.0
```

The commit carries a `+` when the tree had changes not yet committed; those
changes are saved beside the log as `007.diff`, so a build can be traced to
exactly what it was made from: `git diff 3b3ddb3 <other commit>` between two
builds, plus the `.diff` of each. The log is kept in the repository's own
directory (`.git/lulibre-builds/VERSION/`), which every worktree shares, so
builds made in different checkouts are numbered in one sequence; it is not
committed. From Lua the number and commit are `lulibre.build.number` and
`lulibre.build.commit`, and a crash log names them.

## Tests

| | |
|---|---|
| `make unit` | `test/unit.c` (the C core) and `test/units.lua` (the Lua runtime and API) |
| `make check` | those, and `test/smoke.sh`: the command line and the interface, driven through tmux, on a generated library |
| `make e2e` | every end-to-end test: smoke; `install.sh` (the version in every place, a staged install); `offline.sh` (changes straight to a library folder); `write.sh` (changes through a content server); `forms.sh` (the edit form, review, removal and orphans, typed into the interface) |
| `make check-offline` · `make check-write` · `make check-forms` | one of the last three |

The last three need calibre and `unshare`: they run inside a private network
namespace against throwaway libraries, because calibre refuses direct access
to any library while one of its servers runs on the machine. They skip where
that is not possible. Nothing touches a real library.

A sanitizer build should stay clean on all of them:

    ./configure --sanitize=address,undefined && make e2e    # ASAN_OPTIONS=use_sigaltstack=0
    ./configure --sanitize=thread && make check

(`use_sigaltstack=0` because notcurses installs its own alternate signal stack.)

## Crashes

A fatal signal appends the version and a backtrace to
`~/.local/state/lulibre/crash.log` before the terminal is restored and the
core is dumped. Frames read `lulibre(+0xOFFSET)`;
`addr2line -fe $(command -v lulibre) 0xOFFSET` names the function and line.
`coredumpctl info lulibre` has the same stack where systemd keeps cores.

## Layout

    src/version.h   the version
    src/main.c      argument parsing, command dispatch
    src/app.c       what every part shares: the index, the worker count
    src/core/       strings, paths, options, md5, the log
    src/db/         schema, calibre mirror, staged files, SQL functions, the filter language
    src/doc/        text extraction and rendering: mupdf, djvulibre, plain text
    src/index/      the parallel indexer
    src/match/      text folding, fuzzy matching
    src/tui/        the interface: windows, views, keymap, commands, pickers, console
    src/lua/        Lua state, task scheduler, the bridge between threads, the API (one l_*.c per module)
    src/cmd/        command-line front ends
    lua/lulibre/    the runtime written in Lua; ui/ holds the screens built on panels
    scripts/        bundled scripts
    test/  tools/

## Threads

- **The interface thread** owns the terminal, the windows, the list, the
  options and its own libuv loop. It never opens a book file and never
  touches the Lua state.
- **The Lua thread** (when the interface is up) owns the Lua state, the task
  scheduler, a second loop and its own database connection.
- **The libuv pool** does extraction, rendering, hashing and the list's
  queries.

`src/lua/bridge.c` connects the first two. Lua calls into the interface with
`ui_call`, which runs a C function on the interface thread while the Lua
thread waits (so it may use the Lua state); the interface sends work to Lua
with `bridge_lua`, which queues it and returns. The interface never waits
for Lua. Two rules follow:

- A `lulibre.x` that touches the interface, the options or the command and
  key tables is a one-line wrapper around `x_ui` (see `ON_UI` in `l_ui.c`).
- A function that waits calls `sched_begin_wait` on the Lua thread, then
  sets up through `ui_pcall`, then yields.

## The index

One SQLite file per library (WAL). Most of it mirrors calibre's
`metadata.db` and is replaced wholesale when that changes, or holds extracted
text. A few tables are lulibre's own and are never dropped: `proposals`,
`journal`, `kv`, `hashes`, `staged`. Staged files are also given rows in the
mirror tables under negative ids (`src/db/stage.c`), which is what lets the
list, the filters and the API treat them as books.

A few tables are lulibre's own and are never dropped: `proposals`,
`journal`, `kv`, `hashes`, `staged`, `good` (records confirmed as right) and
`terms` (the phrases learned for each subject).

lulibre reads `metadata.db` read-only. Every change goes through `calibredb`.
