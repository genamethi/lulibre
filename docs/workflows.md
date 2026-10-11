# Workflows

lulibre reads calibre's `metadata.db` and the book files directly, and never
writes to either itself. Every change goes to calibre through `calibredb`,
is recorded in a journal with the value it replaced, and can be undone with
`u`.

Most actions apply to the **selection**: the range being selected with `V`,
else the marked books that are in the list, else the book under the cursor.
With the cursor in review, duplicates or orphans, that is the book its row
stands for; a command is refused when that book is no longer in the list.

## Editing: `e`

A form with one row per field for the selected book or books.

| Key | |
|---|---|
| `Enter` | type a value; a popup ranks suggestions and `Tab` takes the highlighted one |
| `Space` | step through what the file itself and related books suggest |
| `a` | fill every empty field with the best suggestion from the file |
| `c` | clear: blank the field |
| `t` | title case |
| `x` | revert: forget the change pending for the field |
| `w` | write |
| `?` | every key of the form |

In a list field (authors, tags, identifiers) `+x, -y` adds and removes values
and leaves the rest alone, which is how one tag is added to two hundred books.

To blank a field press `c`, or empty it (`<C-u>`, or backspace) and press
`Enter`: the form shows `(blank)` where the value will be removed. Both work
in review too.

### Copying from the page

The preview usually shows the title page, with the title and authors right
there. Drag over them with the mouse (or double click a word, triple click a
line) and they are copied; in a field, `<C-v>` or a middle click pastes them,
flattened to one line. This works while the field is open, and `<PageUp>` /
`<PageDown>` or the wheel scroll the preview meanwhile.

Inside tmux the copy is a tmux paste buffer as well, so text copied in
another pane pastes the same way.

## Title case: `gT`

A title set in CAPITALS is rewritten in title case, after the APA manual:
the first word of the title and of a subtitle is capitalised, so is every
major word and every word of four letters or more, and articles, short
conjunctions and short prepositions stay small.

    ON THE THEORY OF GROUPS: AN INTRODUCTION
    On the Theory of Groups: An Introduction

- `gT` (`:titlecase`) does it for the selection, leaving alone titles that
  are not in capitals; `:titlecase all` applies the style to any title.
  `&is:capstitle` lists the titles in capitals.
- `t` in the edit form and in review does it for the value under the cursor.
- Proposals do it by themselves: a title found in capitals on a title page,
  in a file's own metadata or in a `.bib` file is proposed in title case.
  `title_case = "never"` proposes titles as found.

Capitals carry no case to go by, so some of it is guessed: Roman numerals,
words with a digit, short words without a vowel (NMR) and a list of known
spellings (PDE, LaTeX, USA) are kept. The rules are English; both lists can
be added to in `init.lua`:

```lua
local tc = require "lulibre.titlecase"
tc.minor["with"] = true      -- APA capitalises "With"; this keeps it small
tc.minor["de"] = true        -- for French titles
tc.keep["cw"] = "CW"
```

## Proposals and review: `gr`

Scripts do not change the library; they *propose*, and you review.

    :run propose [filter]        metadata read from title pages
    :run split-authors           "A. One; B. Two" into separate authors
    :run enrich [filter]         arXiv and CrossRef records for books with an identifier
    :run normalize-tags          one spelling for subjects that exist under two
    :run bib-import FILE         what a .bib file says about books it matches

`propose` reads the first pages: an arXiv stamp, a cover sheet that labels
its fields (JSTOR's "Author(s):"), a thesis cover (title above "by", author
after it, institution, year), a by-line under the title ("By A. Name", or
"by" on a line of its own above the names), a page that opens with its
author's name alone on the first line and has its title further down, or
failing those the largest type on the page.

