# Planned

Changes planned for a version, larger than a single fix. Each comes out of
this file when it is done (the CHANGELOG says what was).

## 0.2.0: the database's integrity, backups, restoring

Copies of calibre's database are made (`lulibre.backup`, `:backup`). Still
to come:

- **Restoring a copy.** Put one of lulibre's copies of `metadata.db` back,
  with the content server stopped (through `lulibre.offline`, like adding
  a column), after a copy of the database as it is now. Say what the copy
  differs in first: books, and fields, from the journal and the mirror.
- **Integrity.** `PRAGMA integrity_check` of `metadata.db` (read-only, the
  server may run), when a copy is made and when asked; a failure is the
  signal to restore. Then the choice: one of lulibre's copies, or calibre's
  `restore_database` from the books' metadata.opf files (as good as those
  files are: they are written only by calibre's own program or
  `backup_metadata`).
- **The opf files, and calibre's program beside lulibre** (high priority).
  Every setup is supported: calibre's program open (it writes the opf files
  itself, a dirty book every ~2 s), the content server alone (nothing writes
  them), neither. lulibre keeps them current where calibre does not, never
  in competition with the program: whatever lulibre does that the program
  could also be doing (writing opf files, moving files in book folders, a
  direct calibredb run) starts a watcher for the program
  (`@calibre-singleinstance-<uid>-GUI` in `/proc/net/unix`, the book folder
  by inotify) and stops when it appears. How the files are written (calibre's
  `backup_metadata` while stopped, or calibre's own writer over a read-only
  copy of the database) is still to be decided.

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
