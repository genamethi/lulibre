# Workflows

lulibre reads calibre's `metadata.db` and the book files directly, and never
writes to either itself. Every change goes to calibre through `calibredb`,
is recorded in a journal with the value it replaced, and can be undone with
`u`, or the whole library put back to a snapshot (`:rollback`).

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

### Mathematics in titles

Proposed titles write their mathematics in Unicode, as far as Unicode
goes: SL₂(ℤ), GLₙ(ℚₚ), 𝔽ₚ[T], ℤ/pᵃℤ, X³ − 5, ℓ-adic. A script Unicode
has no letter for is written `_q` or `^q` (𝔽_q), a longer one `_{…}`, and
TeX it cannot write at all (a fraction) keeps its dollars. Search is not
affected: in lulibre and in calibre, `SL2` finds SL₂(ℤ) and `Fp` finds 𝔽ₚ.

- From the pages: the PDF reader marks each line's mathematics from its
  fonts (a maths italic, a symbol or blackboard font) and from type set
  smaller and higher or lower (X³, GLₙ), so a title page gives back the
  scripts its plain text lost. A capital alone in bold inside a formula is
  a number system, as many authors write it (**Z** for ℤ).
- From TeX: arXiv and the like give titles as their authors typed them
  (`On $\mathbb{Z}_p$-extensions` becomes On ℤₚ-extensions).
