# Notes for an agent working on lulibre

Method, learned the hard way in the sessions that built this. The user
counts mistakes of process as bugs: a misunderstanding between agent and
user is a defect in the interface, to be fixed and recorded like one in the
code.

## What the library is for

The user's library is the motivation for the application, not the work.
Its problems show what the program cannot do yet (a title the program
cannot write, a value it cannot check, a step that takes a person too
long), and that is what gets built. Organizing the library is not the
goal of a session: do not run cleanups on it, do not report its state
item by item, and do not list library chores as work to do ("fix the
authors of book 400" is the user's, and ongoing). Fixing a class of
problem in the program is the work; say what the library showed only as
far as it explains the feature. Suggesting a way to do something with the
program as it stands is fine.

## Every setup is supported

The user runs calibre's content server and its web interface only, but
lulibre is not built for that setup alone. calibre's desktop program is
supported as fully: a design that works because nothing else writes the
library (or because the program is never open) is wrong. Before a feature
is done, ask what it does with the program running, with the server only,
with neither, and with the program running its own server; and whether it
touches anything the program also writes (metadata.db, the opf files, the
book folders, covers). What could compete with the program is watched while
it happens, not assumed away. Do not frame a finding by the user's setup
("redundancy in name only" was true of theirs, not of calibre's).

## Branches and versions

- **The user's tree, `/media/servd/staging/lulibre`, is theirs.** They run
  `./build/lulibre` from it, and a binary run from its tree reads its Lua
  files from the tree as it needs them: changing the files under it, by a
  checkout or a merge, breaks the program they have open (it did: "unknown
  option 'propose_over'" from a beta binary reading 0.2.0's files). All
  branch work happens in the second checkout,
  `/media/servd/staging/lulibre-0.2.0` (`git worktree list`). Their tree
  changes only by `git merge --no-ff` into the branch it is on, followed by
  `make` there, and only when they have asked for the feature or the
  update. The merge is gated, not merely preceded by a look (see the last
  note under Verifying):
  `if pgrep -x lulibre >/dev/null; then ...; elif [ -n "$(git status --short)" ]; then ...; else git merge --no-ff ... && make; fi`.
  They do switch that tree themselves:
  `git -C /media/servd/staging/lulibre branch --show-current` first.

- `v0.1.0` is the first release; the branch `0.1` is kept at it for patches.
- `main` is the 0.2.0 line, what the user runs. `0.2.0-dev` is where it is
  put together, in the second checkout: each feature is a branch
  `0.2.0-<name>` merged into `0.2.0-dev` with `--no-ff`, and `0.2.0-dev` is
  merged into `main` when a batch is whole and passes.
- Run `make check` and `make e2e` and read the result **before** the merge
  command, not in the same pipeline: a merge chained after a filtered test
  run went through with three failures in it.
- The version is written in `src/version.h` and nowhere else.
- Builds of a version are numbered by `make` (docs/development.md, Builds),
  each version as it is written in full having its own count: the first
  build of `0.2.0-alpha.0` is 001 whatever `0.2.0-dev` had reached. Tell the
  user the number of the build they are given: `lulibre -V`, or the last
  line of `make builds`.

### Moving to the next version

The user says when (bumping is their call, never a consequence of a batch
being finished). Then, on a branch in the second checkout:

1. `src/version.h`: the pre-release tag (`-alpha.0`, `-alpha.1`, `-beta.0`,
   `-rc.1`, `""` for a release), or the numbers. Nothing else holds the
   version: `./configure` reads it, and `make` runs configure again by
   itself when the header changes.
2. `CHANGELOG.md`: the section that was "in development" takes the version
   as its heading; a new "in development" section is opened above it only
   when work for the next one begins.
3. `man/lulibre.1`: the date and version in its `.TH` line.
4. `make check` and `make e2e`, read, then merged into `0.2.0-dev` and
   `main` like any other change. The build number starts again at 001 by
   itself.
5. In the user's tree, after the merge and `make`: an annotated tag,
   `git tag -a v0.2.0-alpha.0 -m "lulibre 0.2.0-alpha.0"`. Releases and
   pre-releases are both tagged; builds are not.
6. Tell the user the version and the build number, and record in the memory
   notes where the line stands.

After 0.2.0 is released, 0.2.1 is the patch line the user has set aside for
optimization, quality of life and bug fixes: features wait for 0.3.0.
- Work is committed on its feature branch as it is finished; what the user
  decides is when their tree changes. A fix goes with a test that fails
  without it.
- Record user-visible changes in `CHANGELOG.md`, and bring the docs to the
  change in the same branch, before it is merged: a feature is not done
  while its docs describe the one before it.

## What counts as a bug

- Anything the user was surprised by, including a limitation that was
  chosen on purpose. "Removals cannot be undone" and "release builds carry
  no symbols" were both deliberate and both wrong. When choosing the more
  restrictive of two behaviours, say so at the time and ask.
- A claim that turned out narrower than it sounded. Say what was verified
  and how: "tested with synthetic mouse events in tmux, not with a pointer in
  ghostty" is a result; "mouse works" is not.

## Before believing a report is a code bug

- Read the user's `~/.config/lulibre/init.lua` first (read, never edit: it
  is theirs; defaults belong in the repo, in what `lulibre config` emits). A
  password file "looked for in the wrong place" was a line in it.
- For a crash, read `coredumpctl info` and `~/.local/state/lulibre/crash.log`
  before reasoning from the source. The one unreproducible segfault was
  identified from its stack in a minute.

## Never touch

- The user's calibre library. Every write path is tested against a
  throwaway library inside `unshare -rn` (`make check-offline`,
  `make check-write`), because calibre refuses direct access to any library
  while one of its servers runs on the machine.
- The user's tmux buffers and clipboard. Anything that copies is tested
  only inside the private tmux server the tests start (`tmux -L ...`).
- The user's index: do not leave marks, proposals or settings behind when
  driving the real library for a look.

## Code rules that are easy to break

- Two threads own state when the interface is up, the interface's and
  Lua's. A `lulibre.x` that touches the interface, the options or the
  command and key tables runs through `ui_call` (`ON_UI` in
  `src/lua/l_ui.c`); interface code never touches the Lua state, it sends a
  message with `bridge_lua`. Besides them, worker threads run
  `uv_queue_work` jobs (indexing, hashing, extracting, copying a database):
  a job touches only what it was handed and what it opens itself, and its
  answer is delivered in the after-callback, on the loop that queued it.
- Lua at the prelude's top level runs before `-L` and `init.lua` are
  applied. Anything there that opens the index (`lulibre.store`, `sql`)
  ends lulibre with "no library" in every run without one, the test
  probes included: put it in a task (`lulibre.spawn`), and check there.
- Lua tasks are preempted between any two operations (a count hook, once a
  4 ms slice is spent). Shared counters lose counts; use `lulibre.each`,
  `table.insert`, `table.remove`. A test followed by a set is two steps:
  `while busy[s] do sleep end busy[s] = true` let all 8 tasks of a test in
  at once; take it with `lulibre.claim(t, key)`, one C call. Build a table
  that tasks share in a local and put it in place with one assignment, never
  fill it where they can see it. A test of any of this holds what it tests
  for longer than a slice, or it passes without the fix.
- luv belongs to the main Lua state. It is loaded once at startup; never
  arrange for a task's coroutine to be the state a C library keeps.
- A panel reserves `g` (for `gg`), `j`, `k`, `G`, `q`, `Esc`, `Tab`, `:`.
- A screen written in Lua never compares a key with a letter. It asks its
  key table (`lua/lulibre/ui/keys.lua`) which action the key means, and its
  hint and `?` help are written from that table. A new action goes into the
  table with a label and a description.
- C code for a place with keys of its own (a panel's movement, the line
  editor, picker, pager, console) never compares a key with a constant
  either: it asks `ctx_feed(KC_..., &pending, key)` for the action
  (`src/tui/ctxkeys.c`; the enums in `tui.h` follow the tables there).
- Nothing shown to the user names a key literally: C uses `key_hint("the
  command")` or `ctx_hint(place, action)`, Lua `lulibre.hint("the command")`, a screen `keys:key(action)`.
  The user rebinds keys and expects what is on screen to say so.
- A command acts on what the *focused* cursor shows. With a panel that
  follows the list focused, that is the panel row's book, not the list's
  cursor: once the two can differ (the book was removed, or filtered out)
  the list's cursor is on a neighbour. `lulibre.selection()` settles this;
  do not read the list's cursor directly for an action.
- Closing a window frees its node *and its sibling's* (the sibling's
  contents move up into the parent). Never keep a `struct node *` across a
  close; `wm_close_leaf` closes a given window and keeps `t->focus` valid.
  A view's state pointer kept elsewhere (`t->drag`) is checked against the
  windows, class included, before every use.
- Whatever takes over the bottom line or the keyboard (`tui_prompt`,
  `picker_open`) first answers a question still open as cancelled. A script
  waiting on an answer nobody can give any more waits for ever.
- Lua code must run on 5.4 and 5.5: never assign to a `for` variable.
- `src/core/log.h` includes the generated `<config.h>` with angle brackets,
  because `src/core/config.h` is the options header.

## Verifying

- Anything that writes lulibre's own tables in bulk (`:learn`, confirming
  records) is tried on a **copy** of the user's index, never the index
  itself, taken as the next note says, and run with `-o index=scratch.db`.
  The library is still read, nothing of the user's is written.
