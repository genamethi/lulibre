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
the order they are made, each version as it is written in full having its
own count (`0.2.0-alpha.0` begins again at 001, as `0.2.0-alpha.1` will). `make` gives the binary the next number whenever it
links it, which is whenever anything it is made of has changed, the Lua
runtime and the bundled scripts included. The number is for telling one
build from another when something is reported; it is not part of the
version.

    lulibre -V          lulibre 0.2.0-alpha.0 (debug build 007, Lua 5.5)
    make builds         the log: number, time, version, commit, branch, checkout

```
007  2026-10-13 05:10  0.2.0-alpha.0  3b3ddb3+  0.2.0-dev  /media/servd/staging/lulibre-0.2.0
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
| `make check` | those, `test/smoke.sh` (the command line and the interface, driven through tmux, on a generated library) and `test/terminal.sh` (keys as a terminal sends them, outside tmux) |
| `make e2e` | every end-to-end test: smoke; `install.sh` (the version in every place, a staged install); `offline.sh` (changes straight to a library folder); `write.sh` (changes through a content server); `forms.sh` (the edit form, review, removal and orphans, typed into the interface) |
| `make check-offline` · `make check-write` · `make check-forms` | one of the last three |

The last three need calibre and `unshare`: they run inside a private network
namespace against throwaway libraries, because calibre refuses direct access
to any library while one of its servers runs on the machine. They skip where
that is not possible, saying `skipping` and why: a missing tool, no
namespace, no luv. Any other failure to start is a failure, not a skip, so
read `make e2e`'s output for both. Nothing touches a real library.

tmux sends keys plainly, so the tests driven through it never see what a
terminal with the kitty keyboard protocol sends (ghostty, kitty): there a
shifted key comes as the key and Shift with the text it types, ":" as ";"
with Shift. `test/terminal.py` runs lulibre on a pseudo-terminal of its own
and types as ghostty does, byte for byte (captured from it with notcurses'
flags), and plainly as tmux does; `test/terminal.sh` holds both to the same
checks. A key that works in tmux and not in a terminal is tested there.

A sanitizer build should stay clean on all of them:

    ./configure --sanitize=address,undefined && make e2e    # ASAN_OPTIONS=use_sigaltstack=0
    ./configure --sanitize=thread && make check

(`use_sigaltstack=0` because notcurses installs its own alternate signal stack.)

## calibre's server and the opf files

`contrib/calibre-server-opf.py` runs calibre's content server with calibre's
own `MetadataBackup` thread, which calibre's program starts for its library
(`gui2/library/models.py`, `start_metadata_backup`). It is calibre's code in
calibre's process, but it reaches into calibre's internals, which change
without notice:

- `calibre.srv.standalone`: `Server`, `main` (it wraps `Server.__init__` and
  calls `main` with calibre-server's arguments);
- `Server.handler.router.ctx.library_broker`, and the broker's `lmap` and
  `get(library_id)` (the libraries the server has, opened);
- `Server.serve_forever`, an attribute it wraps to stop the threads once
  the server has stopped;
- `calibre.db.backup.MetadataBackup`: `start()`, `stop()`, `join()`.

Written against calibre 9.15 (its source is the reference: `src/calibre/srv/
standalone.py`, `srv/library_broker.py`, `db/backup.py`). After a calibre
update, `make check-offline` runs the launcher against the installed
calibre: a title changed through the server must reach the book's
metadata.opf within 15 s. When it fails, read those files of the new calibre
and bring the launcher to them. The launcher fails soft at run time (the
server without the thread, the reason in its log and its status file) and
hard with `LULIBRE_OPF_REQUIRED=1`. `scripts/server-unit.lua` only changes
units; it does not depend on calibre's internals.

## The API reference

The modules' doc comments are written for LDoc (`config.ld`), which makes
the API reference from them: `make api` writes it to `build/api` (LDoc from
`luarocks --local install ldoc`, or `make api LDOC='lua path/to/ldoc.lua'`).
A module's opening comment starts with `---`, says what it is, and ends
with `@module lulibre.NAME` and an `@usage` example; each function a module
exports has a `---` comment with `@tparam`, `@treturn` (and `[opt]`,
`[1]`/`[2]` for optional arguments and alternative returns). A setting or
list a module exports (`M.SHOWN`, `M.STOP`) gets a `---` line of its own.
Done so far: `lulibre.verify`, `lulibre.backup`, `lulibre.offline`; the
others are listed in `config.ld` as they are done.

## The documentation site

`docs/` is also a site, built with [Zensical](https://zensical.org)
(`zensical.toml`) by Read the Docs (`.readthedocs.yaml`, which pins the
version). To see it before pushing:

    pip install zensical==0.0.71
    ldoc -d docs/api .      # the API reference, which the site links to
    zensical serve          # http://localhost:8000; zensical build --strict writes site/

Read the Docs does the same (`.readthedocs.yaml`): LDoc from luarocks,
written into `docs/api` (not kept in git), then Zensical. The other
configuration, `tools/readthedocs-ldoc/.readthedocs.yaml`, makes the site of
LDoc's reference alone; which one is used is the project's "path for
.readthedocs.yaml" on Read the Docs.

A new page goes in `nav` in `zensical.toml`. Links between pages are
relative (`[Keys](keys.md)`); a link to a file outside `docs/` (the README,
the changelog) is written as its address on GitHub.

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
- **The libuv pool** does extraction, rendering, hashing, copies of
  databases (`lulibre.copy_db`) and the list's queries. A job touches only
  what it was handed and what it opens itself; its answer arrives on the
  loop that queued it.

`src/lua/bridge.c` connects the first two. Lua calls into the interface with
`ui_call`, which runs a C function on the interface thread while the Lua
thread waits (so it may use the Lua state); the interface sends work to Lua
with `bridge_lua`, which queues it and returns. The interface never waits
for Lua. Two rules follow:

- A `lulibre.x` that touches the interface, the options or the command and
  key tables is a one-line wrapper around `x_ui` (see `ON_UI` in `l_ui.c`).
- A function that waits calls `sched_begin_wait` on the Lua thread, then
  sets up through `ui_pcall`, then yields.

## Reentrancy

Code here runs on several threads (above) and, within the Lua thread, in
tasks that are interrupted at any point. Code is held to this strictly, and
the work goes on: new code is checked against it, and old code as it is
touched. What a change must keep to:

**C**

- No hidden shared state. A function that hands out text writes into a
  buffer of its caller's: `key_hint(c)` and `ctx_hint(p, a)` are macros
  that give each call a buffer of its own (`key_hint_in(buf, n, c)` for one
  you keep); `errstr(err)` in place of `strerror` (not thread-safe);
  `qsort_r` with the state as its argument, never a global for a
  comparator. A message built for a caller is allocated and freed by it
  (`lstate_tree_mismatch`).
- What stays global, on purpose: the command and key tables (the
  interface thread's own; Lua reaches them only through `ui_call`), the
  clipboard's last copy, the source tree a binary runs from. Anything added
  to this list is argued for.
- A worker job (`uv_queue_work`) touches only what it was handed and what it
  opens itself, its own SQLite connections included; its answer is
  delivered in the after-callback, on the loop that queued it, and the task
  waiting for it is woken from there (`sched_end_wait`, `sched_wake`).

**Lua**

- Tasks are interrupted between any two VM instructions: a count hook every
  1000 instructions yields once a 4 ms slice is spent. A read and a write of
  shared state are two steps another task can come between.
- A test followed by a set is taken in one step with `lulibre.claim(t,
  key)`: a C call is a single step, so no task comes between. (net.lua's
  one request at a time per service is a claim.)
- A table tasks share is built in a local and put in place with one
  assignment, never filled in place where another task may read it half
  made (the caches in junk, names, quality, subjects, the C-module probes).
- Counters and lists tasks share: `lulibre.each`, `table.insert`,
  `table.remove` (one C call each), not `t[#t + 1] = v` (two steps).
- A C function that calls back into Lua while the interface thread works
  (`ui_call`) does so under `lua_pcall` there; the error is raised again on
  the Lua thread, with the collector stopped meanwhile.

**Testing it**

A test of a race holds what it tests for longer than a slice (a loop of
some 1.5 million iterations between the test and the set, in
`test/units.lua`'s claim check), or it passes whether or not the fix is in.
`./configure --sanitize=thread` builds with ThreadSanitizer for the C side.

## The index

One SQLite file per library (WAL). Most of it mirrors calibre's
`metadata.db` and is replaced wholesale when that changes, or holds extracted
text. A few tables are lulibre's own and are never dropped: `proposals`,
`kv`, `hashes`, `staged`, `good` (records confirmed as right), `terms` (the
phrases learned for each subject), `refs` (what each book cites) and
`lookups` (what metadata services answered). Two files beside the index
hold what must outlive it (`src/db/db.c`): `<index>.history.db`, the
journal of changes, snapshots and the changes waiting for the server
(`offline`); `<index>.custom.db`, your own fields. Staged files are given
rows in the mirror tables under negative ids (`src/db/stage.c`), which is
what lets the list, the filters and the API treat them as books.

lulibre reads `metadata.db` read-only. Every change to a book goes through
`calibredb`. The one exception is putting one of lulibre's copies of it
back (`:backup restore`, `lua/lulibre/backup.lua`): with nothing holding the
library, after a copy of it as it is, through SQLite's backup.
