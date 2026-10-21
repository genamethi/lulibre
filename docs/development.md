# Development

## Building

    ./configure [--prefix=DIR] [--debug] [--sanitize=LIST] [--lua=5.4|5.5] [--lua-inc=DIR]
    make
    make help

configure finds the dependencies with pkgconf. It checks that the Lua
headers the compiler picks match the Lua library it links. If an old set of
headers comes earlier on the include path, configure pins the right ones;
if it can't tell where they are, `--lua-inc` says.

| Build | |
|---|---|
| release (default) | `-O2 -g`: optimised, with symbols so a crash log resolves to source lines |
| `--debug` | `-O0 -g3`, and the log's trace level |
| `--sanitize=address,undefined` · `--sanitize=thread` | a debug build with that sanitizer |

`make clean` removes what make built and keeps the configuration.
`make distclean` also removes what configure wrote. `make install` honours
`DESTDIR`, and building never needs root.

After building, `make` prints the version and md5 of the new binary next to
those of the `lulibre` on PATH. `make status` prints the same on its own.

## Version

lulibre uses semantic versioning. The version is written once, in
`src/version.h`:

```c
#define LULIBRE_VERSION_MAJOR 0
#define LULIBRE_VERSION_MINOR 1
#define LULIBRE_VERSION_PATCH 0
#define LULIBRE_VERSION_PRE ""           /* "-alpha", "-beta", "-rc.1" before a release */
```

configure reads the version, refuses anything that is not a semantic
version, and passes it to make. After you edit the header, the next `make`
runs configure again with its last arguments. To release: change the
header, run `make check e2e`, commit, and tag `vX.Y.Z[-pre]`.

## Builds

While a version is in progress, its builds are numbered 001, 002, ... in
the order they are made. Each full version string has its own count:
`0.2.0-alpha.0` starts again at 001, and so will `0.2.0-alpha.1`. `make`
gives the binary the next number whenever it links it, which happens
whenever any part of it has changed, including the Lua runtime and the
bundled scripts. The number tells one build from another in a report; it is
not part of the version.

    lulibre -V          lulibre 0.2.0-alpha.0 (debug build 007, Lua 5.5)
    make builds         the log: number, time, version, commit, branch, checkout

```
007  2026-10-13 05:10  0.2.0-alpha.0  3b3ddb3+  0.2.0-dev  /media/servd/staging/lulibre-0.2.0
```

A `+` after the commit means the tree had uncommitted changes. Those
changes are saved beside the log as `007.diff`, so you can trace a build to
exactly what it was made from: `git diff 3b3ddb3 <other commit>` between two
builds, plus each build's `.diff`.

The log is kept in the repository's own directory
(`.git/lulibre-builds/VERSION/`), which every worktree shares, so builds in
different checkouts share one sequence of numbers. The log is not
committed. In Lua, the build's number and commit are `lulibre.build.number`
and `lulibre.build.commit`, and a crash log names both.

## Tests

| | |
|---|---|
| `make unit` | `test/unit.c` (the C core) and `test/units.lua` (the Lua runtime and API) |
| `make check` | the unit tests, `test/smoke.sh` (the command line and the interface, driven through tmux, on a generated library) and `test/terminal.sh` (keys as a terminal sends them, outside tmux) |
| `make e2e` | every end-to-end test: smoke; `install.sh` (the version in every place, a staged install); `offline.sh` (changes straight to a library folder); `write.sh` (changes through a content server); `forms.sh` (the edit form, review, removal and orphans, typed into the interface) |
| `make check-offline` · `make check-write` · `make check-forms` | one of the last three |

The last three need calibre and `unshare`. They run inside a private
network namespace against throwaway libraries, because calibre refuses
direct access to any library while one of its servers runs on the machine.
If a test can't run (a missing tool, no namespace, no luv), it prints
`skipping` and the reason. Any other failure to start is a failure, not a
skip, so read `make e2e`'s output for both. No test touches a real library.

