# Notes for an agent working on lulibre

Rules for working on lulibre, and facts about calibre measured for it.

## A library is the motivation, not the work

A calibre library's problems show what the program cannot do yet: a title
it cannot write, a value it cannot check, a step that takes a person too
long. That is what gets built. Organizing someone's library is not the
work: do not run cleanups on it, report its state item by item, or list
its chores as tasks. Say what a library showed only as far as it explains
the feature.

## Every setup is supported

lulibre works beside calibre's desktop program as fully as beside its
content server. A design that holds only because nothing else writes the
library (or because the program is never open) is wrong. Before a feature
is done, ask what it does with the program running, with the server only,
with neither, and with the program running its own server; and whether it
touches anything the program also writes (metadata.db, the opf files, the
book folders, covers). What could compete with the program is watched while
it happens, not assumed away.

## Branches and versions

- `main` is the line being developed; a release has its own branch for
  patches (`0.1`). Work for a version is put together on an integration
  branch (`0.2.0-dev`): each change is a branch `<version>-<name>`, merged
  into it with `--no-ff`, and the integration branch is merged into `main`
  when a batch is whole and passes.
- A checkout someone runs lulibre from is not touched by branch work: a
  binary run from a source tree reads its Lua files from that tree as it
  needs them, so checking out or merging there breaks the program while it
  runs. Branch work happens in a separate worktree; the other checkout
  changes only by a merge, gated on lulibre not running there and the tree
  being clean:
  `if pgrep -x lulibre >/dev/null; then ...; elif [ -n "$(git status --short)" ]; then ...; else git merge --no-ff ... && make; fi`.
  A check that only prints is no check.
- Run `make check` and `make e2e` and read the results before the merge,
  not in the same pipeline as it.
- The version is written in `src/version.h` and nowhere else.
- `make` numbers the builds of a version, each version as written in full
  counting from 001 (docs/development.md, Builds); `lulibre -V` shows it.
- A change is committed on its branch with its tests, and its CHANGELOG
  entry and docs in the same branch: a feature is not done while its docs
  describe the one before it. A fix comes with a test that fails without it.

### Moving to the next version

When the maintainer decides (never as a consequence of a batch being done),
on a branch:

1. `src/version.h`: the pre-release tag (`-alpha.0`, `-beta.0`, `-rc.1`,
   `""` for a release), or the numbers. `./configure` reads it, and `make`
   runs configure again when the header changes.
2. `CHANGELOG.md`: the "in development" section takes the version as its
   heading; a new one is opened above it when work for the next begins.
3. `man/lulibre.1`: the date and version in its `.TH` line.
4. `make check` and `make e2e`, then merged like any other change. The
   build number starts again at 001.
5. After the merge and `make`: an annotated tag,
   `git tag -a v0.2.0-alpha.0 -m "lulibre 0.2.0-alpha.0"`. Releases and
   pre-releases are tagged; builds are not.

## What counts as a bug

- Behaviour that surprises the person using it, including a limitation
  chosen on purpose. When choosing the more restrictive of two behaviours,
  say so at the time and ask.
- A claim narrower than it sounds. Say what was verified and how ("tested
  with synthetic mouse events in tmux, not with a pointer in a terminal" is
  a result; "mouse works" is not).

## Before believing a report is a code bug

- Read the reporter's `init.lua` first; read it, never edit it (defaults
  belong in the repo, in what `lulibre config` writes).
- For a crash, read `coredumpctl info` and `~/.local/state/lulibre/crash.log`
  before reasoning from the source.

## Never touch

- A real calibre library. Every write path is tested against a throwaway
  library inside `unshare -rn` (`make check-offline`, `make check-write`):
  calibre refuses direct access to any library while one of its programs
  runs, and the namespace hides its lock.
- The user's tmux buffers and clipboard. Anything that copies is tested
  inside a private tmux server (`tmux -L ...`).
- A real index: no marks, proposals or settings left behind when looking.

## Code rules that are easy to break

- Two threads own state when the interface is up, the interface's and
  Lua's. A `lulibre.x` that touches the interface, the options or the
  command and key tables runs through `ui_call` (`ON_UI` in
  `src/lua/l_ui.c`); interface code never touches the Lua state, it sends a
  message with `bridge_lua`. Worker threads run `uv_queue_work` jobs
  (indexing, hashing, extracting, copying a database): a job touches only
  what it was handed and what it opens itself, and its answer is delivered
  in the after-callback, on the loop that queued it.
