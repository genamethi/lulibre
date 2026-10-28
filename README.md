# lulibre

A fast, modal terminal workbench for the metadata of a [calibre](https://calibre-ebook.com)
library: a full-text index over the first pages of every book, a filter
language, batch editing with undo, and Lua scripting. C, notcurses, libuv.

**Alpha.** It works and is tested, but it is young: try changes on a few
books before a few hundred. Every change is journaled and `u` undoes it,
removals included. [Changelog](CHANGELOG.md).

## Build

Needs a C compiler, pkgconf and the development files of **libuv**,
**sqlite3**, **notcurses**, **mupdf**, **djvulibre**, **OpenSSL** (libcrypto)
and **Lua 5.4 or 5.5**.

    ./configure
    make                # build/lulibre, and build/lulibre-setup
    make check          # optional: unit tests and the runtime's tests

At run time:

| For | Needs |
|---|---|
| changing the library | calibre's `calibredb` |
| OCR | `tesseract` |
| looking books up (`:enrich`) | `curl`, the `dkjson` rock |
| grammars | the `lpeg` rock |

`pixi.toml` provides the run-time dependencies through [pixi](https://pixi.sh).

`make help` lists every target; `./configure --help` every option.

## Set up

    make install BINDIR=~/.local/bin DATADIR=~/.local/share   # or: sudo make install

lulibre needs only to know where the library is: `-L DIR`,
`$LULIBRE_LIBRARY`, or in `~/.config/lulibre/init.lua`:

```lua
setman.set("library", "~/calibre-library")
setman.set("server", "http://127.0.0.1:8080")          -- optional: calibre's content server
setman.set("user", "me")
setman.set("password_file", "~/.config/calibre/password-file")
```

When calibre's content server has the library open, changes go through it;
when nothing has it open, straight to the folder. lulibre never reads the
password: calibredb gets the file's name.

    lulibre index                 # first run: a few seconds per thousand files

## Use

    lulibre                       # the interface; ? lists every key and command

| Keys | |
|---|---|
| `j` `k` `gg` `G` `<C-d>` `<C-u>` | move |
| `/` then `n` `N` | search, next, previous |
| `&` · `<BS>` | narrow the list as you type · show everything |
| `f` `ga` `gs` | fuzzy-find a book, author, subject |
| `gh` | the list as a tree: by author, subject, series, publisher, year, format |
| `Space` · `V` | mark · select a range |
| `e` | edit the selection; `w` writes |
| `gp` · `gr` | propose metadata from the files · review the proposals |
| `u` | undo the last change |
| `?` | every key: of the interface, or inside a panel, of that panel |
| `J` `K` `[` `]` · `P` | scroll and page the preview · text ⇄ page image |
| mouse | click a row; wheel scrolls; drag over text anywhere to copy it, `<C-v>` pastes it into a field; drag the line between windows to resize |
| `` ` `` · `:` · `q` | log console · command line · quit |

Most actions apply to the selection: the range being selected, else the
marked books, else the one under the cursor.

## Examples

From the shell:

    lulibre stats                                   # what is missing, and the filter behind each count
    lulibre query 'author:unknown subject:number-theory'
    lulibre query -c 'text:"class field" year:>1990'
    lulibre show 1299                               # one book: metadata, file, indexed text
    lulibre -o ocr=auto index                       # read the files, with OCR where their text is not usable

In the interface:

- **Label unknown books.** `&author:unknown`, mark them, `gp`, then `gr`:
  `a` accepts, `e` corrects, `r` rejects, Space shows the next alternative.
- **Look them up.** Books with a DOI, ISBN or arXiv number: `:enrich`; the
  answers propose too.
- **Fix one thing on many books.** Mark them, `e`, `Enter` on *tags*, type
  `+math/topology, -misc`, `w`.

A script is Lua:

```lua
-- ~/.config/lulibre/scripts/no-date.lua  —  :run no-date
for _, book in ipairs(lulibre.books("no:date has:doi")) do
  print(book.id, book.title, book.idents.doi)
end
```

## In tmux, in ghostty

- Inside tmux, the mouse needs `set -g mouse on`, and copies go through tmux
  (`tmux load-buffer -w`), so they also land in a tmux paste buffer.
- Inside tmux the page-image preview (`P`) is drawn with block characters;
  tmux does not pass graphics through. Run directly in a terminal with the
  kitty graphics protocol, such as ghostty, lulibre asks notcurses for real
  pixels (tested in ghostty); `setman.set("blitter", "sextant")` forces block
  characters if it misbehaves.

## Documentation

Inside lulibre, `?` shows the keys under headings (with a search), and
`:help TOPIC` shows what these guides say about a word. `man lulibre`
covers the command line.

- [Workflows](docs/workflows.md) — reading the files and OCR, editing, proposals and review, online lookups
- [Filters](docs/filters.md) — the query language
- [Keys and commands](docs/keys.md)
- [Configuration](docs/configuration.md) — settings, colours, key maps
- [Lua API](docs/api.md)
- [Development](docs/development.md) — builds, tests, source layout, releasing

## License

lulibre is under the Apache License 2.0 with LLVM Exceptions
(`Apache-2.0 WITH LLVM-exception`): see [LICENSE](LICENSE). The libraries
it links keep their own licenses. MuPDF's is the AGPL (version 3 or later),
so a lulibre binary built with it is distributed under the AGPL's terms.