tmux sends keys plainly, so the tests driven through tmux never see what a
terminal with the kitty keyboard protocol sends (ghostty, kitty). There, a
shifted key arrives as the key plus Shift along with the text it types, and
":" arrives as ";" with Shift. `test/terminal.py` runs lulibre on its own
pseudo-terminal and types the way ghostty does, byte for byte (captured
from ghostty with notcurses' flags), and also plainly, the way tmux does.
`test/terminal.sh` runs the same checks on both. A key that works in tmux
but not in a terminal is tested there.

A sanitizer build should pass all of them cleanly:

    ./configure --sanitize=address,undefined && make e2e    # ASAN_OPTIONS=use_sigaltstack=0
    ./configure --sanitize=thread && make check

(`use_sigaltstack=0` is needed because notcurses installs its own alternate
signal stack.)

## calibre's server and the opf files

`contrib/calibre-server-opf.py` runs calibre's content server with
calibre's own `MetadataBackup` thread, which the calibre program starts for
its library (`gui2/library/models.py`, `start_metadata_backup`). The
launcher runs calibre's code in calibre's process, but it reaches into
calibre's internals, which change without notice:

- `calibre.srv.standalone`: `Server` and `main`. The launcher wraps
  `Server.__init__` and calls `main` with calibre-server's arguments.
- `Server.handler.router.ctx.library_broker`, and the broker's `lmap` and
  `get(library_id)`: the libraries the server has open.
- `Server.serve_forever`, which the launcher wraps to stop the threads once
  the server has stopped.
- `calibre.db.backup.MetadataBackup`: `start()`, `stop()`, `join()`.

The launcher was written against calibre 9.15. Its reference is calibre's
source: `src/calibre/srv/standalone.py`, `srv/library_broker.py`,
`db/backup.py`. After a calibre update, `make check-offline` runs the
launcher against the installed calibre: a title changed through the server
must reach the book's metadata.opf within 15 s. If the check fails, read
those files in the new calibre and update the launcher to match.

At run time the launcher fails soft: the server runs without the thread,
and the reason goes to its log and its status file. With
`LULIBRE_OPF_REQUIRED=1` it fails hard. `lua/lulibre/units.lua` only writes
units and doesn't depend on calibre's internals.

## The API reference

The modules' doc comments are written for LDoc (`config.ld`), which builds
the API reference from them. `make api` writes the reference to
`build/api`. Install LDoc with `luarocks --local install ldoc`, or use
`make api LDOC='lua path/to/ldoc.lua'`.

- A module's opening comment starts with `---`, says what the module does,
  and ends with its section and name (`@scripting lulibre.edit`) and an
  `@usage` example. LDoc takes the first sentence as the module's summary,
  so end it before any list.
- The sections are `scripting`, `reading`, `judging`, `library`,
  `services`, `setup` and `screens`. `config.ld` defines them (`new_type`)
  and lists the modules section by section. `tools/ldoc/ldoc.ltp`, a copy of
  LDoc's page template, shows each section's full heading and adds the
  "Manual" links back to the guides. Those links work in the site, where the
  reference is in `reference/`, but not in `build/api`.
- Each function a module exports has a `---` comment with `@tparam` and
  `@treturn`. `[opt]` marks optional arguments, and `[1]`/`[2]` alternative
  returns.
- A setting or list a module exports (`M.SHOWN`, `M.STOP`) gets its own
  `---` line.
- Every module in `lua/lulibre/` is listed in `config.ld`, except
  `commands/`, which only registers commands. Add a new module there, in its
  section.
- A `--` inside a doc comment (such as `--only` written in the text) makes
  LDoc drop the item without a warning. Write it another way.

## The documentation site

`docs/` is also a site, built with [Zensical](https://zensical.org)
(`zensical.toml`) on Read the Docs (`.readthedocs.yaml`, which pins
Zensical's version). To see the site before pushing:

    pip install zensical==0.0.71
    ldoc -d docs/reference .   # the API reference, which the site links to
    zensical serve          # http://localhost:8000; zensical build --strict writes site/

Read the Docs does the same (`.readthedocs.yaml`): it installs LDoc from
luarocks, writes the reference into `docs/reference` (not kept in git; `docs/api` would clash with the page `api.md`), then
runs Zensical. The other configuration,
`tools/readthedocs-ldoc/.readthedocs.yaml`, builds a site of LDoc's
reference alone. The project's "path for .readthedocs.yaml" setting on Read
the Docs chooses between them.

Add a new page to `nav` in `zensical.toml`. Links between pages are
relative (`[Keys](keys.md)`). A link to a file outside `docs/` (the README,
the changelog) uses the file's address on GitHub.

## Crashes

A fatal signal appends the version and a backtrace to
`~/.local/state/lulibre/crash.log`, before the terminal is restored and the
core is dumped. Frames read `lulibre(+0xOFFSET)`, and
`addr2line -fe $(command -v lulibre) 0xOFFSET` gives the function and line.
Where systemd keeps cores, `coredumpctl info lulibre` has the same stack.

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
- **The Lua thread** (while the interface is up) owns the Lua state, the
  task scheduler, a second loop and its own database connection.
- **The libuv pool** does extraction, rendering, hashing, copies of
  databases (`lulibre.copy_db`) and the list's queries. A job touches only
  what it was given and what it opens itself. Its result arrives on the loop
  that queued it.

`src/lua/bridge.c` connects the first two threads. Lua calls into the
interface with `ui_call`, which runs a C function on the interface thread
while the Lua thread waits, so the function may use the Lua state. The
interface sends work to Lua with `bridge_lua`, which queues the work and
returns. The interface never waits for Lua. Two rules follow:

- A `lulibre.x` that touches the interface, the options, or the command and
  key tables is a one-line wrapper around `x_ui` (see `ON_UI` in `l_ui.c`).
- A function that waits calls `sched_begin_wait` on the Lua thread, then
  sets up through `ui_pcall`, then yields.

## Reentrancy

Code here runs on several threads (see above) and, within the Lua thread,
in tasks that can be interrupted at any point. All code is held strictly to
the rules below: new code is checked against them, and old code is brought
to them when it is touched.

**C**

- No hidden shared state. A function that returns text writes into its
  caller's buffer. `key_hint(c)` and `ctx_hint(p, a)` are macros that give
  each call its own buffer (`key_hint_in(buf, n, c)` for a buffer you keep).
  Use `errstr(err)` instead of `strerror`, which is not thread-safe. Use
  `qsort_r` with the state as its argument, never a global for a
  comparator. A message built for a caller is allocated and freed by that
  caller (`lstate_tree_mismatch`).
- These stay global on purpose: the command and key tables (owned by the
  interface thread; Lua reaches them only through `ui_call`), the
  clipboard's last copy, and the source tree a binary runs from. Anything
  added to this list needs a reason.
- A worker job (`uv_queue_work`) touches only what it was given and what it
  opens itself, including its own SQLite connections. Its result is
  delivered in the after-callback, on the loop that queued it, and the
  waiting task is woken from there (`sched_end_wait`, `sched_wake`).

**Lua**

- Tasks can be interrupted between any two VM instructions: a count hook
  runs every 1000 instructions and yields once a 4 ms slice is used up. A
  read and a write of shared state are two steps, and another task can run
  between them.
- Take a test followed by a set in one step with `lulibre.claim(t, key)`.
  A C call is a single step, so no task can run in between. (net.lua's one
  request at a time per service is a claim.)
- Build a table that tasks share in a local, and put it in place with one
  assignment. Never fill it in place where another task may read it half
  built (the caches in junk, names, quality, subjects, the C-module probes).
- For counters and lists that tasks share, use `lulibre.each`,
  `table.insert` and `table.remove` (one C call each), not `t[#t + 1] = v`
  (two steps).
- A C function that calls back into Lua while the interface thread works
  (`ui_call`) does so under `lua_pcall` there. The error is raised again on
  the Lua thread, with the garbage collector stopped in the meantime.

**Testing it**

A test for a race must hold the window open longer than a slice (a loop of
some 1.5 million iterations between the test and the set, in
`test/units.lua`'s claim check). Otherwise the test passes whether or not
the fix is in. `./configure --sanitize=thread` builds with ThreadSanitizer
for the C side.

## The index

The index is one SQLite file per library (WAL). Most of it either mirrors
calibre's `metadata.db`, and is replaced whole when that changes, or holds
extracted text. A few tables are lulibre's own and are never dropped:
`proposals`, `kv`, `hashes`, `staged`, `good` (records confirmed as right),
`terms` (the phrases learned for each subject), `refs` (what each book
cites) and `lookups` (what metadata services answered).

Two files beside the index hold what must outlive it (`src/db/db.c`):
`<index>.history.db` holds the journal of changes, the snapshots and the
changes waiting for the server (`offline`); `<index>.custom.db` holds your
own fields. Staged files get rows in the mirror tables under negative ids
(`src/db/stage.c`), which lets the list, the filters and the API treat them
as books.

lulibre opens `metadata.db` read-only. Every change to a book goes through
`calibredb`. The one exception is putting back one of lulibre's copies of
the database (`:backup restore`, `lua/lulibre/backup.lua`). That happens
only when nothing has the library open, after a copy of the current
database is made, and through SQLite's backup.