- No hidden shared state in C: no static buffers handed out (give each call
  a buffer of the caller's, as `key_hint` and `errstr` do), no globals for
  a comparator (`qsort_r`), no `strerror` (`errstr`).
- Lua at the prelude's top level runs before `-L` and `init.lua` are
  applied: anything there that opens the index ends lulibre with "no
  library" in a run without one. Put it in a task (`lulibre.spawn`).
- Lua tasks are interrupted between any two operations (a count hook, once
  a 4 ms slice is spent). Shared counters lose counts: use `lulibre.each`,
  `table.insert`, `table.remove`. A test followed by a set is two steps:
  take it with `lulibre.claim(t, key)`, one C call. A table tasks share is
  built in a local and put in place with one assignment. A test of any of
  this holds what it tests for longer than a slice, or it passes without
  the fix.
- luv belongs to the main Lua state, loaded once at startup; never arrange
  for a task's coroutine to be the state a C library keeps.
- A panel reserves `g` (for `gg`), `j`, `k`, `G`, `q`, `Esc`, `Tab`, `:`.
- A screen written in Lua never compares a key with a letter: it asks its
  key table (`lua/lulibre/ui/keys.lua`) which action the key means, and its
  hint and `?` help are written from that table. A new action goes into the
  table with a label and a description.
- C code for a place with keys of its own (a panel's movement, the line
  editor, picker, pager, console) asks `ctx_feed(KC_..., &pending, key)`
  for the action (`src/tui/ctxkeys.c`; the enums in `tui.h` follow it).
- Nothing shown names a key literally: C uses `key_hint("the command")` or
  `ctx_hint(place, action)`, Lua `lulibre.hint("the command")`, a screen
  `keys:key(action)`. Keys are rebindable, and what is shown says so.
- A command acts on what the *focused* cursor shows. With a panel that
  follows the list focused, that is the panel row's book, not the list's
  cursor; `lulibre.selection()` settles it.
- Closing a window frees its node *and its sibling's* (the sibling's
  contents move up into the parent). Never keep a `struct node *` across a
  close; `wm_close_leaf` closes a given window and keeps `t->focus` valid.
  A view's state pointer kept elsewhere (`t->drag`) is checked against the
  windows, class included, before every use.
- Whatever takes over the bottom line or the keyboard (`tui_prompt`,
  `picker_open`) first answers a question still open as cancelled, or a
  script waiting on it waits for ever.
- Lua code runs on 5.4 and 5.5: never assign to a `for` loop's own variable
  (5.5 will not load the file; `make unit` compiles every Lua file).
- Lua patterns work on bytes: a character outside ASCII is several, so
  `©?` or `[çc]` do not mean what they seem. Write the bytes, list the
  spellings, or replace whole sequences; test such a pattern with and
  without the character.
- `src/core/log.h` includes the generated `<config.h>` with angle brackets,
  because `src/core/config.h` is the options header.
- A C module found on the default `cpath` may be built against another
  Lua's headers and crash in `luaopen_*`. Before blaming a widely used
  library, check the build environment (headers, ABI, the library linked).

## Verifying

- Anything that writes lulibre's own tables in bulk (`:learn`, confirming
  records) is tried on a copy of the index, run with `-o index=COPY`. Take
  the copy with `sqlite3 'file:NAME.db?mode=ro' ".backup COPY"` (a plain
  `cp` of an index in use can be torn), after removing any `COPY-wal` /
  `-shm` left from an earlier copy of that name.
- Anything that deletes "what belongs to X" is counted on a copy before and
  after, by status: the numbers outside X must come back exactly.
- A matching rule is measured against every case there is before it is
  believed: list what it accepts on a copy, read the list, count. A search
  always returns something. After a rule changes, run it over a whole copy
  and read what it now refuses and what it would still put over a value a
  book has.
- "The library holds it" is not evidence: a value there may have been
  proposed by this program and accepted in a batch. Check what a value
  rests on against something independent (the file's text, the book's
  other fields).
- A confidence says how sure this value is, not how good its source is: a
  record reached through a guess carries the guess's confidence on every
  field.
- Commands put end to end make something new: read what each says when it
  finishes, in that sequence.
- The proposer is measured on a bare copy: links to the book folders, a
  metadata.db stripped to "Untitled / Unknown" by hand with sqlite (never
  through calibredb, which renames the folders the links point at), a copy
  of the index. Compare the proposals with the real records by field and
  confidence.
- A learned or statistical feature is reported with a held-out number.
- A word list that removes "noise" is tested against the phrases that must
  survive it.
- A heuristic that repairs in bulk is run over a whole copy and the changed
  items read one by one before it is trusted.
