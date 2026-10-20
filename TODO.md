# Planned

Changes planned for a version, larger than a single fix. Each comes out of
this file when it is done (the CHANGELOG says what was).

## 0.2.1: dependencies, declared and installed

Today a feature names the programs it needs (`lulibre.features`), says
when one is missing, and can offer pixi (`pixi_deps`) or a rock
(`rocks_install`). Nothing declares them as a whole, and nothing installs
lulibre's own set.

- **A rockspec** (or a manifest) for the Lua side: `luv` (needed), `lpeg`
  (grammars). Installed with `luarocks --local` by default, the user's own
  tree.
- **A `pixi.toml`**, optional throughout and never used to build lulibre:
  features and environments for the optional programs (conda-forge has
  poppler, tesseract, ocrmypdf, djvulibre, and lua 5.5 with luarocks 3.13),
  tasks for fetching datasets. pixi may also manage luarocks, the most
  reproducible setup, and the docs say so; then "local" means pixi's
  environment, not `~/.luarocks`. luarocks never depends on pixi.
- **The installer** asks: luarocks (the default), pixi, or by hand; asks
  before anything that needs sudo (calibre, notcurses and other system
  packages), and says what it would run.

## 0.3.0: the API, what is C and what is Lua; yours apart from lulibre's

Much of lulibre's API is written in Lua (the prelude, `lua/lulibre/`),
which makes it easy to change and to replace; the rest is C (`src/lua/l_*.c`).
Nothing decided which belongs where.

- **What should be C, or a C module.** Go through the API: what is slow in
  Lua (profile it first: board item 11), what must not be replaced (the
  write path, the journal), what C already half does. Options for each
  part: C in the binary, a C module loaded with `require`, or Pallene
  (typed Lua compiled to C), if the maintainer's port of it to 5.5 gets
  there.
  The answer decides how much of lulibre a user can still replace.
- **Your files apart from lulibre's.** Today a file of yours named like one
  of lulibre's replaces it whole (`~/.config/lulibre/lua/`, `scripts/`), and
  `lulibre.overrides` warns of it. Better: say what is meant to be
  replaced (replaceable functions, hooks: board items 8 and 14) and keep
  your modules in a namespace of their own, so a name of yours can't
  replace one of lulibre's by accident; and a replaced file that knows
  which version of lulibre's it was made from.

## 0.3.0: settings, one registry, named by module

Today the core options are one flat list in C (`lulibre.settings`,
`lulibre.o`), and a script's options live under a namespace of its own
(`lulibre.option(ns, …)`, `lulibre.cfg.ns.name`). One registry instead,
where every setting is named by the module it belongs to (`review.sort`,
`verify.shown`, `enrich.batch`), the same whether that module is C,
lulibre's Lua, or a plugin. On it:

- **Registered but not in init.lua**, worked out in one place, and used by
  two actions in the configuration window: put those settings in init.lua
  with their defaults; put every setting back to its default. Nothing asks
  at the start of a session (the `config_add_*` prompt goes). To weigh:
  writing a default into init.lua fixes it there, so a later change of
  lulibre's default no longer reaches that user; commented-out lines
  avoided that.
- verify's thresholds (`SHOWN`, `FRONT`, `MIN_CHARS` …) become settings
  rather than fields of the module; board items 21 and 22 are the same
  question for the rest of the API.

## 0.3.0: every message a user sees, in one place

About 480 places in the C and the Lua show the user something
(`lulibre.notify` 140, `error` 168, `print` 68, `tui_msg` 49, `confirm` 25,
`show` 22, `pick` 7), each with its own wording. Register them, so that
they can be read as one table, reviewed for what they actually tell the
person reading them, and translated (a "language API", to be designed with
the settings above). First an inventory; then the rules the review holds
them to (name the thing, no "it" or "them" pointing back; a key given as
an instruction, "press gr to review"; numbers only where they mean
something to the reader).

## 0.3.0: a scratch pad, and reading a book in Neovim

- **A scratch pad** in lulibre: text kept across sessions, to collect
  what is copied from books while editing records.
- **A Neovim helper** (a Lua plugin, launched from lulibre): a book's
  text as the index holds it, page by page, scrolled a page at a time or
  continuously, with a key to read more pages (the next, a range, all)
  into the index and the buffer as it goes; and a buffer shared with
  lulibre's scratch pad, so what is copied in one is there in the other.

## To decide, not yet placed in a version

- **The library as links.** A second tree of the books, as symbolic links
  on the same filesystem, laid out by a template
  (`~/library/<subject>/<author>/<title> - <year>.<ext>`) and made again
  from the mirror when the library changes. One way only: the links point
  into calibre's folder, nothing in calibre's folder points out, and
  nothing in it is renamed or moved.

- **SPDX lines.** The license is settled (LICENSE: Apache-2.0 WITH
  LLVM-exception). Whether each source file also carries an
  `SPDX-License-Identifier` line is still to decide.
- **The docs website.** Read the Docs, built with Zensical from `docs/`
  (`zensical.toml`, `.readthedocs.yaml`), is live and kept up. Zensical
  suits the guides; to try for the API reference: LDoc (MIT), which needs
  its tags (`@param`, `@return`, `@module`) in the doc comments. The two
  compared side by side first (lulibre-dev-support), then perhaps both, the
  API pages under the guides. GitHub Pages remains the alternative host.
- **A testing framework.** The suites are shell scripts and one Lua file of
  checks; whether to move to a framework (busted, say, for the Lua side)
  is put off for now.

## 0.3.0: the library checked against its folders

calibre's `check_library`, done by lulibre: it is only the folders compared
with the database (about 260 lines of calibre's Python), so lulibre can do
it from the mirror and the folder while the server runs, with nothing
stopped and the database not vacuumed. A report page first, summing each
kind up in a line; acting on a kind where it fits what lulibre already does.

- Already covered by `:orphans`: records whose file is gone, files no
  record knows, stray folders; and more than calibre checks (broken links,
  empty folders).
- To add: folders not named as calibre names them (`Title (id)` under an
  author), a folder whose case differs from its record's path, a format
  whose file name's case differs, covers the database claims and the
  folder lacks or the reverse (`has_cover` is to be mirrored), files of
  unknown kinds in a book's folder, folders that cannot be read.
- Acting: what is lulibre's already (`:orphans` verdicts); the rest
  reported only until a feature fits it. Fixes calibre's own check offers
  (dropping a missing format from the record, the cover flag) go through
  calibredb like any change.

## 0.3.0: catalogues, and lulibre as a reference manager

- **A catalogue API** over calibredb's `catalog` (CSV, XML, BibTeX, EPUB,
  AZW3, MOBI): the books chosen by a filter or the selection, the fields,
  the format's own options, written where asked. It needs the server
  stopped, so it goes through `lulibre.offline`, or a copy of the library's
  database where the format allows.
- Toward working with reference managers, or being one: the BibTeX
  writer (`:bib`) and catalogues as one export path; citation keys kept
  stable; importing back what a reference manager changed.
