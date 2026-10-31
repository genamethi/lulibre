# Workflows

lulibre reads calibre's `metadata.db` and the book files, and never writes
to either itself. Every change goes to calibre through `calibredb`, and the
journal records it with the value it replaced and where the new value came
from. `u` puts the last change back.

Most actions apply to the **selection**: the range selected with `V`, or
else the marked books, or else (in a grouped list, with the cursor on a
heading) every book under that heading, or else the book under the cursor.
A command given a filter (`:propose author:unknown`) applies to the books
the filter finds instead.

## The list as a tree: `gh`

The list can be grouped under headings and browsed as a hierarchy, without
leaving it:

| Grouping | Headings |
|---|---|
| `author` | each author; a book by two authors appears under both |
| `subject` | the tags as a tree, split at calibre's ".": `math`, inside it `number-theory`, inside that `additive` (`math.number-theory.additive`); a tree only when calibre shows tags as one (Preferences → Look & feel → "Categories with hierarchical items"), each tag as it is otherwise |
| `series` `publisher` `year` `format` | each value; years newest first |
| `folder` | the folders of the calibre library, as it is filed on disk |
| `none` | the plain list |

`gh` chooses the grouping (`:group subject`), and `gH` goes back to the
plain list. A heading shows how many books are under it, and `◐` or `●`
if some or all of them are marked.

| Key | |
|---|---|
| Enter, `l`, `→`, `zo` | open a heading |
| `h`, `←`, `zc` | close a heading. On a book, close the heading the book is under; on a closed heading, move to the heading that contains it |
| `za` | open or close |
| `zR` `zM` | open or close all headings |
| a click on a heading | open or close it |
| `Space` | on a heading: mark every book under it (or unmark them, if all are marked) |
| `e` | open the edit form for the book, or for every book under the heading |
| `r` | review the proposals waiting for the book, or for the books under the heading |
| Enter on a book | open the edit form |
| `s` | choose the order of the books (`:sort title`, `-year`, `-added` ...) |

`:group count` puts the largest headings first, and `:group name` sorts
them by name again. Books with nothing to group by appear last, under
`(none)`. Filters and searches work as usual: a filter keeps the headings
that still hold a book, with counts of the matches, and a search opens the
headings that hold a match. A list of forty books or fewer starts with its
headings open, and a longer list starts with them closed. lulibre remembers
the grouping between sessions.

## Reading the files

lulibre reads the first `pages` pages of every book's file into its index,
as lines: each line's text, size, place on the page, and whether it is
bold, italic or starts a paragraph. Reading runs in the background when the
interface starts (`auto_index`), and `:index` runs it now; a file is read
again only when it changes.

A file's text is judged as it is read: enough letters, few characters no
font could map, enough words that look like words. With `ocr = "auto"`,
tesseract reads the first `ocr_pages` pages of a file whose text is not
usable; with `ocr = "always"`, every file's. OCR's lines come with their
place and size too, and its text replaces the file's own when it is usable
or the file's is not. Turning OCR on later reads again the files that
wanted it.

Each file has one outcome, and each is a filter:

| Filter | |
|---|---|
| `is:read` | usable text |
| `is:ocr` | the text layer was not usable; OCR's is |
| `is:ocrfailed` | not usable after OCR either |
| `is:noocr` | not usable, and OCR is off or tesseract is not installed |
| `is:unreadable` | the file did not open (`lulibre show ID` says why) |
| `is:missing` | no file at the recorded path, or no file at all |
| `is:unread` | not read yet |

`lulibre stats` counts each. `text:` searches the text by paragraph.

## Editing: `e`