A name the leading pages give twice (again in an e-mail address or a running
head) is proposed with more confidence, and says so ("named twice"). Ranks
and roles are never proposed as authors ("Professor Emeritus", "Lecture
Notes"); the option `never_authors` adds words and phrases of your own:

    lulibre.o.never_authors = "visiting scholar, working group"
Each proposal carries where it came from and how sure it is.

A field that is empty always gets the file's best candidate. A field that
already has a value is proposed for when the file is confident (0.8 or more)
and says something different, so a slip made by hand is caught the next
time `:propose` runs over the book; review shows the value and the proposal
side by side. What counts as different ignores case, accents, the shape of
quotes and punctuation. The option `propose_over` moves the line:

| `propose_over` | a field that has a value |
|---|---|
| `gaps` | is left alone |
| `sure` (default) | is proposed for when the file is confident and differs |
| `any` | is proposed for whenever the file's best candidate differs |

    :propose --over [filter]     as `any` for this run, and proposing again what was rejected before
    :propose --gaps [filter]     as `gaps` for this run

A proposal you rejected is not made again by a later run, unless `--over`
asks. In review, `A` (accept everything above a confidence) asks before it
includes proposals that replace a value.

`gr` lists the proposals book by book, with the current value beside each;
the list and preview follow the cursor, so the title page is in view. The
book whose surest proposal is surest comes first, so what can be accepted at
a glance is at the top and what needs thought is further down; each book's
line says how many proposals wait and how sure the surest is. `s` switches
to book id order (the option `review_sort` sets which it starts in).

Review, duplicates and orphans bring themselves up to date when the library
changes under them: a book removed with `:remove` leaves the panel.

| Key | |
|---|---|
| `a` `r` | accept, reject; on a book's own line, all of that book's proposals |
| `e` | correct the proposed value, then accept it |
| `x` · `X` | show this book's other fields under its proposals · for every book |
| `e` on a shown field | edit it in the same pass; it becomes an accepted proposal |
| `A` | accept everything at or above a confidence |
| `R` | reject everything still pending |
| `c` | propose blanking the field |
| `t` | put the value in title case, and accept that |
| `s` | sort: surest first, or by id |
| `p` | more preview: shrink the panel, and again to bring it back |
| `w` | write the accepted ones as one batch |

`:review FILTER` keeps the review to the books a filter matches
(`:review author:unknown`); `w` then writes only theirs.

Copying from the page does not take the cursor out of review: drag over a
name in the preview, or double click a word, and the next key is still
review's, so `e` then `<C-v>` puts what was copied into the field. (A plain
click in the preview, one that selects nothing, does move the cursor there.)

While the cursor is in review, duplicates, orphans or capture, the preview's
own keys still work: `P` for the page as an image, `]` `[` to turn pages,
`J` `K` to scroll, as do the copying keys (`yy` ...). `?` lists them.

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

`e` opens the edit form for the book under the cursor and `r` the review of
its proposals; the duplicates panel steps aside while they are open and
comes back up to date. `p` gives the preview more room.

`t` takes from the copy under the cursor: every field where its record says
something the kept copy's does not is proposed for the kept copy, and review
opens on those proposals, each marked with the book it came from. Accept
what is wanted and `w` writes it; nothing is removed.

## Orphans: `go`

| Found | Suggested |
|---|---|
| a record whose file is gone, and the file is elsewhere in the library | re-attach it |
| a record whose file is gone, and another book is the same work | remove the record |
| a file in one of calibre's folders that calibre does not know | move it out, if a book already holds the same bytes |
| a symbolic link in a folder of your own that points at a renamed book | repair it |

`Space` changes a row's action, `w` carries them out. `e` and `r` open the
edit form and the review for the row's book, as in duplicates, and `t` on a
record whose file is gone offers what it says to the book that is the same
work and has the file. `x` opens the row
under the cursor to show what its columns cut short (the verdict in full,
the whole path, where a link points); `X` opens every row. Removed records go to
calibre's recycle bin (`u` brings them back); stray files are moved to
`~/.local/share/lulibre/orphans/`, never deleted. Calibre renames a book's
folder when its title or author changes; with `repair_links = "auto"` links
are repaired after every such change.

## The sync folder: `gS`

Set `lulibre.o.sync_dir` to a folder where files arrive. A tab line then
appears along the top: `1 Library` and `2 Sync folder`, with how many each
holds and which the list is showing. `2` (or `gS`, or a click on the tab)
reads the folder and shows it in place of the library; `1` (or `gl`) goes
back.

A file there is *staged*: listed, filtered, searched and previewed like a
book, and `e`, `gc`, `:run propose`, `gr` and undo all work on it. Those
edits are kept by lulibre; nothing reaches calibre until:

| Key | |
|---|---|
| `S` | add the selection to the library with its staged metadata; the files stay |
| `X` | add, then delete each file from the folder once calibre holds the same bytes |
| `D` | drop: take the selection out of the folder without adding it. The files are kept under `~/.local/share/lulibre/dropped/` and `u` puts them back |

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

Removals are batches too. Undoing one re-adds each book from calibre's
recycle bin (`.caltrash` in the library folder), with its files, cover and
metadata; the book comes back under a new id. It works for as long as
calibre keeps the bin, which it empties after some days.

If lulibre itself crashes, `~/.local/state/lulibre/crash.log` has the
backtrace.