- A file somebody else made is opened before code is written for it.
- Code that talks to another service is written from that service's own
  terms, read first and linked in a comment. The rules (`net.lua`): one
  request at a time, no retry after 429/503 but a pause that outlives the
  run, no fallback that multiplies requests, an empty or broken answer not
  remembered as "no such record". A parser for its answers is checked
  against one real answer, which (cut down) becomes the test.

## Tests

- `make check` always; `make e2e` before every merge. Read its log for
  `skipping` as well as `FAIL`: offline, write and forms skip when their
  tools are missing, and only then.
- A change to a form (edit, review, duplicates, orphans) gets a keystroke
  check in `test/forms.sh`. The configuration window's check counts rows
  down to `pages`: an option added above it moves it.
- The interface is driven through tmux (`send-keys`, `capture-pane`), mouse
  and paste included, as `test/smoke.sh` does.
- Escape is sent alone and given a moment (`send-keys Escape`, `sleep
  0.2`): with a key right behind it the terminal reads Alt and that key.
- A step added to a long tmux session inherits what the steps before it
  left (a filter, a closed preview, a search): put it where the state is
  the one it needs, and leave the state as it found it.
- A session made with `-y 30` has 29 rows for the program: find a row by
  what is on it, never by number.
- Keys go to whatever has the cursor when they arrive: wait for the screen
  they are meant for (`shown ...`) before sending them.
- A message left by an earlier step satisfies a later `shown` of the same
  words: clear it (`Escape`) first.
- Name a private tmux server with `-L`; a socket path under a deep `mktemp`
  is too long. A test that starts a tmux server stops it in its EXIT trap,
  with `|| true`.
- Test scripts do not `rm` paths built from variables; plant and remove
  files from Lua with exact paths.
- Thread or memory work: `./configure --sanitize=address,undefined` and
  `--sanitize=thread` in a scratch copy, then the same targets
  (`ASAN_OPTIONS=use_sigaltstack=0`).

## calibre, as measured

Facts found by testing and in calibre's source, which the code relies on
(calibre 9.15):

- calibredb refuses the content server for catalog, add_custom_column,
  remove_custom_column, restore_database, check_library and
  backup_metadata (`no_remote`); direct access is refused while any
  calibre program has the library open. `check_library` vacuums the
  database first, and exits 0 whatever it finds.
- calibre's lock is an abstract unix socket per user, not a file:
  `@calibre-singleinstance-<uid>-db` (the program, calibre-server, calibredb
  opening a library directly) and `...-GUI` (the program). `/proc/net/unix`
  lists them; binding the name would take the lock.
- A book's metadata.opf is written only by calibre's own code: the
  program's background thread, `backup_metadata`, and removal, in the
  process that holds the lock and also renames book folders. calibre's code
  run in another process is a second writer outside that lock. A change
  through calibredb or the content server only marks the book in
  `metadata_dirtied`. A removed book's mark stays: count marks joined with
  `books`.
- A book's folder is `<author>/<title> (<id>)`; when a change renames it,
  the process making the change moves everything in the folder to the new
  path and removes the old one.
- A content server without `--enable-auth` is read-only unless started
  with `--enable-local-write`.
- A stopped server closes its port before it lets go of the library: wait
  for calibredb to be let in, not for the port.
- A date given without a time is read as local midnight; lulibre writes
  custom dates at noon UTC so that the day is the same everywhere.
- `set_metadata --field '#col:'` cannot empty a number or date column;
  `set_custom COL ID ''` can.

## Questions every change is held against

- Reentrancy, strictly: no hidden static state where a parameter would do;
  what a worker thread, a task or a callback may touch.
- Separation of concerns: does the code sit in the unit its job belongs to
  (the Lua API in its own translation units, the interface apart from the
  data)?
- Do the docs describe the program as it now is? Are the tests documented
  (what each suite covers, what it needs, why it may skip)?
- Can it be unified with something that exists, or simplified? Is anything
  left dead, or built but not exposed (no command, no key, no API)? Is an
  interface missing where code reaches into another's data?
- Every setup (above), and the combinations.
- Memory: leaks and ownership, checked with the sanitizers; the cost
  profiled rather than guessed.
- Configuration: a missing, malformed or old init.lua; options a script
  declares, added or changed in an update, or missing their values.
- Names: can a shipped script or module shadow, or be shadowed by, a
  standard or user module?
- The Lua API: gaps a script runs into; errors crossing between Lua and C
  in both directions, raised and reported with their cause.
- luv and libuv: handles closed before their memory goes, callbacks after
  their task or state is gone, the loop left with nothing pending at exit.
- Runtime dependencies: a feature names the programs it needs
  (`lulibre.features`), says so when one is missing, and offers to install
  it when allowed, so nothing is required up front. How friendly is setting
  lulibre up, from `./configure` to the first library?
