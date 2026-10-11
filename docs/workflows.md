# Workflows

lulibre reads calibre's `metadata.db` and the book files directly, and never
writes to either itself. Every change goes to calibre through `calibredb`,
is recorded in a journal with the value it replaced, and can be undone with
`u`.

Most actions apply to the **selection**: the range being selected with `V`,
else the marked books that are in the list, else the book under the cursor.

## Editing: `e`

A form with one row per field for the selected book or books.

| Key | |
|---|---|
| `Enter` | type a value; a popup ranks suggestions and `Tab` takes the highlighted one |
| `Space` | step through what the file itself and related books suggest |
| `a` | fill every empty field with the best suggestion from the file |
| `x` | clear the pending value |
| `w` | write |

In a list field (authors, tags, identifiers) `+x, -y` adds and removes values
and leaves the rest alone, which is how one tag is added to two hundred books.

### Copying from the page

The preview usually shows the title page, with the title and authors right
there. Drag over them with the mouse (or double click a word, triple click a
line) and they are copied; in a field, `<C-v>` or a middle click pastes them,
flattened to one line. This works while the field is open, and `<PageUp>` /
`<PageDown>` or the wheel scroll the preview meanwhile.

Inside tmux the copy is a tmux paste buffer as well, so text copied in
another pane pastes the same way.

## Proposals and review: `gr`

Scripts do not change the library; they *propose*, and you review.

    :run propose [filter]        metadata read from title pages
    :run split-authors           "A. One; B. Two" into separate authors
    :run enrich [filter]         arXiv and CrossRef records for books with an identifier
    :run normalize-tags          one spelling for subjects that exist under two
    :run bib-import FILE         what a .bib file says about books it matches

`gr` lists the proposals book by book, with the current value beside each;
the list and preview follow the cursor, so the title page is in view.

| Key | |
|---|---|
| `a` `r` | accept, reject |
| `e` | correct the proposed value, then accept it |
| `x` · `X` | show this book's other fields under its proposals · for every book |
| `e` on a shown field | edit it in the same pass; it becomes an accepted proposal |
| `A` | accept everything at or above a confidence |
| `R` | reject everything still pending |
| `w` | write the accepted ones as one batch |

Proposals are kept between sessions.

## Capture: `gc`

Pull fields out of file names, titles or embedded metadata. Type a pattern
and the table shows what it finds in each selected book:

    %author% - %title% (%year%)                       a template
    ^(.-) %- (.-) %((%d+)%)$ => author, title, year   a Lua pattern, then the names of its captures

| Key | |
|---|---|
| `p` · `s` | change the pattern · change what it runs against (file name, title, authors, embedded title or author) |
| `w` · `P` | write what was captured · turn it into proposals instead |
| `m` | mark the books that matched |
| `S` `L` | save the pattern as a named rule, load one |

## Duplicates: `gd`

Books whose files are byte for byte the same. Only files that share a size
are hashed (MD5), and hashes are remembered, so this is quick.

`Space` chooses the copy to keep (the record with the most metadata by
default), `s` skips a group, `m` marks the surplus, `f` filters the list to
`is:dupe`, `D` removes the surplus. What a removed record knew that the kept
one does not becomes proposals for the kept one.

## Orphans: `go`

| Found | Suggested |
|---|---|
| a record whose file is gone, and the file is elsewhere in the library | re-attach it |
| a record whose file is gone, and another book is the same work | remove the record |
| a file in one of calibre's folders that calibre does not know | move it out, if a book already holds the same bytes |
| a symbolic link in a folder of your own that points at a renamed book | repair it |

`Space` changes a row's action, `w` carries them out. Removed records go to
calibre's recycle bin; stray files are moved to
`~/.local/share/lulibre/orphans/`, never deleted. Calibre renames a book's
folder when its title or author changes; with `repair_links = "auto"` links
are repaired after every such change.

## The sync folder: `gS`

Set `lulibre.o.sync_dir` to a folder where files arrive. `gS` reads it and
shows it as the list in place of the library; `gl` goes back.

A file there is *staged*: listed, filtered, searched and previewed like a
book, and `e`, `gc`, `:run propose`, `gr` and undo all work on it. Those
edits are kept by lulibre; nothing reaches calibre until:

| Key | |
|---|---|
| `S` | add the selection to the library with its staged metadata; the files stay |
| `X` | add, then delete each file from the folder once calibre holds the same bytes |

`=` marks a staged file the library already has. Adding it adds nothing;
moving it only clears it out of the folder.

## Metadata that comes with the files

A `.bib` file beside a set of files, whose entries name them in
`file = {...}`, is taken as the truth about those files: the sync folder and
`:run onboard DIR` use it instead of reading title pages, and
`:run bib-import` matches its entries to books by content. A build can write
one next to its output. Fields used: `author`, `title`, `date`/`year`,
`publisher`, `series` with `number`, `keywords` (tags), `doi`, `isbn`,
`eprint`, `url`.

## BibTeX

    lulibre bib 'tag:math/algebra' > algebra.bib
    :bib FILE                    the selection
    yb  yk                       copy entries, or cite keys, to the clipboard

Entries carry a `file` field, which Zotero, JabRef and BibDesk understand.

## OCR

    :ocr [filter]                tesseract, for books with no usable text layer
    lulibre ocr 'is:needsocr'

`lulibre.o.ocr = "auto"` runs it after indexing for files that need it.

## Without the content server

`lulibre.o.write_via` chooses the route: `"server"`, `"direct"` (straight to
the library folder, which calibre permits only while none of its programs
has the library open), or `"auto"`, the default: the server when it answers,
else direct.

## When something goes wrong

`` ` `` opens the log console. Errors are counted in the status line until it
has shown them. `:history` lists every batch of changes; `:undo N` puts one
back, leaving alone any field that has been changed again since.