- When the user may have lulibre open, a plain `cp` of the index can give
  "database disk image is malformed": take the copy with
  `sqlite3 'file:NAME.db?mode=ro' ".backup scratch.db"`, and remove any
  `scratch.db-wal` / `-shm` left beside an earlier copy of that name first
  (an old one is replayed into the new file).
- Anything that deletes "what belongs to X" (a run's proposals, a group's
  books) is counted on a copy before and after, by status: the numbers
  outside X must come back exactly. Dropping a run first took 137
  proposals, 44 of them accepted, that had waited for its books from
  before; only the count showed it.
- A matching rule is measured before it is believed, against every case
  there is: the title search took "An Introduction to Module Theory" for
  "An introduction to the ipaddress module", and of 79 matches it had made
  in the user's library 62 were wrong, 29 of them already written. A search
  always returns something; "two words in three" is not a test. List what
  the rule accepts on a copy, read the list, and count.
- "The library holds it" is not evidence. An identifier in the library may
  have been proposed by this program from a reference list and accepted in
  a batch; believing its record outright closes the loop on the program's
  own mistake. Whatever a value rests on is checked against something
  independent (the file's text, the book's other fields) each time.
- After a matching rule changes, run it over the whole library on a copy
  starting from no waiting proposals, and read two lists: everything it
  now refuses, and everything it would still put over a value a book has.
  Both lists were short enough to read (33 and 60), and each showed a
  class the rule had missed (chapters holding their volume's ISBN; a
  catalogue's first author alone).
- A confidence says how sure *this* value is, not how good its source is in
  general: a record reached through a guess (a title search) carries the
  guess's confidence on every field, identifiers included, never the
  service's 0.95.
- Putting existing commands end to end makes a new thing out of them: read
  what each one says when it finishes. `:propose` closing with "gr goes
  through them" was right alone and wrong as step one of three, where it
  sent the user into review while the other two were still working.
- The proposer is measured on a **bare copy**: links to the library's book
  folders, a `metadata.db` stripped to "Untitled / Unknown" (triggers
  dropped, written by hand with sqlite, **never through calibredb**: it
  renames book folders, and here they are links to the real ones), a copy of
  the index for the pages. Propose, then compare with the real records by
  field and confidence. The first run showed titles at 0.9 right a third of
  the time: one reader misreading a newer form of a page. The scripts are
  kept in the session's scratch folder (`bare/compare.py`, `apply.py`,
  `phase2.lua`); rebuild them from this note if they are gone.
