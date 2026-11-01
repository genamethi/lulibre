# lulibre

lulibre is a fast, modal terminal program for fixing the metadata of a
[calibre](https://calibre-ebook.com) library. It has a full-text index of
the first pages of every book, a filter language, batch editing with undo,
and Lua scripting. It is written in C with notcurses and libuv.

**Beta.** lulibre works and is tested, but it is young, so try a change on
a few books before a few hundred. The journal records every change, and
`u` undoes it, including removals.

The [README](https://github.com/genamethi/lulibre#readme) covers installing
and a first look. The
[changelog](https://github.com/genamethi/lulibre/blob/main/CHANGELOG.md)
lists what changed in each version.

- [Workflows](workflows.md) — reading the files and OCR, editing,
  proposals and review, online lookups, how changes reach calibre
- [Filters](filters.md) — the query language
- [Keys and commands](keys.md)
- [Configuration](configuration.md) — settings, colours, key maps
- [Lua API](api.md)
- [Development](development.md) — builds, tests, source layout, releasing