The edit form has one row per field for the selected books, with the
value each has now (the first book's, for several) and the value it is to
get.

| Key | |
|---|---|
| `Enter` `e` | type a value |
| `x` | drop the field's change |
| `w` | write every change, to every book in the form, as one change |
| `q` | close without writing |

These are the keys of the place `form`, which `keymap.set("form", key,
action)` rebinds ([keys](keys.md)).

In a list field (authors, tags, identifiers, languages), `+x, -y` adds
and removes values and leaves the rest alone. That is how you add one tag
to two hundred books. An empty value blanks the field.

### Selecting text with the keys

`v` puts a cursor in the preview's text. `h` `j` `k` `l` and the arrows
move it, `w` and `b` move by words, `0` and `$` go to the ends of the line,
and `gg` and `G` to the ends of the page. `v` starts a selection at the
cursor (and cancels it if pressed again), and `V` selects the line. `y` or
Enter copies the selection (or the line, if nothing is selected) and gives
the keys back. `Esc` or `q` leaves without copying. `]` and `[` still turn
pages.

### Copying from the page

The preview usually shows the title page, with the title and authors on
it. Drag over them with the mouse (or double-click a word, triple-click a
line) to copy them. In a field, `<C-v>` or a middle click pastes them as
one line. This works while the field is open, and `<PageUp>` / `<PageDown>`
or the wheel scroll the preview meanwhile.

Inside tmux, the copy also goes to a tmux paste buffer, so text copied in
another pane pastes the same way.

## Proposals and review: `gp`, `gr`

`gp` (`:propose`) reads each selected book's file and proposes values for
its fields; `gr` (`:review`) shows them.

A proposal comes from a **parse**: a grammar's reading of the file, or an
online record. A grammar is a pattern over the text that knows where a
kind of book states its title, authors, publisher or year: the largest
lines at the top of the first page, the bold line after the series name.
lulibre comes with one, `front`, which takes a first page's largest lines
as the title and the line after as the authors; grammars written for an
author, a publisher or a series are added in Lua (see [the Lua
API](api.md)).

The parses of a book are ranked: by the fields each fills (title and
authors count most), by how far its values agree with the book's sources
(the record, the file's own metadata, the online answers kept for it), and
by its record of review decisions once the journal holds a hundred of them.
The settings `rank_coverage`, `rank_agreement` and `rank_track` weigh the
three, and a value on the file's pages gains `rank_on_page`.

What is worked out from a file is kept: what each grammar finds, the file's
identifiers, how much of a value is on its pages. A new online answer or a
changed setting only ranks again; nothing is read again until the file is.

An identifier is taken as the file's own if its metadata says so, or, before
any references or bibliography (those words alone on a line, from `id_refs_from`
of the way through the document on), if an ISBN has its label, or a DOI or arXiv
number is near the top (`id_top`), or a DOI begins a line with its label, or
an arXiv number has its margin stamp. An online record is compared with the
pages before it counts: its title scores `min(1, check_title_k * found / words
+ check_title_base)`, without small words; its authors found add up to
`check_authors`; a page count further from the file's than `check_pages` means
it is another book, and no page count means nothing. At `check_same` it is
this book. When such a record comes by the file's own identifier, and all of
them agree (several ISBNs of one work do), the book's match is clear: its
values score from `score_identified` up to 1 by how much of them is on the
pages, and the other parses' values for those fields are kept but not shown.

A field's proposal is the best-scoring value, and the others its alternatives.
A value the record already has is not proposed, nor one a decision has already
gone against. A review shows up to `propose_values` values per field, none
scoring under `propose_min` or, where the field has a value, under
`propose_over`. `:review deep`, or `z` in review, shows the rest too, with
records the pages did not bear out.

In review, one row per field:

| Key | |
|---|---|
| `a` | mark the value shown accepted |
| `e` | edit it, then mark it accepted |
| `r` | mark it rejected: the field keeps its value |
| `u` | take the mark off |
| `Space` | show the next alternative |
| `w` | write what is marked |
| `z` | show or hide what the review otherwise doesn't |
| `s` | name the review |
| `o` | open another review |
| `n` | start a new review |
| `d` | discard the review |
| `A` | add books to it, by a filter |
| `E` | ask the online services about its books |
| `p` | drop the proposals whose value the record now holds (`review_prune` does so by itself) |
| `q` | close |

A review stays as it is until you write or discard it: closing it, or quitting,
keeps its proposals and marks. `:propose` adds to the current one. Writing in
one review leaves the others' proposals alone; the Record column always shows
what the record holds now.

Writing is an operation like any other, and `u` in the list puts it back.
Every decision, rejections too, goes into the journal with the parse that made
the proposal: that is what a parse's record is measured from, against each
field's value as it stands now.

## Holding the records against the files: `:verify`

`:verify` lists the books whose pages leave something of the record unborne: a
title scoring under `check_same`, authors none of whose names are there, an
identifier that is not the file's own, or a file that can't be read. It goes by
what was kept and reads only files not read before. It changes nothing, but
`r` proposes for the book under the cursor, adding it to the current review, and
`R` for every book listed. `z` lists the rest too.

## The sync folder

The files in `path.sync` are shown by `gS` or `:source sync` as books, and
everything that works on a book works on them: filters, the preview, `:propose`,
review. What you change stays in lulibre until the file is added.

| | |
|---|---|
| `:sync` | a dialog on the selected files: add, add and take out, or drop; propose first if you like |
| `:sync add [filter]` | add them to the library, with what lulibre knows of them |
| `:sync move [filter]` | add them, and take them out of the folder |
| `:sync drop [filter]` | take them out of the folder without adding them |
| `:beside`, `gb` | the waiting files in a column; the library's list follows the file under the cursor |
| `:onboard DIR` | take a folder as the sync folder for now |

In a review, `y` does what `w` does, then adds the review's files to the library:
the same review, ending in sync instead of write. Proposals still waiting go with
a file into the library. A file taken out of the folder goes to `dropped/` beside
the index. `:undo` takes what was added back out of the library, and brings a
file taken out back into the folder with what lulibre knew of it.

## Rewriting values

These propose a value worked out from the value a field has, adding it to the
current review, first among the field's values; they change nothing until the
review writes them. With no filter, each works on the selection.

| | |
|---|---|
| `:titlecase [all] [filter]` | titles in CAPITALS, or with `all` any title, in title case |
| `:notation [filter]` | titles with their mathematics in Unicode: SL₂(ℤ), read from the title page where it has them |
| `:split-authors [filter]` | one "author" that is several people, by default every such book |
| `:normalize-tags [filter]` | tags under their canonical names, by default every book |
| `:clear FIELDS [filter]` | blank fields: title authors tags identifiers pubdate publisher series, or t a s i d p e |
| `:capture [pattern]` | pull fields out of the selected books with a pattern, `%author% - %title% (%year%)`, and propose them |

`:junk [filter]` marks and lists the books whose title or author is plainly not one.
`lulib._rewrites.list` holds the rewrites: yours is a field and a function from
value to value.

## Looking books up: `:enrich`

`:enrich` asks the online services about the selected books, by their
identifiers: Crossref and OpenAlex by DOI, zbMATH by DOI or arXiv number, Open
Library by ISBN, arXiv by arXiv number. `:enrich titles` also searches Crossref
by title for books with no identifier to ask by; such a record has to agree with
the book's title and authors as well as its pages, and never counts as a clear match.
Each answer is kept in the index, and a kept answer is not asked for
again. An answer is a source of agreement for the parses, and a parse of
its own: it proposes, ranked beside the grammars'.

Each service is asked no sooner than its pace (arXiv every 5 seconds,
Open Library every 2, Crossref every second), arXiv forty works at a time,
and a service that says it is asked too much is left alone for a while.
Nothing is asked but on command. `contact_email`, when set, goes with each
request; some services answer faster for it.

## History and snapshots

Every change goes into the journal with its old value, and lulibre also logs what
changed in calibre by other means, each time it reads calibre's records, in batches
labelled "outside". `:history` lists the batches, newest first: Enter shows a batch's
rows, `u` puts it back, `a` hides what changed outside.

A snapshot is a position in the journal, not a copy of the library. `:snapshot NAME`
takes one, `:snapshots` (`gz`) shows what going back to each would do, and
`:rollback SNAP` goes back to it, after showing that and asking. It takes a snapshot
of its own first, and going back to that rolls forward.

| | |
|---|---|
| `exact` | put back changes made outside lulibre too |
| `unsync` | books added from the sync folder leave the library, their files to `unsynced/` in the folder; otherwise they go back to how they came |
| `fields` | fields only: no book is brought back, removed or taken out |

`:snapshot import FILE [NAME]` makes a snapshot from a copy of calibre's `metadata.db`,
such as one kept from before lulibre.

## Looking after the library

| | |
|---|---|
| `:remove [filter]` | remove the selected books from calibre, to its recycle bin; `:undo` puts them back, under new ids |
| `:dupes`, `gd` | books whose files hold the same bytes: keep one of each (`Space`), skip a group (`s`), remove the rest (`D`). What the others knew is proposed for the one kept |
| `:orphans`, `go` | records with no file, files with no record, broken links in your own folders, empty folders. `Space` says what to do about a row, `w` does it; `:orphans write` does what is suggested. Files taken out go to `orphans/` beside the index |
| `:embed [filter]` | write calibre's metadata into the selected books' own files |
| `:columns [push \| remove]` | calibre columns for `#partof`, `#part` and `#parts`; `push` copies lulibre's values into them |
| `:offline [cancel JOB \| retry \| restart]` | what waits for nothing to hold the library. `restart` stops the content server by its systemd unit, and starts it again once they're done |

## Changes, and who has the library

calibre lets one program at a time have a library open. lulibre watches
for it: when calibre's content server has the library, changes go through
the server (the settings `server`, `user`, `path.password`); when nothing
has it, straight to the folder; while calibre's own program has it,
changes wait, and run once it closes. calibre's lock is one for all of a
user's libraries: while a calibre program has another library open (a
copy of this one, say), changes wait too. Changes that wait are in the
journal, and run at the next start if lulibre is closed first.

With `embed`, each change is also written into the books' files
(`calibredb embed_metadata`, once per change), so other programs see it.

## calibre's server and lulibre's systemd units

When calibre's content server runs as a systemd unit, three settings say
which units of lulibre's go with it:

| Setting | |
|---|---|
| `server_hook = true` | `lulibre.service`, run before each start of the server's unit: `lulibre offline` reads calibre's records and makes the changes that wait for nothing to hold the library |
| `opf_writer = "server"` | a drop-in on the server's unit (`lulibre-opf-writer.conf`) that starts it through `contrib/calibre-server-opf.py`, so calibre's own opf writer runs in the server; not made on a unit with sandboxing or hardening settings, where the change is shown instead |
| `server_restart_at = "HH:MM"` | `lulibre-restart.timer`, which restarts the server every day at that time |

`:units` shows what would change and why not where it cannot; `:units
apply` makes it: a user unit's files directly, a system unit's with sudo,
in the terminal, after asking, and a restart of the server, asked. When
one of the three has been set (init.lua, the command line, the saved
state), the interface keeps a user unit as they say when it starts;
left at their defaults, nothing is touched. Changing one in the
Configuration tab applies it at once.

## When something goes wrong

`` ` `` opens the log console. The status line counts errors until the
console has shown them. If lulibre itself crashes,
`~/.local/state/lulibre/crash.log` has the backtrace.