- A learned or statistical feature is reported with a held-out number, and
  the number goes in the report as measured. The first phrase learner looked
  finished and was teaching "delaware corporation" as a mark of computing.
- A word list that removes "noise" removes signal too: the first trade-word
  list dropped "number", "series", "law" and "distribution", and with them
  number field, power series, reciprocity law. Test such a list against the
  phrases that must survive it.
- Lua 5.5 will not load a file that assigns to a `for` loop's own variable
  (`for line in ... do line = trim(line)`). It was written four times in
  two days. The unit tests now compile every Lua file, so `make unit`
  catches it; name the changed value something else (`local text = ...`).
- Lua patterns work on bytes. A character outside ASCII is several of them,
  so `©?` asks for the first byte and makes the second optional, and a set
  like `[çc]` or `[‘’–]` matches single bytes of those characters. This went
  wrong three times in one day (a copyright sign, "Reçu", the quotes and
  dashes in `propose.same`). Write the bytes (`\194?\169?`), list the
  spellings separately, or replace whole sequences through a table; and give
  every such pattern a test with and without the character.
- A file somebody else made is opened before code is written for it. The
  reader for "arXiv's snapshot" was written from the format of the dataset
  I expected; the file that arrived was another dataset (a hypergraph, no
  author order, no DOI). Saying "not verified against the real file" was
  what kept that from being a surprise.
