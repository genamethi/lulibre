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
| `subject` | the tree of subjects: `math`, inside it `number-theory`, inside that `additive` |
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
three. A field's proposal is the best-ranked parse's value; every other
parse's value is an alternative. A value the record already has is not
proposed.

In review, one row per field:

| Key | |
|---|---|
| `a` | accept the value shown |
| `e` | edit it, then accept |
| `r` | reject it: the field keeps its value |
| `Space` | show the next alternative |
| `q` | close |

Accepting is a change like any other, and `u` puts it back. Every
decision, rejections too, goes into the journal with the parse that made
the proposal: that is what a parse's record is measured from, against each
field's value as it stands now. While review is open, a change to a book
in view proposes for it again.

## Looking books up: `:enrich`

`:enrich` asks the online services about the selected books, by their
identifiers: Crossref by DOI, Open Library by ISBN, arXiv by arXiv number.
Each answer is kept in the index, and a kept answer is not asked for
again. An answer is a source of agreement for the parses, and a parse of
its own: it proposes, ranked beside the grammars'.

Each service is asked no sooner than its pace (arXiv every 5 seconds,
Open Library every 2, Crossref every second), arXiv forty works at a time,
and a service that says it is asked too much is left alone for a while.
Nothing is asked but on command. `contact_email`, when set, goes with each
request; some services answer faster for it.

## Changes, and who has the library

calibre lets one program at a time have a library open. lulibre watches
for it: when calibre's content server has the library, changes go through
the server (the settings `server`, `user`, `password_file`); when nothing
has it, straight to the folder; while calibre's own program has it,
changes wait, and run once it closes. calibre's lock is one for all of a
user's libraries: while a calibre program has another library open (a
copy of this one, say), changes wait too. Changes that wait are in the
journal, and run at the next start if lulibre is closed first.

With `embed`, each change is also written into the books' files
(`calibredb embed_metadata`, once per change), so other programs see it.

## When something goes wrong

`` ` `` opens the log console. The status line counts errors until the
console has shown them. If lulibre itself crashes,
`~/.local/state/lulibre/crash.log` has the backtrace.
