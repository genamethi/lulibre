# Workflows

lulibre reads calibre's `metadata.db` and the book files directly, and never
writes to either itself. Every change goes to calibre through `calibredb`,
is recorded in a journal with the value it replaced, and can be undone with
`u`.

Most actions apply to the **selection**: the range being selected with `V`,
else the marked books that are in the list, else (in a grouped list, with
the cursor on a heading) every book under that heading, else the book under
the cursor. With the cursor in review, duplicates or orphans, that is the
book its row stands for; a command is refused when that book is no longer
in the list.

## The list as a tree: `gh`

The list can be set out under headings, and browsed as a hierarchy without
leaving it:

| Grouping | Headings |
|---|---|
| `author` | each author; a book by two stands under both |
| `subject` | the tree of subjects: `math`, within it `number-theory`, within that `additive` |
| `series` `publisher` `year` `format` | each value; years the newest first |
| `folder` | the folders of the calibre library, as it is filed on disk |
| `none` | the plain list |

`gh` picks the grouping (`:group subject`), `gH` goes back to the plain
list. A heading shows how many books are under it, and `◐` or `●` when some
or all of them are marked.

| Key | |
|---|---|
| Enter, `l`, `→`, `zo` | open a heading |
| `h`, `←`, `zc` | close it; on a book, close the heading it is under; on a closed heading, step out to the one it is within |
| `za` | open or close |
| `zR` `zM` | open, or close, all of them |
| a click on a heading | opens or closes it |
| `Space` | on a heading: mark every book under it (or unmark, when they all are) |
| `e` | the edit form: for the book, or for every book under the heading |
| `r` | the proposals waiting for the book, or for the books under the heading |
| Enter on a book | the edit form |
| `s` | choose the order of the books (`:sort title`, `-year`, `-added` ...) |

`:group count` puts the largest headings first, `:group name` back in
order of name. Books with nothing to be grouped by stand under `(none)`,
last. Filters and searches work as ever: a filter leaves the headings that
still hold a book, with the counts of what it matched, and a search opens
the headings that hold a match. A list of forty books or fewer starts with
its headings open; a longer one, closed. The grouping is remembered between
sessions.

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

### Selecting text with the keys

`v` puts a cursor in the preview's text. `h` `j` `k` `l` and the arrows
move it, `w` and `b` by words, `0` and `$` to the ends of the line, `gg`
and `G` of the page. `v` begins a selection where the cursor is (and lets
go of it again), `V` takes the line; `y` or Enter copies what is selected
(the line, when nothing is) and gives the keys back to where they were;
`Esc` or `q` leaves without copying. Pages still turn with `]` and `[`.

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
    :propose --only FIELDS ...   only those fields: title authors subject ids date publisher, or t a s i d p
    :propose --fresh ...         as if the fields were empty: the file's best reading, whatever the book says

A value that is plainly not one counts as empty: a title that is a file
name, a number or a heading, an author that is a program, a web site or a
rank. `:junk` marks and lists the books that have such a title or author.

A title of one word is a title when it is a plain capitalised word
("Algebra", "Topology") and junk when it is what a file name leaves behind
("infinite", "E807en", "tensorprod"). The option `one_word_titles` changes
that: `ok` takes any single word for a title, `junk` takes none. Two things
protect a title whatever it looks like: listing it in `good_titles`
(`lulibre.o.good_titles = "Set, 1984"`), and confirming its record as good
(`gk`), after which nothing in that record is treated as junk.

**When one field went wrong across many books** (titles from a bad download
run, say): narrow the list to them, then

    :propose --fresh --only title

proposes the file's own title for each, whatever the record says, and review
(`gr`, then `f` `t` to see only the titles, then `A`) accepts them in one go.
`:clear FIELDS [filter]` blanks fields outright (`u` puts them back), and
`:propose --fresh` without `--only` re-reads every field of the books.

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
| `f` then a letter | only one field's proposals: `t` title, `a` authors, `s` subject, `i` identifiers, `d` date, `p` publisher; `f` `f` shows all again. Accept-all and reject-rest then speak for that field alone |
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