- Code that talks to somebody else's service is written from that service's
  own terms, read first and linked in a comment, not from memory of what is
  usual. The first arXiv code kept to a pace but retried after "rate
  exceeded" and, when a batch failed, asked for each paper singly: forty
  requests to a service that had just asked for fewer. The rules now
  (`lua/lulibre/net.lua`): one request at a time, no retry after 429/503 but
  a pause that outlives the run, never a fallback that multiplies requests,
  and an empty or broken answer is not remembered as "no such record".
- A parser for a service's answers is checked against a real answer before
  it is called done, and that answer (cut down) becomes the test. One
  request is enough; if the service refuses it, say so and stop.

- `make check` and `make e2e` before every merge (above). Read the e2e log
  for `skipping` as well as `FAIL`: offline, write and forms skip
  themselves when their tools are missing, and a probe that took any
  failure for "luv is not installed" let a broken build pass with three
  suites unrun. A skip must be for its stated reason only.
- A change to a form (edit, review, duplicates, orphans) gets a keystroke
  check in `test/forms.sh`. The configuration window's check counts rows
  down to `pages` (`k j j ...`): an option added above it moves it.
- In a test, Escape is sent alone and given a moment (`send-keys Escape`,
  `sleep 0.2`): with a key right behind it the terminal reads Alt and that
  key, and the program never sees an Escape.
- A step added to a long tmux session inherits what the steps before it
  left: a filter, a closed preview, a search. Put it where the state is the
  one it needs, and leave the state as it found it.
- A tmux session made with `-y 30` has 29 rows for the program (tmux keeps
  one for its status line): find a row by what is on it, never by number.
- Keys go to whatever has the cursor when they arrive, not to what had it
  when the test was written: `g r` sent after a review has already opened
  rejects a proposal, and `q` sent after it has closed quits the program.
  Wait for the screen the keys are meant for (`shown ...`) before sending.
- A message left on the message line by an earlier step satisfies a later
  `shown "changed 1 book"`. Clear it (`Escape`) before a step that waits for
  the same words, or the check passes before the work is done.
- A long tmux socket path fails ("File name too long"): name the private
  server with `-L`, do not move its socket directory under a deep `mktemp`.
- Thread or memory work: `./configure --sanitize=address,undefined` and
  `--sanitize=thread` in a scratch copy, then the same targets
  (`ASAN_OPTIONS=use_sigaltstack=0`).
- The interface is driven through tmux (`send-keys`, `capture-pane`), mouse
  and paste included, as `test/smoke.sh` does.
- The shell here is zsh: unquoted variables do not split into words, and a
  here-document ends at the first line equal to its delimiter, even inside
  a quoted block of another language.
- A test that starts a tmux server stops it in its EXIT trap, with
  `|| true`. Failed runs of the smoke test left six lulibre processes
  running for two days.
- Test scripts do not `rm` paths built from variables; plant and remove
  files from Lua with exact paths.
- A change to the user's real library (calibredb through their server) may
  be refused by the session's permission checks even when the user asked
  for it. Do not route around that: run the same command against a copy of
  the index first (`-o index=COPY`), show the dry run, and give the user the
  one command to run themselves.
- Something a heuristic "repairs" in bulk (text re-read, letters shifted
  back, titles restored) is checked on the whole library copy and the
  changed items read one by one before it is trusted: three passes of
  `reread` and four of `recheck` each turned up a class of false fixes
  (TOC leaders taken for garbage, a "shift" found in symbols, junk titles
  restored) that the unit cases had not.
