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
- **check_library, read.** Run it while the server is stopped, read its CSV
  (it exits 0 whatever it finds), and hand each kind of finding to what
  can act on it: files with no record and records with no file to
  `:orphans`, extra formats to adding them to their book, missing covers.

## 0.3.0: catalogues, and lulibre as a reference manager

- **A catalogue API** over calibredb's `catalog` (CSV, XML, BibTeX, EPUB,
  AZW3, MOBI): the books chosen by a filter or the selection, the fields,
  the format's own options, written where asked. It needs the server
  stopped, so it goes through `lulibre.offline`, or a copy of the library's
  database where the format allows.
- Toward working with reference managers, or being one: the BibTeX
  writer (`:bib`) and catalogues as one export path; citation keys kept
  stable; importing back what a reference manager changed.