- From plain text, a glossary changes only what reads one way: `SL2(Z)`,
  `GLn(Qp)`, `Fp[T]`, `Z/nZ`, `Rn`, `over Q`, `X3 −5`, `K0` in a K-theory
  title, `` `-adic ``. `F[t]` (any field), `R[t]` (any ring), `f(R)`,
  `Programming in R` and `A4` are left.

`:notation [filter]` proposes the selected books' titles that way, reading
each PDF's title page again where it gives the same title (books indexed
before this version have no marks kept), and the glossary otherwise. Title
case leaves formulas alone and keeps the word after one in lower case
(p-adic). `math_notation = "off"` proposes titles as found. The glossary
is a list of functions in `init.lua`'s reach:

```lua
local nt = require "lulibre.notation"
table.insert(nt.groups, "PU")          -- PU2 as PU₂
nt.glossary[#nt.glossary + 1] = function(s)        -- Spin3 as Spin₃
  return (s:gsub("%f[%w]Spin(%d)%f[%W]", function(n) return "Spin" .. nt.subscript(n) end))
end
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

A proposal under `propose_min` (60% by default) is kept but not shown:
review leaves it out, the counts of what waits leave it out, and every
summary ends by saying how many there are ("12 are under propose_min (60%)
and not shown"). Lower the option, in the configuration window or
init.lua, and they are shown at once. When another value is proposed for
the same field of a book, the ones not shown give way to it
(`propose_held = "keep"` keeps them all).

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

    :propose --over [filter]     as `any` for this run, and proposing again what was barred before
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

Rejecting a proposal (`r`) decides that proposal only: a later run may
propose the same value again. `N` rejects it for good: that value is not
proposed again for that book and field, unless `--over` asks. With the
option `review_reject = "always"`, `r` does what `N` does. In review, `A` (accept everything above a confidence) asks before it
includes proposals that replace a value.

`gr` lists the proposals book by book, with the current value beside each;
the list and preview follow the cursor, so the title page is in view.

**The pages' verdict.** Each proposal's row is marked with what the book's
own pages say of it, against what the book has now:

| Mark | |
|---|---|
| `●` | the pages show it, and not what the book has now (or the field is empty); or it is what the book has and more (a subtitle) |
| `=` | the pages show it, and what the book has now |
| `◐` | the pages show part of it |
| `·` | the pages cannot tell: no readable text, or a field they cannot settle (subjects) |
| `○` | the pages show neither it nor what the book has now |
| `✗` | the pages show what the book has now, and not this |

A title, authors, a series or a publisher is looked for on the opening
pages; a date by its year, where a book says when it is from (a copyright
line, arXiv's stamp); an identifier as the file's own, not one it cites.
Books whose proposals the pages bear out best come first, so what can be
accepted at a glance is at the top. `s` steps through the orders: best
borne out, surest (by the sources' confidence), most disputed, by id (the
option `review_sort` sets which it starts in). Replace
`require("lulibre.ui.review").marks` in init.lua to mark them otherwise.

Review, duplicates and orphans bring themselves up to date when the library
changes under them: a book removed with `:remove` leaves the panel.

| Key | |
|---|---|
| `a` `r` | accept, reject; on a book's own line, all of that book's proposals |
| `N` | reject, and never propose that value for that field of the book again |
| `e` | correct the proposed value, then accept it |
| `x` · `X` | show this book's other fields under its proposals · for every book |
| `e` on a shown field | edit it in the same pass; it becomes an accepted proposal |
| `A` | accept everything at or above a confidence |
| `R` | reject everything still pending |
| `c` | propose blanking the field |
| `t` | put the value in title case, and accept that |
| `s` | sort: best borne out by the pages, surest, most disputed, by id |
| `f` then a letter | only one field's proposals: `t` title, `a` authors, `s` subject, `i` identifiers, `d` date, `p` publisher; `f` `f` shows all again. Accept-all and reject-rest then speak for that field alone |
| `p` | more preview: shrink the panel, and again to bring it back |
| `l` `h` | the next view, the one before (the tabs in the bar; a click on one works too) |
| `D` | drop what the view in front holds: deleted, not rejected, so it can be proposed again |
| `w` | write the accepted ones as one batch |
| `o` | the next source's proposal for this field (one row per field) |
| `O` | for this field, the next kind of source (CrossRef, Open Library, the title page, ...) in every book that has one |
| `m` | one row per field, or every proposal a row of its own |
| `i` | show or hide, where the list is, what the proposal under the cursor rests on |

**One row per field.** A title, the authors, a date, a publisher or a
series holds one value, so the proposals for it are alternatives. Review
shows one of them, the surest, with `2/3` before its source when there are
others; `o` steps to the next, and `O` shows the same kind of source for
that field throughout the view, so you can look at all the titles CrossRef
gave, then all those the title pages gave. Accepting takes the one shown.
`m` (or the option `review_rows = "all"`) shows every proposal on a row of
its own instead. Subjects and identifiers that are added or taken off are
not alternatives and always have a row each.

**What a proposal rests on.** While review is open, the place where the list
was shows the proposal under the cursor: where it came from and how sure,
the pages' verdict in words, what the book's own pages say of it (and of
the value it would replace),
the record behind it (for an identifier, the record that identifier leads
to: what taking it would bring), with that record's title, people, date,
type, length and identifiers and how they stand against the pages, and the
other sources' values for the field. `i` hides it and brings it back; the
option `review_context = 0` starts without it. To show something else
there, replace `require("lulibre.ui.review").context` in init.lua: it is
given the proposal and the others for its field and returns rows.

`:review FILTER` keeps the review to the books a filter matches
(`:review author:unknown`); `w` then writes only theirs.

#### Runs, and review's tabs

Each go of proposing is a *run*: `gp`, `:propose`, `:enrich`, and the
dialog below, which is one run however many steps it takes. While a run is
going on the status line carries a badge beside the mode, in the warning
colour:

     NORMAL  ⟳ PROPOSING  280 books: records, step 2 of 2

and nothing tells you to open review until it is done. Review shows the
runs as tabs in its bar, the one in view standing out:

     review  13 pending, 0 accepted   best borne out first   09:41 · 4 books (13)   all waiting (1140)

| Tab | Holds |
|---|---|
| `09:41 · 4 books (13)` | everything that waits for the books of the run begun at 09:41, whether that run proposed it or it waited before |
| `⟳ 09:50 · 280 books (96)` | a run still going on: what it has found so far. The view comes up by itself when the run is done |
| `all waiting (1140)` | every proposal that waits |

`gr` opens on a run that is going on or that you have not looked at yet,
and otherwise on everything; a "propose, then review" from the dialog
brings its own run up when it is done, in the review that is open if one
is, so two reviews never lie on top of each other. The first line of a
run's view says what it is and which keys act on it. `D` there drops what
*that run added* and leaves what waited before; on a run still going on it
stops the run first. A run is forgotten when nothing waits for its books
any more, or when a later run covers the same books.

All of this is Lua and yours to change, in `init.lua`:

    local runs = require "lulibre.runs"
    runs.badge = function(run) return "busy: " .. (run.step or ""), "accent" end  -- other words, another colour
    runs.badge = function() end                                -- no badge
    require("lulibre.ui.review").banner = function() end       -- no line at the top of a run's view
    lulibre.map("review", "<C-n>", "next_view")                -- another key for the next tab

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

### Propose, then review, from one dialog: `<Leader>pr`

`\pr` (`:propose-review`) opens a dialog that puts the whole round in one
place and in order:

| Part | What it sets |
|---|---|
| Which books | what is selected, everything the list shows, or the whole library |
| What is asked | the files themselves; the records kept on this machine; the services; CrossRef by title; the bibliographies first; subjects from shared references and from learned phrases; whether the sources are weighed |
| Which fields | a box for each: title, authors, subject, date, publisher, series, identifiers |
| What is there already | as `propose_over` says, only gaps, or over whatever differs; as if the fields were empty; drop the proposals already waiting for these books |
| Then, in review | accept by itself what is at or above a confidence (never over a value a book has); show nothing below a confidence; the order of the books |

A line that cannot be used is greyed and says why ("nothing learned yet:
confirm records with gk, then :learn"). `Space` ticks a box or steps
through a choice, Enter types a value, `w` (or Enter on the last lines)
goes. Everything it does can also be done by hand with `:propose`,
`:enrich`, `:refs` and `:review` and their flags.

The whole round is one run (see "Runs, and review's tabs" above): the
status line says which step it is at, the steps keep their closing lines
for the log, and when it is done review opens on that run's tab.

### Other dialogs

The same kind of pane stands in front of a few more things, each saying
what will happen before it does:

| Key | Dialog |
|---|---|
| `\e` | **Look up** the selection: how many works each service would be asked about and in how many requests (nothing is asked to find out), a box for each service, then "ask, then review" or "ask nobody: propose from what is kept here" |
| `\c` | **Change at once**: add or remove a subject, or set the authors, series, publisher, date or language, for every selected book (the books under a heading, the marked ones). Empty lines change nothing; one undo takes it all back |
| `\d` | **Databases** kept on this machine: what is here, how old, and a box for each to fetch |
| `\s` | In the sync folder, **the waiting files that are selected**: which are new and which the library holds, and a choice of add, add and remove, or drop |

`\` then `Space` unmarks every book (`:mark none`).

### How far the sources agree

A book is described by several sources at once: its title page, a
cataloguing block, the data inside the file, an arXiv record. Where two of
them speak of the same field they should agree. lulibre measures how far
apart two values of a field are (titles by their words, authors by their
family names, dates by their years, subjects by how near they are in the
tree) and, for each field of a book:

- the **value** most of the weight is behind;
- how many sources **agree** on it, shown in review beside the source:
  `title page 0.55  [2/3]`;
- the **disagreement**: 0 when every source says the same, towards 1 when
  they say unrelated things. `s` in review puts the books whose sources
  disagree most first: where a look is most needed.

### How much each source is believed

`:weigh` measures every kind of source against the library as it stands:
of the times the title page gave a title for a book whose title is worth
trusting, how often was it that title? `:weights` (`\w`) shows the table,
and any line of it can be set by hand (Enter) or given back to the
measurement (`x`). `:weigh good` measures against the records you have
confirmed (`gk`) only, which is the better measure once there are a few
dozen: a field the library itself has wrong for many books (dates taken
from the files, say) makes the sources that are right look bad.

With the option `weigh_sources = "on"` (or its box in the dialog) a
proposal's confidence is no longer what its rule claims but what the
sources that agree on it come to, each taken for what it was measured to be
worth. It is off unless you turn it on.

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
| arXiv stamp | the day of submission, from a first version's stamp only: a later version's stamp gives the day of that revision, and is not taken for a date |
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

With `learned_tags = "suggest"`, when a book's pages hold at least two of a
subject's phrases, the edit form offers that subject for its tags, naming
the phrases ("learned: modular forms, elliptic curves"), never as surer
than 0.3. This is a judgement from a handful of phrases on a book's first
pages and has been wrong more often than right; it is off unless you turn
it on. `learned_tags = "propose"` makes `:propose` use it too; such a
proposal is shown when it reaches `learned_tags_min` (20%), in place of
`propose_min`.

`:run holdout` says how well this does on the library as it stands. The
confirmed records are cut into five parts; each part in turn is left out,
the phrases are learned from the other four, and the subject of every book
left out is asked for and held against the tags it has. It reports how
often a subject was said and how often that was one of the book's, by
subject and by how many phrases the book had, and `--wrong` names the
books it missed with the phrases that misled it. Nothing is kept or
changed, and it takes a few seconds. `:run holdout 10` cuts into ten.

Read it for what it is. A book has several subjects and its tags name one
or two, so "not among its tags" is sometimes a subject the book should
have; and a few dozen confirmed books for a subject are few. It is for
seeing whether something you changed (more records confirmed, a phrase
dropped in `:terms`, a threshold in `lulibre.learn`) made it better or
worse.

Phrases that say how a book was published ("editorial board", "graduate
texts", "mathematics subject classification") are never learned as a
subject's; `require("lulibre.learn").FURNITURE["lecture notes"] = true` in
`init.lua` adds one.

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

#### Is the record this book's?

An identifier can be wrong: a DOI read off a reference list, a chapter's
or a review's DOI, the ISBN of the whole volume a chapter is from. So a
record is checked against the book before anything from it is proposed,
whether the identifier was read from the file or the library holds it:

| The record | |
|---|---|
| has the book's title, or its title stands word for word in the opening of the file, or is the book's title with a subtitle | is the book's |
| is only like it (a title cut short, most of the words) | is the book's unless the authors differ: a review "..., by Sutton and Barto" is not the book |
| has another title, but an author in common | is taken, without its title being pressed (0.5): another form of the title, or the volume this is part of |
| has another title and no author in common | is left out; what it proposed before is withdrawn; and if the library holds the identifier, taking it off is proposed (0.6) |
| says what the book's pages contradict, as read by rule (a cataloguing block, a copyright line, a series page, a cover sheet, a journal header, an arXiv stamp, a grammar): a year earlier than the one they print, or a publisher that is not theirs nor its imprint nor its journal | is left out, the same way, and says why; an ISBN the pages do not print is proposed to be taken off. Where the pages state nothing of the kind, the record is not held to them |

What was left out is listed in the log (`:messages`), and on the terminal
by `lulibre enrich`. Even from a record that is the book's, a value that
is plainly worse than the one the book has is offered at 0.6 or less,
which means only into an empty field or when `--over` asks: a title with
words left out ("Extending Python" for "Extending and Embedding Python"),
authors with none of the book's names, or fewer of them.

A search by title is the weakest of these, because a search always answers
with something. The record is taken only when it is plainly the same work:

| The titles | The authors | Offered at |
|---|---|---|
| the same telling words | one family name in common | 0.90 |
| the same telling words, four or more | the book has none | 0.80 |
| one is the other with something after it (a subtitle, the author's name run on), four words or more shared | in common · the book has none | 0.85 · 0.70 |
| three telling words or fewer ("Algebraic Geometry") | the book has none | not taken |
| anything | both have authors, no name in common | not taken |

"Telling words" leaves out *the, of, and, to* and their like; "An
introduction to the ipaddress module" and "An Introduction to Module
Theory" share two of three and are not the same title. Until 0.2.0-alpha.1
they counted as one, and such records were offered at 0.95. `:run unmatch`
lists the matches made that way which no longer hold; `:run unmatch --fix`
withdraws what still waits from them and proposes putting back what the
books said before, as a run of its own in review ("wrong title matches").
It asks no service anything: the answers were kept.

#### The file decides

A record is somebody's word that the file is a certain work; the file is
the one witness that cannot be about another work. So before anything is
offered, the record is also held against the book's own pages
(`lulibre.verify`):

| The book's pages | |
|---|---|
| show neither the record's title nor any of its people | the record is another work's: left out, as above |
| are much shorter than the edition the record describes (a 40-page file, a 404-page book), or the record is of a whole book and the pages do not show its title | the file is a **part** of that work (a chapter of a handbook): the record's title, people and identifiers are the whole's and are not offered; its publisher and year are |
| do not show the record's title | its title is not offered |
| show only some of its words, or name only some of its people | that value is offered at 0.6 or less |
| could not be read (no text, a scan, garbled characters) | everything is offered 0.2 lower: nothing could be checked |

A title found by searching for it must stand on the pages, or the record
is not taken. Words are compared folded (case and accents gone), with what
TeX leaves beside a letter ("Universit´e") joined up, and figures and
daggers beside a name ("Chamseddine1,3", "Joyner†") apart from it.

A file's own metadata counts too. Publishers put a work's DOI in the PDF's
XMP packet (`prism:doi`, `dc:identifier`), some in its Info dictionary; an
EPUB names its ISBN in its package. Those are offered (0.9) as the file's
own, ahead of a DOI read off the pages, which may be a cited work's. An
arXiv DOI (`10.48550/arXiv....`) is taken as the arXiv number.

### Checking the library against its files: `:verify` and `:run recheck`

`:verify [filter]` holds every book against its own file and changes
nothing: whether the opening pages show its title, name its authors, and
where each DOI, ISBN and arXiv number it holds stands (named in the file's
metadata, on the opening pages, further in, only in its reference list, or
nowhere). `--list title|authors|ids|unread` names every book of one kind.

`:run recheck` goes back over what lulibre has written, with the file
deciding:

- a title a catalogue's record put there goes back to what the book had
  before, when the pages read that one better (more of it, in order); for
  a title from anywhere else, only when the old one stands in the largest
  type of the first pages and the new one hardly stands there at all. A
  name run on to the old title ("Noncommutative Geometry Alain") is taken
  off; junk and headings any file may have ("Front Matter") are never put
  back;
- authors go back when the pages name none of those there now and some of
  those before;
- a DOI, ISBN or arXiv number it added comes off when it stands only in
  the reference list, or its record is plainly another work's; one it took
  off that the file's own metadata names goes back on.

Values you typed are left alone, and so are changes made outside lulibre
and books whose file could not be read.

    :run recheck [--list] [filter]   say what would change
    :run recheck --propose           put it in review, as a run
    :run recheck --apply             change it now, after taking a snapshot
    :run recheck --since SNAP        only what was written after a snapshot

`--apply` also withdraws what still waits from `:run unmatch --fix`: this
settles the same books, with the file to go by.

### arXiv numbers by title, on this machine: `:run arxiv-titles`

With arXiv's own snapshot kept here (`:datasets`), `:run arxiv-titles
[filter]` looks every book with no arXiv number up by its title (and by
the part before a colon), in one pass through the file and asking nobody.
A paper with the same title is taken only when the book's pages show that
title and name its people; its number is then proposed, and `:enrich
--offline` proposes the rest of its record. It takes a minute or so.

### Works no catalogue has: `:noncatalog`

A handout, the notes of a course, a chapter of the Stacks project, a page
saved from the web: no catalogue has a record of these. Such a work has no
DOI and no ISBN of its own, so one in its pages is that of a work it
cites, and a record found by searching for its title is somebody else's.
Marking it says so once:

| | |
|---|---|
| `:noncatalog add` | mark the selection |
| `:noncatalog remove` | take the mark back |
| `:noncatalog` | list the marked books (the filter `is:noncatalog`) |

For a marked book:

- a DOI or ISBN in its pages is not offered as its own;
- `:enrich` does not look it up by DOI or ISBN, nor search for it by
  title. An arXiv number is still followed: arXiv is where such works
  are kept;
- having no identifiers does not count against it in `:good`, and
  `lulibre stats` counts it apart;
- when it is marked, what waits for it from CrossRef, Open Library,
  OpenAlex and zbMATH is withdrawn, and taking off a DOI or ISBN it holds
  is proposed (at 0.8, for review like anything else).

To mark many at once, filter to them, select them all and `:noncatalog
add`: `author:"keith conrad"`, say. Look at what the filter caught first:
`author:conrad` also finds Brian Conrad's book with Springer, which has an
ISBN and should keep it. A removal you did not expect in review is the
sign of a book marked by mistake.

The mark is lulibre's own, kept in its index. Nothing is written to
calibre for it.

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

## Grammars of publications: `:run grammars`

Some kinds of document always open the same way. Keith Conrad's handouts put
the title in capitals with KEITH CONRAD, smaller, under it; a chapter of the
Stacks project its name in capitals, then its tag ("01H8") or its contents;
a Springer chapter its number and title in very large type; a chapter of
Elsevier's Handbook of Algebra carries a DOI that says its volume and its
place in it. A *grammar* says what a kind of document's opening lines look
like, line by line (their text, the size of their type, capitals, bold),
and what follows when they do.

    :run grammars [filter]           what each grammar finds; nothing is changed
    :run grammars --apply [filter]   keep the parts and the non-catalog marks

What a grammar says of a title or authors is proposed by `:propose`, like
what the title page says (source `grammar: keith-conrad`). Conrad's
handouts and the Stacks project's chapters are marked non-catalog by
`--apply`.

**Parts of a whole.** A grammar may say which whole a file is a part of, its
number in it and how many there are; so may a record much longer than the
file. These are custom fields (below): `#partof`, `#part`, `#parts`.
`is:part` finds such books, and `:parts` lists each whole with its parts in
order and the numbers missing. For the Stacks project the order is the one
its Makefile gives: a book holding the table "Chapters in reading order"
(`| # | Chapter | Pages | PDF |`) is read for it.

Your own grammars go in init.lua or a module:

```lua
local G = require "lulibre.grammars"
G.add {
  name = "my-seminar",
  kind = "seminar notes",
  noncatalog = true,
  lines = {
    G.line { pattern = "^Seminar on (.+)$", take = "series" },
    G.skip(2),                                    -- up to two lines between
    G.line { upper = true, bigger = true, take = "title", case = "title" },
    G.opt(G.line { smaller = true, take = "authors" }),
  },
  confidence = 0.9,
}
```

A line rule may ask for `pattern` (`nocase = true`), `upper`, `bold`,
`bigger` or `smaller` (than the page's body type), `largest`, or `size = {
min, max }`; it may `take` a field (the line, or the pattern's capture;
`case = "title"`) or `give` fixed values. `G.skip(n)`, `G.opt(rule)` and
`G.either{ ... }` join rules; `text = { patterns }` and `pages = { min, max
}` ask things of the whole file, and `read(doc, got)` can work out more (or
return false to say no after all).

With LPeg installed for lulibre's Lua (`:features` says), a line rule may
give `peg = PATTERN` in place of `pattern`, and a grammar may give one LPeg
pattern over its opening lines joined by newlines (`head` of them, 12 by
default); a table capture (`lpeg.Ct` with named `lpeg.Cg`) gives fields:

```lua
local lpeg = G.lpeg()            -- nil and why, when LPeg is not there
local C, Cg, Ct, P, R, S = lpeg.C, lpeg.Cg, lpeg.Ct, lpeg.P, lpeg.R, lpeg.S
G.add { name = "caps-then-names",
  peg = Ct(Cg(C((R"AZ" + S" '-:,")^3), "title") * P"\n" * Cg(C((1 - P"\n")^1), "authors")) }
```

## Custom fields: `:custom`

calibre has the fields it has. Metadata of your own goes beside them, in a
database of lulibre's own (`<index>.custom.db`, beside the index): calibre's
database is never changed for it, and building the index again loses
nothing. A field is named as calibre names a custom column (`#partof`), so
it could become one later.

    :custom                          the fields, what they are, how many books have each
    :custom add NAME [type] [help]   declare one: text (the default), number, date or list
    :custom set NAME VALUE           set it for the selection (an empty value removes it)

Otherwise a custom field is a field like the others: it is in the edit form
(`e`), it can be proposed and reviewed, it is written through the same path
(so it is in the journal, and undo, snapshots and rollbacks take it back),
the preview shows it under the book's identifiers, and filters find it:

    #partof:handbook     #part:3     #part:none     has:#partof     no:#series2

lulibre's own: `#partof`, `#part`, `#parts` (parts of a whole). Scripts read
and write them through `lulibre.custom` and `lulibre.apply`.

### In calibre too

A field can be a calibre custom column as well, of the same name. lulibre
keeps its values as before, and every change to the field is written to
calibre's column too.

    :custom column add NAME [heading]   ask calibre for the column
    :custom column remove NAME         take a column out of calibre (any of calibre's); lulibre keeps its values
    :custom push NAME                  copy lulibre's values into it, where calibre's differ
    :run columns                     the columns for #partof, #part, #parts (an example script)

calibre makes a column only while the content server is stopped, so the
column waits (below) and lulibre asks: restart now, or not now. Until it is
there, and wherever calibre's value is not lulibre's, the preview says so
under the book's custom fields (`not in calibre: #note (lulibre only),
#partof (calibre: …)`), and `:custom` says it of each field: lulibre only,
waits for a restart, calibre too, or how many books differ.

### Changes that wait for the server to be stopped: `:offline`

Some of calibredb's commands refuse the content server: they work on the
library folder, while nothing else has it open.

| Command | What it does |
|---|---|
| `add_custom_column` | adds a column to calibre's database |
| `remove_custom_column` | removes one, and its values |
| `restore_database` | rebuilds `metadata.db` from the `metadata.opf` kept in each book's folder |
| `check_library` | vacuums the database, then reports what disagrees between it and the folders |
| `backup_metadata` | writes the `metadata.opf` of each book changed since its last one |
| `catalog` | writes a catalogue of the library (CSV, BibTeX, EPUB …) |

A book's `metadata.opf` is written by calibre's own code only: a change
made through calibredb or the content server just marks the book. Each time
the server is stopped, lulibre has calibre write them (`backup_metadata`,
on), before anything else, so that `restore_database` would have them right
(see "The opf files" below).

lulibre queues them (in the history file beside the index) and does them
the next time the server is stopped. They are done the same way whatever
stopped it:

- `lulibre.service`, run before each start of the server's systemd unit:
  set `server_hook = "on"` and lulibre installs and enables it for the unit
  that runs your server (see "lulibre's systemd units" below).
- "restart now": lulibre stops the server with the option `server_stop`,
  does them, and starts it with `server_start`
  (`systemctl --user stop calibre-server`, `… start …`).
- by hand, while the server is down: `lulibre offline`.

With `server_restart_at = "03:30"` (a time of day), lulibre also has
systemd restart the server every day at that time, so that what
`lulibre.service` does is done at least daily.

With both `lulibre.service` and the "restart now" options set up, a
restart from lulibre makes one copy of calibre's database, not two: the
service, set off by the restart's start of the server, leaves the copy and
the opf files to the restart.

What lulibre offers when a change is queued depends on what has the library
open: nothing (no content server, or it is stopped) — do it now; calibre's
program — it waits until the program is closed; the content server —
restart it now, or not now.

      :offline                 what waits, and what failed
      :offline restart         restart the server for them now
      :offline cancel ID
      lulibre offline [list | cancel ID]

A job that fails is tried again the next time; `:offline cancel` drops it.

### Copies of calibre's database: `:backup`

Before the server starts (whichever of the three above starts it), lulibre
copies `metadata.db` and calibre's preferences beside it to
`~/.local/share/lulibre/backups/<the index's name>/`, one folder per copy,
as `backup_restart` says:

| `backup_restart` | |
|---|---|
| `always` | every start (the default) |
| `next` | the next start only; then not again until it is set to `next` again |
| `never` | only when asked |
| a number | when the newest copy is that many days old |

The newest `backup_keep` (5) are kept. The first change to the library in a
session, with the newest copy older than `backup_max_age` days (7), offers
one in a popup (`backup_too_old = false`: no popup).

    :backup                    the copies, and when they are made
    :backup now [why]          one now (the server may be running)
    :backup check              calibre's database: is it whole?
    :backup compare N          what putting copy N back would change (1 is the newest)
    :backup restore N          put copy N back
    :backup next               or always, never, DAYS: set backup_restart (and in init.lua)
    :backup prune [keep]
    lulibre backup ...         the same, with no interface (restore asks for --yes)

**Is it whole?** `:backup check` is SQLite's integrity check of
`metadata.db`, read only, so the server may run. Each copy is checked as it
is made, and the list marks one that fails (`FAILED`). The copy is the
database page for page, so a copy that fails means calibre's database
fails too. When calibre's database is damaged, lulibre still starts: it
warns, and goes on with the library as it last read it, so that a copy can
be put back. Pruning never removes the newest copy that passed its check,
so copying a damaged database again and again doesn't push out the last
good copy.

**Putting a copy back.** There are two ways back from a damaged database,
or from a change you want undone across the whole library:

- one of lulibre's copies (`:backup restore N`): everything calibre had at
  that moment;
- calibre's `restore_database`, which rebuilds the database from the books'
  `metadata.opf` files: only as current as those files (see "The opf files"
  below for who writes them in your setup).

`:backup restore N` first shows what the copy differs in, against
calibre's database as it is now:

- **books removed since:** their records come back. Their files don't,
  if calibre moved them to its trash. Bring those back with calibre's
  program first: calibre can't once the copy has their records.
- **books added since:** their records go, and their folders stay;
  `:orphans` finds them.
- **books changed since:** back as they were, with how many differ in each
  field lulibre reads. calibre's last-modified time says which books changed,
  so a book changed only in its comments, a custom column or its cover is
  counted, but no field is named.
- **folders renamed since:** a new title or author renames a book's folder.
  The copy's record names the old folder, so the record is pointed at the
  folder as it is now.

Then it asks. The copy goes back once nothing has the library open, like a
new column (`:offline`): restart the server now, or at its next start.
Before anything is changed, calibre's database as it is goes into a copy
of its own; put that one back to undo the restore. lulibre fits the copy,
in a staged file of its own, to the library folder as it is now:

- the renamed folders, as above;
- each book that differs is marked, so that calibre writes its
  `metadata.opf` again;
- no book gets an ID that a book added since had (its folder, `Title (id)`,
  is still there).

Then the staged file goes in through SQLite's own backup. If the
database is too damaged for that, the staged file takes its place.
Nothing else in the library folder is touched.

### The opf files

calibre keeps a copy of each book's record in its folder, `metadata.opf`.
It reads them when it rebuilds its database (`restore_database`) and when it
brings a book back from its recycle bin, so they are worth keeping current.
Only calibre's own code writes them, and only some of calibre's programs do:

| What runs | Who writes the opf files |
|---|---|
| calibre's program | the program, a changed book every few seconds |
| calibre's content server, started through lulibre's launcher | calibre's same writer, in the server |
| calibre's content server, as calibre documents it | nothing while it runs: changes are only marked; calibre writes them each time the server is stopped (`lulibre offline`, which `lulibre.service` runs before each start) |
| nothing | calibre (`backup_metadata`), right after lulibre changes the library in its folder |

(The option `backup_metadata`, on by default, is what has lulibre ask
calibre for them at those times.)

While calibre's program is open, whatever lulibre would do that the program
could be doing too waits: a change straight to the library's folder, a file
set aside from a book's folder, the changes queued for a stopped server. The
status line says so, and lulibre goes on once the program is closed.

lulibre never writes one. Its launcher, `contrib/calibre-server-opf.py`
(installed in `<prefix>/share/lulibre/contrib/`), starts calibre's content
server with calibre's own Python and starts in it the thread calibre's
program runs to write them: one process serves the library, renames its
book folders and writes its opf files, as in the program. It takes the same
arguments as `calibre-server`, after `--`:

    /opt/calibre/calibre-debug -e /usr/local/share/lulibre/contrib/calibre-server-opf.py -- [calibre-server options] LIBRARY

For a systemd unit that runs `calibre-server` (the one calibre's manual
gives, at <https://manual.calibre-ebook.com/server.html>, or your own),
set `opf_writer = "server"`: lulibre adds a drop-in to the unit,
`<unit>.d/lulibre-opf-writer.conf`, which replaces its ExecStart with the
launcher's; the unit's own file is left as it is (see "lulibre's systemd
units" below). A unit with sandboxing or hardening settings
(`ProtectSystem`, `ReadOnlyPaths`, `NoNewPrivileges` ...) is not given it:
the drop-in is shown instead. With such settings the service must still be
able to read the launcher and run `calibre-debug`; the status file below is
optional. `lulibre` ships calibre's manual's unit so changed, in
`<prefix>/share/lulibre/systemd/calibre-server.service`, for a new setup.

Started some other way (an OpenRC or runit service, a script, a
container's command)? Replace `calibre-server ARGS` with
`calibre-debug -e <the launcher> -- ARGS`, using the calibre-debug of the
same calibre.

The launcher writes `~/.local/state/lulibre/calibre-server.json` while it
runs: lulibre reads it to know that the files are being kept current, and
`:backup` says who keeps them so and how many books' files are behind their
record. **It relies on calibre's internals**, not on anything calibre
promises: after a calibre update, see that the server's log has `lulibre
opf: calibre metadata backup running`. If calibre has changed what it
relies on, the server is started without the thread (the library stays
reachable), the log and the status file say why, and `:backup` shows it; with
`LULIBRE_OPF_REQUIRED=1` in the unit's environment the server does not start
at all instead.

### lulibre's systemd units

Three options say what lulibre adds around the systemd unit that runs
calibre's content server, and lulibre keeps the units as they say:

| Option | What lulibre installs |
|---|---|
| `server_hook = "on"` | `lulibre.service`, run before each start of the server's unit (`lulibre offline`), enabled for it |
| `opf_writer = "server"` | the drop-in `<unit>.d/lulibre-opf-writer.conf`: the server started through the launcher, with calibre's opf writer in it |
| `server_restart_at = "HH:MM"` | `lulibre-restart.timer` and `lulibre-restart.service`: the server restarted every day at that time |

Set one off (or back to its default) and what it installed goes. The unit
is found from the calibre-server running now, else from the unit files
that start one (`~/.config/systemd/user/`, `~/.local/share/systemd/user/`,
`/etc/systemd/system/`).

- A user unit: lulibre writes the files and runs `systemctl --user` itself,
  when the interface starts and when one of the options is changed in the
  configuration window (it offers to restart the server when the drop-in
  changed).
- A system unit: lulibre writes the files with sudo, in the terminal, after
  asking: when one of the options is changed in the configuration window,
  or with `lulibre units apply`. `lulibre.service` then runs as the
  server's `User=` (or yours).
- Started some other way (an OpenRC or runit service, a script, a
  container)? Nothing is installed: run `lulibre offline` before each start
  of the server, and start the server through the launcher as above.

      lulibre units            what the options ask for, and what would change
      lulibre units apply      make it
      :units [apply]

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

Set `lulibre.o.sync_dir` to a folder where files arrive. The tab line along
the top then has `2 Sync folder` between `1 Library` and `3 Configuration`,
with how many each holds and which the list is showing. `2` (or `gS`, or a click on the tab)
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

Some folders under the sync folder mean something. A file added from
`non-catalog/` is marked as a work no catalogue has (`:noncatalog`), one
from `good/` as a record known to be right (`gk`). `unsynced/` is where a
rollback puts books it takes back out of the library (`--unsync`, below);
files there are not waiting to be added.

### Beside the library: `gb`

`gb` (`:beside`) puts the sync folder in a column on the left and leaves the
library's list beside it. The list follows the file under the cursor: to
the book that is the very same file, when the library holds it already
(`= 26`), else narrowed to the books whose title, authors or tags hold the
longest words of the file's title, so that a copy under another name is
seen before it is added twice. The preview shows the waiting file; `Esc`
crosses to the library's list, and the preview then shows the book there
(`Tab` comes back).

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

## OCR, and text that came out garbled

    :ocr [filter]                tesseract, for books with no usable text layer
    lulibre ocr 'is:needsocr'

`lulibre.o.ocr = "auto"` runs it after indexing for files that need it. OCR
reads the first `ocr_pages` pages into lulibre's index; the file itself is
left alone, unless:

| `ocr_write` | |
|---|---|
| `off` (default) | the PDF stays as it is |
| `replace` | each PDF read is also given a text layer with `ocrmypdf` (every page; it takes a while), and the new PDF takes the old one's place in calibre |
| `keep` | the same, and the old PDF is first copied to `ocr_originals`, a folder outside the library (default `~/.local/share/lulibre/ocr-originals/`), so that calibre never holds two copies. One inside the library is refused |

`:ocr --write [filter]` does only that part. Each PDF replaced is in the
journal, and `u` puts a kept original back.

**Garbled text.** Some PDFs set their text in fonts that say nothing of which
letter each glyph is: what comes out is `�` (U+FFFD), private-use
characters, or letters moved along ("zkdw dvvxpswlrqv" for "what
assumptions"). Each file keeps the share of such characters (a long run of
them, such as the dots leading to a page number in a table of contents,
counts once), and `is:needsocr` takes a file with more than 4% of them, or
with almost no text. (Mathematics set in fonts with its symbols in the
private-use area comes to 2 or 3%, and is left alone.) `:run reread [filter]`
reads those pages again:

1. with poppler's `pdftotext`, a reader of its own that maps many such fonts
   where MuPDF does not; its line boxes are kept, so the title page can still
   be told by the size of its type. A page is replaced only when the new
   reading is readable and better;
2. by moving the characters back, when one shift turns the file's longer
   pages into English (they must agree on it);

and names the books that still need OCR. `text_fallback = "off"` leaves
poppler out.

## Features and the programs they need

lulibre runs without any of these; each is looked for when the feature that
needs it is used, and `:features` says which are installed and on.

| Feature | Programs | For |
|---|---|---|
| poppler | `pdftotext` | `:run reread` (`text_fallback`) |
| tesseract | `tesseract` | `:ocr` (`ocr`) |
| ocrmypdf | `ocrmypdf` | giving PDFs a text layer (`ocr_write`) |
| lpeg | the Lua module `lpeg` (a rock) | grammars written with LPeg patterns |

When one is missing, lulibre says how to install it. With `pixi_deps = "on"`
it can also keep an environment of its own with pixi (under
`~/.local/share/lulibre/pixi`) and offers to add the program there, asking
first. That is off by default, since it means running what pixi fetches.

Scripts may need Lua modules: `rocks_tree` names a luarocks tree whose modules
`require` finds (before the usual places), and with `rocks_install = "on"`, `lulibre.require_rock(module
[, rock])` offers to install a missing one there (off by default, for the same
reason).

A C module (a `.so`) built for another Lua than lulibre's crashes whatever
loads it: a `lua.h` of another version earlier on the compiler's include
path (`/usr/local/include` comes before `/usr/include`) is enough to cause
it. So lulibre loads each C module once in a child process first, and
refuses one that does not survive that, saying so, instead of going down
with it. (Rebuild such a module against the right headers:
`luarocks --lua-version 5.5 install lpeg LUA_INCDIR=/usr/local/include/lua/5.5`.)

## Without the content server

`lulibre.o.write_via` chooses the route: `"server"`, `"direct"` (straight to
the library folder, which calibre permits only while none of its programs
has the library open), or `"auto"`, the default: the server when it answers,
else direct.

## Snapshots: `:snapshot`, `:rollback`

The journal of changes is kept in a file of its own beside the index
(`<index>.history.db`), so that rebuilding or deleting the index never
loses it. It holds every field lulibre wrote with the value it replaced,
every book it removed, added from the sync folder, put back or dropped, and
also the changes made to calibre by other means (its own window, the
content server, another program): those are found by comparing the books
with how they were the last time lulibre looked, and logged as one batch
labelled `outside` when the next change is logged.

A snapshot is a place in that journal; no copy of the library is made.

| Command | |
|---|---|
| `:snapshot [NAME]` | take one now (named by the time without a name) |
| `:snapshots [--all]` | list them, with how much has changed since each; `--all` shows retired ones |
| `:snapshot plan SNAP` | what going back to it would do; nothing is changed |
| `:rollback SNAP` | go back to it: shows the plan, then asks |
| `:snapshot retire SNAP` | take it out of the list (`unretire` brings it back; nothing is deleted) |
| `:snapshot import FILE [NAME]` | a snapshot from a copy of calibre's `metadata.db` kept from before |

`SNAP` is a snapshot's number or name. From the shell: `lulibre snapshot
list`, `lulibre snapshot rollback 3 --yes`.

Going back works out, for each field changed since, what it was then, and
writes that through calibre like any other change (so it is in the journal
and `:undo` takes it back too):

- a field lulibre changed goes back to what it was;
- a field changed outside lulibre is left as it is, unless `--exact`;
- a field changed again by means the journal did not see (it is no longer
  what lulibre last wrote) is left alone and counted;
- a book added from the sync folder since goes back to how it was when it
  was added, since what was done to it in the library is what is being
  undone. With `--unsync` it leaves the library instead, its files moved to
  the sync folder's `unsynced/`;
- a book removed since comes back out of calibre's recycle bin, with its
  fields as they were; a book put back since is removed again;
- `--fields` puts back fields only: no book is brought back, removed or
  taken out.

Before it writes anything a rollback takes a snapshot of its own ("before
going back to ..."). Going back to that one rolls forward again. Books
nothing has touched since are not looked at, and going back to the same
snapshot twice changes nothing the second time.

Author and tag names are compared without case, as calibre stores them: a
tag renamed `math/topology` to `math/Topology` in calibre is the same tag.

A snapshot imported from an older `metadata.db` is placed in the journal
at that copy's time. Where the copy differs from what the journal says the
library was then (a change nobody logged), those values go with the
snapshot and count as changes made outside lulibre.

### The snapshot browser: `gz`

`gz` (or `:snapshots`) lists the snapshots along the bottom; where the list
was, it shows what going back to the one under the cursor would do, with
some of the books it would change.

| Key | |
|---|---|
| `Enter` | go back to it (asks first) |
| `n` | take a snapshot now |
| `x` | retire it, or bring it back |
| `a` | show the retired ones too |
| `E` `U` `F` | go back with `--exact`, `--unsync`, `--fields` (the title says which are on) |

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