- Lua C modules found on the default `cpath` may be built for another Lua:
  `/usr/local/include/lua.h` here is a 5.4-era header that GCC finds before
  `/usr/include` (and `-I/usr/include` is ignored, being a system
  directory), so a module compiled for 5.5 without an explicit include path
  gets 5.4's `LUA_REGISTRYINDEX` and crashes in `luaopen_*`. The user's
  `~/.luarocks/lib/lua/5.5/lpeg.so` is such a build. Build test modules with
  `-I/usr/local/include/lua/5.5`. I first blamed LPeg for "not supporting
  5.5" after one crash: when a widely used library seems broken, check the
  build environment (headers, ABI, which library is linked) before the
  library, and say what was checked before naming a cause.
- Those headers were Pallene's patched Lua 5.4.7, installed by its `make
  install` (the user has since uninstalled it).
- The merge into the user's tree is gated on lulibre not running, but I
  wrote the check as `pgrep -a lulibre; test -z "$(git status --short)" &&
  git merge ...`: pgrep printed the running process and the merge went on
  anyway. It was harmless that time (the process was /usr/local/bin/lulibre,
  not build/lulibre), but a check that only prints is no check. Gate on it:
  `! pgrep -x lulibre >/dev/null && test -z "$(git status --short)" && git
  merge ...`, and stop and say so when it fails.

## calibre, as measured

Facts found by testing, which the code relies on (calibre 9.15):

- calibredb refuses the content server for catalog, add_custom_column,
  remove_custom_column, restore_database, check_library and
  backup_metadata (`no_remote`); direct access is refused while any
  calibre program has the library open. `check_library` is not read-only:
  it vacuums the database first, and it exits 0 whatever it finds.
- calibre's lock is an abstract unix socket per user, not a file:
  `@calibre-singleinstance-<uid>-db` (the program, calibre-server, calibredb
  opening a library directly) and `...-GUI` (the program). `/proc/net/unix`
  shows them; binding the name would take the lock.
- A book's metadata.opf is written by calibre's own code only (the
  program's background thread, `backup_metadata`, removal). A change
  through calibredb or the content server marks the book in
  `metadata_dirtied`; `backup_metadata` writes them. A removed book's mark
  stays behind: count marks joined with `books`.
- A content server without `--enable-auth` is read-only unless started
  with `--enable-local-write`; a test against one that is not proves
  nothing about writing.
- A stopped server closes its port before it lets go of the library: wait
  for calibredb to be let in, not for the port.
- A date given to calibre without a time is read as local midnight;
  lulibre writes custom dates at noon UTC so that the day is the same
  everywhere.
- `set_metadata --field '#col:'` cannot empty a number or date column;
  `set_custom COL ID ''` can.

## Reporting

- Answer what was asked. Merge, build and branch status are the agent's
  bookkeeping: mention them when the user asked for that change, or must
  act on it.
- Test a concern before raising it, and never put a basic requirement to
  the user as a choice ("search must work over titles" was not a question).
- Check a fact about another program before stating it (`check_library`
  was first called read-only).

## Questions every change is held against

The user's standing review questions. Ask them of new code, and of old code
a change touches:

- Reentrancy, strictly: no hidden static state where a parameter would do;
  what a worker thread, a task or a callback may touch (above).
- Separation of concerns: does the code sit in the unit its job belongs
  to (the Lua API in its own translation units, the interface apart from
  the data)?
- Do the docs describe the program as it now is? Are the tests documented
  (what each suite covers, what it needs, why it may skip)?
- Can it be unified with something that exists, or simplified? Is
  anything left dead, or built but not exposed (no command, no key, no
  API)? Is an interface missing where code reaches into another's data?
- Every setup (above): no content server at all (writes straight to the
  folder); the desktop program in use (its lock, its own opf writing); the
  content server only; and the combinations.
- Memory: leaks and ownership, checked with the sanitizers, and the cost
  profiled rather than guessed.
- Configuration: a missing, malformed or old init.lua; options a script
  declares, added or changed in an update, or missing their values.
- Names: can a shipped script or module shadow, or be shadowed by, a
  standard or user module (`math.lua` would have)?
- The Lua API: gaps a script runs into; errors crossing between Lua and C
  in both directions, raised and reported with their cause.
- luv and libuv: handles closed before their memory goes, callbacks after
  their task or state is gone, the loop left with nothing pending at exit.
- Missing runtime dependencies: a feature names the programs it needs
  (`lulibre.features`), says so when one is missing, and offers to
  install it (pixi, a rock) when allowed, so nothing is required up front.
  How friendly is setting lulibre up, from `./configure` to the first
  library?

