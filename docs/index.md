# lulibre

A fast, modal terminal workbench for the metadata of a
[calibre](https://calibre-ebook.com) library: a full-text index over the
first pages of every book, a filter language, batch editing with undo, and
Lua scripting. C, notcurses, libuv.

**Alpha.** It works and is tested, but it is young: try changes on a few
books before a few hundred. Every change is journaled and `u` undoes it,
removals included.

Installing and a first look: the
[README](https://github.com/genamethi/lulibre#readme). What changed in each
version: the
[changelog](https://github.com/genamethi/lulibre/blob/main/CHANGELOG.md).

- [Workflows](workflows.md) — editing, review, capture, duplicates, orphans,
  the sync folder, BibTeX, OCR, copies of calibre's database
- [Filters](filters.md) — the query language
- [Keys and commands](keys.md)
- [Configuration](configuration.md) — options, colours, key maps
- [Lua API](api.md)
- [Development](development.md) — builds, tests, source layout, releasing
