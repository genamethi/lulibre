# Changelog

Versions follow [semantic versioning](https://semver.org). The version is
written in `src/version.h`.

## 0.2.0 (in development, branch `0.2.0`)

Added
- Thesis and dissertation cover pages are read by rule (title above "by",
  author after it, degree, program, institution, year, advisor), following
  Choudhury et al., JCDL 2020. It needs no font information, so it also works
  on pages read by OCR.
- `D` (`:sync drop`) takes staged files out of the sync folder without adding
  them; they are kept aside and `u` puts them back.
- With a sync folder set, a tab line shows `1 Library` and `2 Sync folder`
  with their counts and which one the list is showing; `1`, `2` or a click
  switch, and the keys that act on staged files are shown beside it.
- The command line completes: command names, option names and their values
  for `:set`, scripts for `:run`, the arguments of other commands, and the
  filter language at `&` and `/`. `Tab` takes the highlighted completion,
  `<C-n>` `<C-p>` move through them.
- History for the command, filter and search lines, kept between sessions.
  `Up` and `Down` recall entries that start with what has been typed.
- `lulibre.index{filter=, force=}` runs the indexer from a script and waits
  for it.
- Every panel's keys can be changed: `lulibre.map("review", "y", "accept")`.
  The title bar shows a panel's main keys and `?` lists them all, both
  written from the keys in force.
- `c` clears a field in the edit form and in review. In the edit form `x`,
  which dropped the pending change, is now called revert.
- `<Leader>` in key bindings, set by the option `leader` (default `\`).
- `:reload-cfg` (`<Leader>R`) reads `init.lua` again.
- Hints and messages name keys as they are bound now, not as they were
  shipped. `lulibre.key`, `lulibre.hint` and `lulibre.maps` give scripts the
  same.

- Title case, after the APA manual. `gT` (`:titlecase`) rewrites the
  selected titles that are in CAPITALS; `t` does it for a field in the edit
  form and in review; titles proposed from files and `.bib` records arrive
  in title case when they were found in capitals (option `title_case`).
  `is:capstitle` filters for titles in capitals. For scripts:
  `lulibre.titlecase`, and `lulibre.lower` / `lulibre.upper`, which know
  accented, Greek and Cyrillic letters.
- The mouse selects text everywhere, not only in the preview: a drag in the
  list, a panel, the line being typed, the status line or an overlay copies
  what it covers; a double click the word; a triple click the row, or in a
  panel the whole cell including what its column cut off. `<C-y>` copies
  the line being typed.
- Review lists the books surest first: the one whose best proposal has the
  highest confidence at the top, with how many proposals wait for each. `s`
  switches to id order; the option `review_sort` sets the default.
- Review, duplicates and orphans refresh when the library changes under
  them (`reloads = true` gives a script's panel the same, as `"<Reload>"`).
  Proposals for a book that has been removed are no longer listed or counted.
- From duplicates and orphans, `e` opens the edit form for the row's book
  and `r` the review of its proposals; the panel steps aside meanwhile and
  comes back up to date. `:review FILTER` reviews only the matching books.
- With the cursor in review, duplicates, orphans or capture, the preview's
  keys work (`P`, `]`, `[`, `J`, `K`), as do the copying keys and the
  console's. `p` shrinks the panel to give the preview room.
- A following panel shows its row's book in the preview even when the
  list's filter leaves that book out.
- Panels for scripts: `keys` and `pass`, `p:hide()`, `p:show()`,
  `p:height()`; `lulibre.ui.edit` and `lulibre.ui.review` take `{ ids = }`.

Changed
- After duplicates or orphan records are removed, the message says plainly
  what was kept from them and where it went.

## 0.1.0-beta

Fixed, from testing the alpha
- A field can be blanked: empty it and press `Enter`. Backspace in an
  emptied field no longer cancels it, review accepts an empty answer, and
  both forms show `(blank)` where a value is about to be removed.
- A command typed with the cursor in review, duplicates or orphans acts on
  the book that row shows. `:remove`, repeated on a row whose book had just
  been removed, took the list's next book instead; it is now refused.
- Orphans: the verdict no longer runs off the right edge. The column holds
  a short wording; `x` opens a row (`X` all rows) to show the full verdict,
  the whole path and where a link points.
- A filter in force is labelled in the status line, with how much of the
  library it leaves and how to clear it:
  `filter id:526   1 of 1999   <BS> shows all`.
- Panels follow files staged from the sync folder too.

Fixed, from a review of pointer lifetimes and leaks
- A use-after-free: closing the console (`` ` ``) while only one other
  window was open left the focus pointing at a freed window.
- A panel made the only window (`:only`) could not be closed; the list now
  takes its place.
- A script waiting on a question (`lulibre.input`) waited for ever when
  another prompt or a picker took over the bottom line; it is answered as
  cancelled.
- A mouse drag is dropped when its preview window closes, and its target is
  checked to be a preview before use.
- Messages still on their way to the Lua thread at exit are run, not
  dropped, so what they carry is freed.
- The indexer's progress report no longer keeps pointers into a finished
  job; `lulibre.extract` no longer leaks when called outside a task.

Tests
- `test/forms.sh` (`make check-forms`, part of `make e2e`): the edit form,
  review, removal and orphans, by keystroke, against a throwaway library.

## 0.1.0-alpha.2

Fixed
- A crash on the Lua thread, seen while writing: luv ran its callbacks on
  the coroutine of whichever task first loaded it, which could be gone.
- Removed books can be brought back with `u` (from calibre's recycle bin).
- A cover sheet that labels its fields ("Author(s): ...", as JSTOR's do) is
  trusted: 0.95 instead of 0.55.
- The preview opens at the first page that has text, and where a page shows
  none it says why (blank page, past the indexed pages, a scan needing OCR).
- A missing password file is reported as such before anything is written.
- Text pasted by the terminal is text: a line break in it no longer submits
  a field, and a paste outside a field no longer runs as keystrokes.
- Tests skip what needs the luv rock when it is not installed (Lua 5.4).

Added
- A crash log with a backtrace, `~/.local/state/lulibre/crash.log`; release
  builds keep their symbols.
- `lulibre.settings` (get, set, reset, names, info, paths); the option
  `config_dir`, `lulibre -C DIR`, `$LULIBRE_CONFIG_DIR`.
- Mouse: drag in the text preview to select and copy, double click a word,
  triple click a line; `<C-v>`, middle or right click paste into a field.

## 0.1.0-alpha

First version.