A book that already has a subject is offered another only when the file
states one (an arXiv class, MSC codes, a shelf class), with one exception:
a finer subject under the one it has. A book filed under `cs` whose pages
are plainly about machine learning is offered `cs/ml`, on the vocabulary's
word alone. `:propose --only s subject:cs` asks for exactly that.

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

## Layouts: pages that say their facts in known places

Some pages can be read by rule rather than by the size of their type, and
are, with more confidence:

| Layout | Read from it |
|---|---|
| cataloguing data (the Library of Congress block on the back of a title page) | author, title, series and number, year, ISBN, and the subject its class number stands for (`QA247` is number theory) |
| series page (some thirty series of Springer, the AMS, Cambridge, Princeton and others) | the series and the volume's number, the publisher, the year (of the edition a reprint reprints) |
| series line (a series named in so many words: "Springer Undergraduate Mathematics Series", the line above "Series Editors", "Series: Lecture Notes in Physics") | the series and, where it is given, the volume's number |
| arXiv stamp | the day of submission |
| received date ("Received 8 February 1972", "Received by the editors May 3, 1999") | the day a journal received the article |
| dated page (a date on a line of its own on the first page: "March 12, 2015", "Date: October 2009.") | that date |
| journal header ("Journal of Algebra 320 (2008) 1234–1256") | the year; the journal, as the publisher |
| copyright line ("© 2008 Elsevier Inc.", "Copyright © 1965, 1984 by McGraw-Hill") | the year, the latest where several stand together; the publisher, when the holder is one and not the author |
| a cover sheet with labelled fields; a thesis cover | as above, under proposals |

What they read is proposed like anything else, marked with the layout's
name.

