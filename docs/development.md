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
`DESTDIR`, `BINDIR` and `DATADIR`, and building never needs root. An
installed lulibre reads its files from `share/lulibre` beside its `bin`, so
one build installs under any prefix.

Setup is separate from the build. `build/lulibre-setup` (src/setup/) keeps
the choices in `setup.conf`, and `setup/install.sh` carries them out;
`sh setup/install.sh -n` prints the commands without running them.

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
committed. In Lua, the build's number and commit are `lulib.build.number`
and `lulib.build.commit`, and a crash log names both.

## Tests

| | |
|---|---|
| `make unit` | `test/unit.c` (the C core) and `test/core.c` (the 0.3 runtime: settings, events, the registry) |
| `make check` | the unit tests, `test/runtime.sh` (settings, init.lua, where modules are found), `test/net.sh` (online lookups with canned answers, no network) and `test/curl.sh` (the curl module against a server of its own in a private network namespace) |
| `make e2e` | every end-to-end test: those three, `test/write.sh` (the write path against throwaway libraries, straight to the folder and through a content server) and `test/tasks.py` (tasks that never wait, in the interface on a pseudo-terminal: reported, cancelled, and quitting past one) |

`test/setup.sh` tests lulibre-setup, which still writes 0.2's init.lua; it
comes back into the targets with lulibre-setup's rework.

Previously the end-to-end tests drove the 0.2 Lua runtime. Now they are
written again as each part of 0.3 is.

Tests that write need calibre and `unshare`. They run inside a private
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
signal stack. Without it, the interface exits with status 1 and ASan reports
"failed to deallocate 0x34c0 (13504) bytes ... (error code: 22)": ASan
cannot free its own stack once notcurses has replaced it. The 0.2 code does
the same, and with the option set the report is gone.)

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
`db/backup.py`. After a calibre update, read those files in the new
calibre and update the launcher to match.

At run time the launcher fails soft: the server runs without the thread,
and the reason goes to its log and its status file. With
`LULIBRE_OPF_REQUIRED=1` it fails hard.

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
    src/app.c       what every part shares: the settings, the index, the library
    src/work.c      the background thread: the library and the indexer
    src/core/       the settings store, the message queue, shared events, the registry, requests (libcurl), strings, the log
    src/db/         schema, calibre mirror, staged files, SQL functions, the filter language
    src/doc/        text extraction and rendering (mupdf, djvulibre, plain text); a file's reading
    src/index/      the parallel indexer, OCR, what reading a file came to
    src/library/    calibre's library as a resource: its holder, operations, the journal, the write core's values
    src/match/      text folding, fuzzy matching, the similarity measure
    src/tui/        the interface: windows, views, keymap, commands, pickers, console, the edit form
    src/setup/      lulibre-setup (still 0.2's; setup/ holds install.sh)
    src/lua/        Lua state, task scheduler, the threads, calls into the interface, the libraries (one l_*.c each)
    src/cmd/        command-line front ends
    lua/            the modules written in Lua: expr, lex, iter, wit, net, trust
    lua/lulibre/    lulibre's own: grammars, propose, ranking, review, commands
    vendor/         libraries carried as their authors wrote them, built in (lsqlite3)
    test/  tools/

## Threads

- **The interface thread** (the main thread) owns the terminal, the
  windows, the list, the settings store and its own libuv loop.
- **The background thread** (`src/work.c`, while the interface is up) owns
  calibre's library (its holder, the calibredb runs, the journal, reading
  the records again) and the indexer, with a loop and a connection to the
  index of its own, and a copy of the settings. It runs no Lua: a reader or
  a store of Lua's is asked on the Lua thread by message. An operation
  carries the settings it was made with, so a change made after
  `setman.set("embed", true)` embeds.
- **The Lua thread** (while the interface is up) owns the Lua state, the
  task scheduler, a second loop and its own database connection.
- **The libuv pool** does extraction, OCR, rendering, readings, hashing,
  reading calibre's records into the index, and the list's queries. A job touches only what it was given and what it
  opens itself. Its result arrives on the loop that queued it.

The threads talk by messages (`src/core/queue.h`): each loop has an inbox,
a message is a function and the value it owns, and it runs on the inbox's
loop, never in the sender's stack. Neither thread waits for the other. A
`uiman.x` that touches the interface is a one-line wrapper around `x_ui`:
`SEND` copies the arguments into a message and returns; `ASK` yields the
task until the answer comes back as a message (`src/lua/uicall.c`). The
interface runs `x_ui` on a lua_State of its own that holds only the copied
values. C never calls Lua and waits: where Lua may take a part's place
(`src/core/registry.h`), C asks by message and goes on when the answer
comes.

