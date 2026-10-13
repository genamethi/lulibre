# lulibre

A fast, modal terminal workbench for the metadata of a [calibre](https://calibre-ebook.com)
library: a full-text index over the first pages of every book, a filter
language, batch editing with undo, and Lua scripting. C, notcurses, libuv.

**Alpha.** It works and is tested, but it is young: try changes on a few
books before a few hundred. Every change is journaled and `u` undoes it,
removals included. [Changelog](CHANGELOG.md).

## Install

Needs a C compiler, pkgconf and the development files of **libuv**,
**sqlite3**, **notcurses**, **mupdf**, **djvulibre** and **Lua 5.4 or 5.5**.

    ./configure --prefix=/usr/local
    make
    make check          # optional: unit tests and a quick end-to-end test
    sudo make install   # or: make DESTDIR=$PWD/stage install

At run time:

| For | Needs |
|---|---|
| changing the library | calibre's `calibredb` |
| the sync folder, orphans, onboarding | the `luv` rock: `luarocks install --local luv` |
| OCR | `tesseract` |
| looking books up (`:enrich`), fetching the databases below | `curl` |
| arXiv's records from Kaggle | [`pixi`](https://pixi.sh) (or `kaggle`), and a Kaggle account |

`make help` lists every target; `./configure --help` every option.

## Set up

    lulibre config --write        # writes ~/.config/lulibre/init.lua, every option commented
    $EDITOR ~/.config/lulibre/init.lua

Set at least the library. If you run calibre's content server, give its
address and account and changes go through it; without one, lulibre changes
the library folder directly.

```lua
local o = lulibre.o
o.library = "~/calibre-library"
o.server = "http://127.0.0.1:8080"          -- optional
o.user = "me"
o.password_file = "~/.config/calibre/password-file"
```

    lulibre index                 # first run: a few seconds per thousand files

Optional, now or any time later: databases for looking books up without
asking anybody.

    lulibre datasets              # says what there is and asks which to fetch

| Dataset | Useful if you have | Size |
|---|---|---|
| `arxiv` | arXiv preprints | 1.7 GB to fetch, 5.6 GB on disk |
| `openlibrary` | books with an ISBN | 9.7 GB |
| `zbmath` | arXiv preprints in mathematics | 37 MB |

They go in `~/.local/share/lulibre`. Run it again to renew them: what is
here and fresh is left alone. Files you fetched yourself are taken up with
`lulibre datasets add FILE...`. More in [docs/workflows.md](docs/workflows.md).

## Use

    lulibre                       # the interface; ? lists every key and command

| Keys | |
|---|---|
| `j` `k` `gg` `G` `<C-d>` `<C-u>` | move |
| `/` then `n` `N` | search, next, previous |
| `&` · `<BS>` | narrow the list as you type · show everything |
| `f` `ga` `gs` · `gt` | fuzzy-find a book, author, subject · browse as a tree |
| `Space` · `V` | mark · select a range |
| `e` | edit the selection, with ranked suggestions; `w` writes |
| `gc` | capture fields from file names or titles by pattern |
| `gr` | review proposed changes, surest first; `x` shows a book's other fields |
| `gT` | titles in CAPITALS to title case |
| `?` | every key: of the interface, or inside a panel, of that panel |
| `u` | undo the last change |
| `J` `K` `[` `]` · `P` | scroll and page the preview · text ⇄ page image |
| mouse | click a row; wheel scrolls; drag over text anywhere to copy it, `<C-v>` pastes it into a field; drag the line between windows to resize |
| `gd` · `go` | duplicate files (MD5) · orphaned records, files and links |
| `gS` `S` `X` · `gl` | the sync folder: show, add, add-and-remove · back to the library |
| `yb` `yk` `yp` | copy BibTeX, cite keys, paths |
| `` ` `` · `:` · `q` | log console · command line · quit |

Most actions apply to the selection: the range being selected, else the
marked books, else the one under the cursor.

## Examples

From the shell:

    lulibre stats                                   # what is missing, and the filter behind each count
    lulibre query 'author:unknown subject:number-theory'
    lulibre query -c 'text:"class field" year:>1990'
    lulibre show 1299                               # one book: metadata, file, indexed text
    lulibre bib 'tag:math/algebra' > algebra.bib
    lulibre run propose 'no:author'                 # read title pages; fills the review queue
    lulibre dupes                                   # books whose files are byte-identical
    lulibre orphans                                 # records with no file, files with no record
    lulibre sync                                    # what is waiting in the sync folder

In the interface:

- **Label unknown books.** `&author:unknown`, then `:run propose`, then `gr`:
  `a` accepts, `e` corrects, `A` accepts everything above a confidence, `w`
  writes.
- **Pull fields out of names.** Select books, `gc`, type
  `%author% - %title% (%year%)`; the table follows your typing. `w` writes.
- **Fix one thing on many books.** Mark them, `e`, `Enter` on *tags*, type
  `+math/topology, -misc`, `w`.
- **Take in new files.** Set `o.sync_dir`, press `gS`, fix what needs fixing,
  select all (`ggVG`) and `X`.

A script is Lua with one table, `lulibre`:

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
  pixels. That path has not been tested yet; `lulibre.o.blitter = "sextant"`
  forces block characters if it misbehaves.

## Documentation

- [Workflows](docs/workflows.md) — editing, review, capture, duplicates, orphans, the sync folder, BibTeX, OCR
- [Filters](docs/filters.md) — the query language
- [Keys and commands](docs/keys.md)
- [Configuration](docs/configuration.md) — options, colours, key maps
- [Lua API](docs/api.md)
- [Development](docs/development.md) — builds, tests, source layout, releasing
