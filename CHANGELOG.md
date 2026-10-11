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