## Reentrancy

Code here runs on several threads (see above) and, within the Lua thread,
in tasks that take turns where they wait.

**C**

- No hidden shared state. A function that returns text writes into its
  caller's buffer. `key_hint(c)` and `ctx_hint(p, a)` are macros that give
  each call its own buffer (`key_hint_in(buf, n, c)` for a buffer you keep).
  Use `errstr(err)` instead of `strerror`, and `strtok_r`: workers run at
  once. A message built for a caller is allocated and freed by that caller.
- State belongs to one thread. Another thread reaches it by message, or
  reads a copy: the lua_State keeps a copy of the settings in its registry,
  which the store keeps current by message.
- A worker job (`uv_queue_work`) touches only what it was given and what it
  opens itself, including its own SQLite connections. Its result is
  delivered in the after-callback, on the loop that queued it, and the
  waiting task is woken from there (`sched_end_wait`, `sched_wake`).

**Lua**

- Tasks give way only where they wait (`src/lua/sched.h`): between two
  waits, a task's reads and writes of shared state are one step for the
  others. A task that waits in the middle of an update (a test, then a
  wait, then a write) owns what it updates across the wait, by a flag it
  sets before waiting.
- A task that runs 2 s without waiting gets a hook, installed by a signal:
  each run arms a timer that sends it to the thread running Lua, and a run
  that waits sooner disarms it (`src/lua/sched.c`), with the interface or
  without. The hook reports the task, and stops it once cancelled, by
  yielding, which no pcall catches. No hook runs otherwise: a count hook
  makes every Lua instruction about twice as slow. `:cancel` reaches a
  running task by the same signal, sent by the interface thread
  (`src/lua/bridge.c`), since a task that runs reads no message. `coroutine.resume` and `coroutine.wrap` are the
  scheduler's own (as Lua's otherwise), so the hook goes on a coroutine the
  task resumed, and a cancelled task yields up through each resume.
  `:tasks` shows the list the scheduler sent at its last change, and the
  running task's time, without asking the Lua thread.
- Code that may run again while it waits takes its values once, at its
  start, in `<const>` locals (`setman.get`), and passes them down: the
  functions it calls take them as arguments.
- A resource lives on the stack of the task that opened it, in a `<close>`
  variable. A request C hands a task to answer (`src/lua/reply.c`) is one:
  closed unanswered, it fails the request, so C never waits for an answer
  that cannot come.

**Testing it**

A test for a race between threads must hold the window open: otherwise
the test passes whether or not the fix is in. `./configure
--sanitize=thread` builds with ThreadSanitizer for the C side. TSan holds
a signal back until the thread calls into the C library (allocating
counts), so under TSan a task that computes without allocating is neither
reported nor stopped, and `test/tasks.py` fails.

## The index

The index is one SQLite file per library (WAL). Most of it either mirrors
calibre's `metadata.db` or holds what was read from the files. When
`metadata.db` changes, only the books calibre marked changed (its
`last_modified`) are copied again, along with the books it added or
removed, and the tables of names are replaced. Every book is copied again
when the copy's SQL changes (`MIRROR_VERSION`, `src/db/mirror.c`), when the
library moves, when calibre's custom columns change, or on `:reload`. From
the files, the index holds their outcomes and their lines (the only
stored text), and a contentless full-text row per paragraph. A new version
of its tables (`SCHEMA_VERSION`, `src/db/db.c`) drops all that and reads
again; `staged` and `kv` stay.

Three files beside the index hold what must outlive it (`src/db/db.c`):
`<index>.journal.db` holds every operation on the library through its
lifecycle, with where each value came from, `<index>.custom.db` holds
your own fields, and `<index>.wit.db` the wits waiting for review, which
`lua/wit.lua` writes through lsqlite3. Online answers are kept for every
library in `net.db` (`lua/net/service.lua`). Staged files get rows in the mirror tables under negative
ids (`src/db/stage.c`), which lets the list, the filters and the API treat
them as books.

lulibre opens `metadata.db` read-only. Every change to a book goes through
`calibredb`, or a store of Lua's in its place.
