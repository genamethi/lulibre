# Notes for an agent working on lulibre

Method, learned the hard way in the sessions that built this. The user
counts mistakes of process as bugs: a misunderstanding between agent and
user is a defect in the interface, to be fixed and recorded like one in the
code.

## Branches and versions

- **The user's tree, `/media/servd/staging/lulibre`, is theirs.** They run
  `./build/lulibre` from it, and a binary run from its tree reads its Lua
  files from the tree as it needs them: changing the files under it, by a
  checkout or a merge, breaks the program they have open (it did: "unknown
  option 'propose_over'" from a beta binary reading 0.2.0's files). All
  branch work happens in the second checkout,
  `/media/servd/staging/lulibre-0.2.0` (`git worktree list`). Their tree
  changes only by `git merge --no-ff` into the branch it is on, followed by
  `make` there, and only when they have said they are not running it or
  have asked for the update. Before any merge:
  `git -C /media/servd/staging/lulibre branch --show-current`, and
  `pgrep -a lulibre`. They do switch that tree themselves.

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
- Commit only when asked. A fix goes with a test that fails without it.
- Record user-visible changes in `CHANGELOG.md`.

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

- Two threads when the interface is up. A `lulibre.x` that touches the
  interface, the options or the command and key tables runs through
  `ui_call` (`ON_UI` in `src/lua/l_ui.c`); interface code never touches the
  Lua state, it sends a message with `bridge_lua`.
- Lua tasks are preempted between any two operations. Shared counters lose
  counts; use `lulibre.each`, `table.insert`, `table.remove`.
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
  itself: `cp ~/.local/share/lulibre/NAME.db scratch.db` and run with
  `-o index=scratch.db`. The library is still read, nothing of the user's
  is written.
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

- `make check` always; `make e2e` before a merge that touches writing.
  A change to a form (edit, review, duplicates, orphans) gets a keystroke
  check in `test/forms.sh`.
- In a test, Escape is sent alone and given a moment (`send-keys Escape`,
  `sleep 0.2`): with a key right behind it the terminal reads Alt and that
  key, and the program never sees an Escape.
- A step added to a long tmux session inherits what the steps before it
  left: a filter, a closed preview, a search. Put it where the state is the
  one it needs, and leave the state as it found it.
- A tmux session made with `-y 30` has 29 rows for the program (tmux keeps
  one for its status line): find a row by what is on it, never by number.
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