The word "series" proves nothing by itself ("Fourier Series", "a series of
lectures given at ..."), so a line is taken for a series' name only when it
is set like a name, is not a piece of mathematics, and something beside it
bears it out: a volume number, the series' editors, an ISSN, or a
publishing house's name. Two tables say what counts, and take more:

```lua
local layouts = require "lulibre.layouts"
layouts.not_series["bertrand"] = true      -- "Bertrand Series" is a sum, not a set of books
layouts.series_houses["polity"] = true     -- "Polity Series in ..." needs nothing else to bear it out
```

A publisher on a copyright line is written one way whatever the line says
("Springer-Verlag Berlin Heidelberg", "Springer Nature Switzerland AG" and
"Springer Science+Business Media" are all Springer): `layouts.houses` is the
list, `{ pattern, name }`, and takes more. A holder that is not on it but
reads as a house ("Chelsea Publishing Company") is proposed as written, less
surely; an author's own copyright names no publisher.

An article's publisher is its journal. Where the house that puts the
journal out is known too (from the page's copyright line, from the record a
service gives, or because the book has it already), the journal goes after
it: `Elsevier: Journal of Algebra`. A society's own journal says whose it
is and stands alone, and an archive that only registers the articles (JSTOR)
is not named. `layouts.journal_join` is what stands between the two.

The four that read a date are there for the books with none. All but the
journal header are below the confidence at which a proposal replaces a value
(`propose_over = "sure"`), so they fill gaps and leave dates alone. A date
that calibre took from the file (the day a PDF was made, not the year the
book came out) is one they would correct: `:propose --over --only d FILTER`
proposes dates over what is there, for review. A layout of your own is a few lines in `init.lua`:

```lua
require("lulibre.layouts").add {
  name = "ams memoirs",
  marks = { "memoirs of the", "american mathematical society" },   -- all on one of the first pages
  fields = {
    series = "Memoirs of the American Mathematical Society",       -- a value as it stands
    series_index = "Number%s+(%d+)",                                -- a pattern: its capture is the value
    pubdate = "(%d%d%d%d)%s+%S*%s*Volume",
    publisher = function(text, doc) return "AMS" end,               -- or a function
  },
  confidence = 0.85,
}
```

`marks` are Lua patterns matched without regard to case; the page they are
all found on is the text the fields are read from. A series the series-page
layout does not know is one line:
`table.insert(require("lulibre.layouts").series, { "Astérisque", "Société Mathématique de France" })`. `:run candidates` shows
what every layout reads from the book under the cursor, which is the way to
try one out. This is a first pass: three layouts come with lulibre, and
books from one publisher and era are where more of them will pay.

## Known good records: `gk`

Every record has a score from 0 to 1 for how complete and clean it looks: a
title that reads as a title, an author that is a name, a date, a subject
that says what the book is about, identifiers. A file name for a title, a
title in capitals or full of figures and odd characters, an author that is
a list or a role, and a catch-all subject (`math/general`) pull it down.

`gk` (`:good`) lists the records by score, best first, with what holds each
down. The score only suggests; confirming is yours:

| Key | |
|---|---|
| `Space` | confirm the record as right, or take that back |
| `A` | confirm every record at or above a score (0.85 is a record with nothing visibly wrong) |
| `v` | show the records still to confirm, the confirmed ones, or all |
| `e` | edit the record |
| `L` | learn from the confirmed records (below) |

`:good add` and `:good remove` do the same for the selection, and
`&is:good` lists the confirmed records. Confirmed records are what lulibre
learns from, so that a mistake in an unchecked record is not taught back to
the rest.

## What marks a subject: `:learn` and `:terms`

`:learn` reads the indexed pages of every book and finds, for each subject,
the phrases of two and three words that its confirmed books use far more
than books of other subjects do: "modular forms" and "class field theory"
for number theory, "gradient descent" for computing. It takes a few seconds.
A phrase counts only if several of the subject's books use it, by at least
three different authors (so that one author's habits do not), and if it
also stands in some book's title, which keeps out cities, companies and
turns of speech. Text that many books share word for word (a publisher's
imprint, a series list) is set aside first. A book teaches its subject and
those above it; a catch-all subject teaches only the ones above it.

`:terms` shows what was learned, subject by subject, strongest first:

| Key | |
|---|---|
| `x` | drop the phrase: it will not be learned for that subject again |
| `a` | add a phrase of your own |
| `f` | narrow the list to the books whose pages hold the phrase |
| `d` | show the dropped ones |
| `L` | learn again |

When a book's pages hold at least two of a subject's phrases, the edit form
offers that subject for its tags, naming the phrases ("learned: modular
forms, elliptic curves"), never as surer than 0.6. This is a judgement from
a handful of phrases on a book's first pages and is often wrong; it is
there to be looked at, not trusted. `subject_learned = "propose"` makes
`:propose` use it too, `"off"` hides it.

In the edit form, subjects that say what a book is about are now listed
before catch-alls, however many books sit in the latter. The option
`subject_catchall` names more of them than the built-in ones (`general`,
`papers`, `books`, `handbook`, `misc`, `other`).

## Looking books up: `:enrich`

For books that have an identifier (in calibre already, or found in the
file), `:enrich` asks what the record says and proposes it:

| Service | Asked by | Gives |
|---|---|---|
| arXiv | arXiv number | title, authors, the day of submission, the subject its class stands for |
| CrossRef | DOI | title, authors, year; publisher and ISBN of a book |
| zbMATH Open | DOI or arXiv number | **the subject**, from the MSC codes each work is classified under by hand; the Zbl number |
| Open Library | ISBN | title, authors, publisher, year, series; the subject from the class it is shelved under |
| OpenAlex | DOI, when CrossRef has nothing | title, authors, date |

None of them needs an account or a key; there is nothing to sign up for.

    :enrich [filter]             the selection, or the books a filter matches
    :enrich --plan [filter]      say what would be asked of whom, and ask nothing
    :enrich --offline [filter]   only from what was fetched before: nothing is asked
    :enrich --titles [filter]    also search CrossRef by title for books with no identifier

Every answer is kept in the index, "there is no such record" included, so a
work is asked about once: a second run costs no requests, a run that was
stopped loses nothing, and `--offline` proposes again from what is kept
without touching the network. ("No such record" is believed for thirty
days, then asked again.)

### How the services are asked

lulibre is a guest of these services and asks as little as it can:

- **One request at a time to a service, and a pause after each**: five
  seconds for arXiv, two for zbMATH and Open Library, one for CrossRef and
  OpenAlex. Each is well inside what the service allows callers
  who do not say who they are (arXiv: one every three seconds; Open
  Library: one a second; CrossRef: five a second, one at a time; OpenAlex:
  ten a second; zbMATH: "a reasonable rate"). The time of the last request is kept in the index, so a
  second lulibre, or the same command run again at once, keeps to the same
  pace.
- **A slow answer is followed by a longer pause**: as long as the answer
  took, so a service under load is asked less (CrossRef asks for this).
- **Many works to a request** where the service takes them: forty papers
  for arXiv, twenty DOIs for CrossRef, twenty ISBNs for Open Library.
  (zbMATH is asked one work at a time; it has no way to ask for several.)
- **arXiv's rules are the strictest and are kept with room to spare.** Its
  [terms of use](https://info.arxiv.org/help/api/tou.html) allow "no more
  than one request every three seconds" on "a single connection at a
  time", and its [manual](https://info.arxiv.org/help/api/user-manual.html)
  asks that results be cached. A library with two hundred arXiv papers is
  five requests, once.
- **A service that says "too many requests" is left alone.** After an HTTP
  429 or 503 nothing is retried: the service is not asked again for half
  an hour (arXiv) or five minutes (the others), or for as long as it says
  if that is longer. The run goes on with the other services and says at
  the end who asked for a pause and until when; run it again later for the
  books that were left.
- **Nothing is asked twice.** A request that fails is not repeated in the
  same hour, and a batch that fails is not broken up into single requests.

`:enrich --plan` reads the identifiers and prints how many requests each
service would get and about how long the run would take.

### Databases kept here

Some of what the services know can be had whole, and then nothing is asked
of them:

    lulibre datasets                 says what there is, and asks which to fetch
    lulibre datasets list            only says
    lulibre datasets fetch NAME...   fetches these (or `all`); --force though they are fresh
    lulibre datasets add FILE...     takes up files you fetched yourself (they are linked, not copied)

| Dataset | Useful if you have | What it is | Size | Renewed |
|---|---|---|---|---|
| `arxiv` | arXiv preprints | arXiv's own snapshot: title, authors, classes, DOI and the day of each version of every paper. From Kaggle (`Cornell-University/arxiv`), fetched with Kaggle's program run through [pixi](https://pixi.sh) (`pixi exec kaggle`: nothing is installed); Kaggle wants an account, and its token in `~/.kaggle/` | 1.7 GB to fetch, 5.6 GB on disk | weekly |
| `openlibrary` | books with an ISBN | Open Library's monthly dumps of editions and authors: title, authors, publisher, year, series, shelf class | 9.7 GB | monthly |
| `zbmath` | arXiv preprints in mathematics | zbMATH's table of links to full texts (Zenodo, doi:10.5281/zenodo.8021789): the zbMATH number of an arXiv paper. It has no titles and no subjects: those are still asked of zbMATH | 37 MB | of June 2023 |

In the interface, `:datasets` picks one to fetch and fetches it behind.

They are kept in lulibre's data folder (`~/.local/share/lulibre`), beside
the index. A file there may be a link to one kept elsewhere, and fetching
then renews the file it points to. A fetch that stops half way leaves what
was there as it was, and running it again goes on from where it stopped.
What is here and as new as its source is left alone, so the command can be
run whenever.

`:enrich` uses whatever is here before it asks anybody:

- **arXiv papers** are read from the snapshot (ten seconds for its three
  million papers); arXiv is asked only about papers newer than the file.
- **Books with an ISBN** are looked for in Open Library's dump (a few
  minutes for its ten gigabytes, once: what the dump does not hold is not
  looked for in it again until the file changes); Open Library is asked
  only about the rest.
- **An arXiv paper's zbMATH number** is proposed as an identifier
  (`zbmath:5635019`).

A hypergraph of arXiv (papers as "edges", authors as "nodes"; one JSON
document over many lines, named `arxiv.json` in the data folder) is read
too, where there is no snapshot; it lacks the order of the authors, the DOI
and the day of submission.

From a hypergraph the authors come in no order, so they are put in the
order the paper's own first page names them in; where the page does not
name them all, the proposal says so and is not put over authors a book
already has. The day of submission is still read from the stamp arXiv
prints on the page.

What a record says is checked before it is believed:

- An arXiv number or DOI that calibre holds is taken at its word. One that
  was read from the file's pages may belong to a work the file cites: its
  record is left out unless the record's title is the book's title, or the
  title the file itself shows.
- Titles and names are held by arXiv as typed, TeX and all
  (`Erd\H{o}s`): they are put into plain text. A title with mathematics
  left in it fills a gap but is not put over a title that reads well.
- The same people named less fully ("S. Joffily" for "Sérgio Joffily") are
  not proposed; named more fully, they are.

`contact_email`, if you set it, is sent with each request: CrossRef and
Open Library allow more to callers they can reach. It is empty unless
you set it, and nothing else about you is sent. `enrich_services` says
which services are asked.

What the records say is proposed like anything else and decided in review.
A title or author from a record is taken as surer than one read from a
title page, so with `propose_over = "sure"` it is proposed over a value
that differs.

## What books cite: `:refs`

The index holds each file's first pages; a bibliography is on its last.
`:refs` reads those (the option `refs_pages`, 14 by default), finds the
heading the bibliography stands under ("References", "Bibliography", numbered
or not), cuts what follows into entries, by their numbering or by the
hanging indent, and gives each a key by which the same work is recognised in
another book's list however each writes it: a DOI or arXiv number where the
entry has one, else first author, year and first page.

    :refs                the selection
    :refs all            the whole library (a couple of thousand books take seconds)
    :refs --force ...    again, for books already read

Nothing is fetched: it is all read from the files, several at a time, and
each book is remembered, so a run can be stopped and taken up again.

Books that cite the same works are about the same thing. Once references
are read, the edit form offers for a book's tags the subject of the books
that share references with it ("shares references with 3 books of that
subject"), when at least two books each share at least two works with it.
A work that half the library cites counts for little, one that two books
cite for much. `lulibre.refs` gives scripts the lists and the coupling.

References also say something of who wrote a book. People cite
themselves, so a name read off a title page that also heads several
entries of the book's own bibliography is proposed with more confidence
("cited 4 times in its references"). And for a book with no author at all
the edit form lists, among its suggestions, who wrote the books that share
the most references with it: who writes on the same things, which is a
place to look and not an answer.

Finding the heading needs no more than the text: it is a short line that is
one of a few words and nothing else. Type size and position are there for
the asking (each line carries them) where a layout needs them.

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

### Beside the library: `gb`

`gb` (`:beside`) puts the sync folder in a column on the left and leaves the
library's list beside it. The list follows the file under the cursor: to
the book that is the very same file, when the library holds it already
(`= 26`), else narrowed to the books whose title, authors or tags hold the
longest words of the file's title, so that a copy under another name is
seen before it is added twice. The preview shows the waiting file; `Tab`
crosses to the library's list, and the preview then shows the book there.

| Key | |
|---|---|
| `S` | add the file to the library; it stays in the folder |
| `X` | add it, then delete it from the folder |
| `D` | drop it |
| `e` or Enter | edit what it will be added with |
| `r` | review the proposals waiting for it |
| `m` | have the library's list follow with look-alikes, or leave it be |
| `R` | read the folder again |

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
