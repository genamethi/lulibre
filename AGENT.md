# Notes for an agent working on lulibre

Method, learned the hard way in the sessions that built this. The user
counts mistakes of process as bugs: a misunderstanding between agent and
user is a defect in the interface, to be fixed and recorded like one in the
code.

## Branches and versions

- **The tree at `/media/servd/staging/lulibre` stays on `main`, always.**
  The user runs `./build/lulibre` from it, and a binary run from its tree
  reads its Lua files from the tree as it needs them: checking out another
  branch there, even for a minute, breaks the program they have open (it did:
  "unknown option 'propose_over'" from a beta binary reading 0.2.0's files).
  All branch work, fixes for `main` included, happens in the second checkout,
  `/media/servd/staging/lulibre-0.2.0` (`git worktree list`). A fix reaches
  `main` by `git merge --no-ff` run in the main tree, followed by `make`
  there; nothing else changes that tree.

- `main` is the released line. Bug fixes go to it through `fix-<name>`
  branches, merged with `--no-ff`.
- `0.2.0` is the next minor. Each feature is a branch `0.2.0-<name>` merged
  into `0.2.0` with `--no-ff`. After fixes land on `main`, merge `main` into
  `0.2.0` so it stays current; `src/version.h` conflicts there, keep 0.2.0's.
- The version is written in `src/version.h` and nowhere else. Bump the
  pre-release tag there (`-alpha.2`, `-beta`, `-rc.1`, `""`).
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

- `make check` always; `make e2e` before a merge that touches writing.
  A change to a form (edit, review, duplicates, orphans) gets a keystroke
  check in `test/forms.sh`.
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
- Test scripts do not `rm` paths built from variables; plant and remove
  files from Lua with exact paths.
