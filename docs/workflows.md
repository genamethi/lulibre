# Workflows

lulibre reads calibre's `metadata.db` and the book files directly, and
never writes to either itself. Every change goes to calibre through
`calibredb`, and the journal records it with the value it replaced. `u`
undoes a change, and `:rollback` puts the whole library back to a snapshot.

Most actions apply to the **selection**. The selection is the range
selected with `V`, or else the marked books in the list, or else (in a
grouped list, with the cursor on a heading) every book under that heading,
or else the book under the cursor. With the cursor in review, duplicates or
orphans, the selection is the book of the row under the cursor. If that
book is no longer in the list, the command is refused.

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

## Editing: `e`

The edit form has one row per field for the selected books. While the form
is open, the preview shows the book being edited, wherever the list's
cursor is (opened from duplicates or orphans, the row's book). For several
books, the preview shows none of them, only how many are selected, so
nothing is copied from the wrong book.

`i` shows, in place of the list, what the file's pages say for each field,
with the source and confidence beside each value. For several books, it
shows which fields they share and which differ, with the values, how many
books have each value, and the books themselves. The panel opens with the
form if `review_context = 1`.

| Key | |
|---|---|
| `Enter` | type a value. A popup ranks suggestions, and `Tab` takes the highlighted one |
| `Space` | step through the values the file and related books suggest |
| `i` | show what the pages say, in place of the list; press again to hide it |
| `a` | fill every empty field with the file's best suggestion |
| `c` | clear: blank the field |
| `t` | title case |
| `x` | revert: drop the field's pending change |
| `w` | write |
| `?` | list every key of the form |

In a list field (authors, tags, identifiers), `+x, -y` adds and removes
values and leaves the rest alone. That is how you add one tag to two
hundred books.

To blank a field, press `c`, or empty it (`<C-u>`, or backspace) and press
`Enter`. The form shows `(blank)` where the value will be removed. Both
ways work in review too.

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

## Title case: `gT`

lulibre rewrites a title in CAPITALS in title case, following the APA
manual. The first word of the title and of a subtitle is capitalised, and
so is every major word and every word of four letters or more. Articles,
short conjunctions and short prepositions stay in lower case.

    ON THE THEORY OF GROUPS: AN INTRODUCTION
    On the Theory of Groups: An Introduction

- `gT` (`:titlecase`) converts the selection's titles that are in
  capitals and leaves the others alone. `:titlecase all` converts any
  title. `&is:capstitle` lists the titles in capitals.
- `t` in the edit form and in review converts the value under the cursor.
- Proposals convert titles on their own: a title found in capitals on a
  title page, in a file's own metadata or in a `.bib` file is proposed in
  title case. `title_case = "never"` proposes titles as found.

Capitals carry no case information, so some of it is guessed. Roman
numerals, words with a digit, short words without a vowel (NMR) and a list
of known spellings (PDE, LaTeX, USA) are kept as they are. The rules are
English, and you can add to both lists in `init.lua`:

```lua
local tc = require "lulibre.titlecase"
tc.minor["with"] = true      -- APA capitalises "With"; this keeps it lower case
tc.minor["de"] = true        -- for French titles
tc.keep["cw"] = "CW"
```

### Mathematics in titles

Proposed titles write their mathematics in Unicode, as far as Unicode
allows: SL₂(ℤ), GLₙ(ℚₚ), 𝔽ₚ[T], ℤ/pᵃℤ, X³ − 5, ℓ-adic. A subscript or
superscript that Unicode has no character for is written `_q` or `^q`
(𝔽_q), a longer one `_{…}`, and TeX that can't be written at all (a
fraction) keeps its dollars. Search is not affected: in lulibre and in
calibre, `SL2` finds SL₂(ℤ) and `Fp` finds 𝔽ₚ.

- From the pages: the PDF reader marks each line's mathematics by its
  fonts (a maths italic, a symbol or blackboard font) and by type set
  smaller and higher or lower (X³, GLₙ). So a title page gives back the
  scripts that its plain text lost. A capital alone in bold inside a
  formula is a number system, as many authors write it (**Z** for ℤ).
- From TeX: arXiv and similar services give titles as their authors typed
  them (`On $\mathbb{Z}_p$-extensions` becomes On ℤₚ-extensions).
- From plain text: a glossary changes only text that can be read one way:
  `SL2(Z)`, `GLn(Qp)`, `Fp[T]`, `Z/nZ`, `Rn`, `over Q`, `X3 −5`, `K0` in a
  K-theory title, `` `-adic ``. `F[t]` (any field), `R[t]` (any ring),
  `f(R)`, `Programming in R` and `A4` are left alone.

`:notation [filter]` proposes the selected books' titles this way. It reads
each PDF's title page again if the page gives the same title (books indexed
before this version have no stored marks), and uses the glossary
otherwise. Title case leaves formulas alone and keeps the word after a
formula in lower case (p-adic). `math_notation = "off"` proposes titles as
found. The glossary is a list of functions you can extend in `init.lua`:

```lua
local nt = require "lulibre.notation"
table.insert(nt.groups, "PU")          -- PU2 as PU₂
nt.glossary[#nt.glossary + 1] = function(s)        -- Spin3 as Spin₃
  return (s:gsub("%f[%w]Spin(%d)%f[%W]", function(n) return "Spin" .. nt.subscript(n) end))
end
```

## Proposals and review: `gr`

Scripts don't change the library. They *propose* changes, and you review
them.

    :run propose [filter]        metadata read from title pages
    :run split-authors           "A. One; B. Two" into separate authors
    :run enrich [filter]         arXiv and CrossRef records for books with an identifier
    :run normalize-tags          one spelling for subjects that exist under two
    :run bib-import FILE         what a .bib file says about the books it matches

`propose` reads the first pages. It looks, in order, for an arXiv stamp; a
cover sheet that labels its fields (JSTOR's "Author(s):"); a thesis cover
(title above "by", author after it, institution, year); a by-line under the
title ("By A. Name", or "by" on its own line above the names); a page that
starts with its author's name alone on the first line and has the title
further down. If none of these is found, it takes the largest type on the
page.

A name the first pages give twice (again in an e-mail address or a running
head) is proposed with more confidence, and the source says so ("named
twice"). Ranks and roles ("Professor Emeritus", "Lecture Notes") are never
proposed as authors. The option `never_authors` adds your own words and
phrases:

    lulibre.o.never_authors = "visiting scholar, working group"

Each proposal records where it came from and how confident it is.

A proposal under `propose_min` (60% by default) is stored but hidden.
Review leaves it out, the counts of waiting proposals leave it out, and
every summary ends by saying how many there are ("12 are under propose_min
(60%) and not shown"). Lower the option, in the config window or init.lua,
and they show at once. When another value is proposed for the same field
of a book, the hidden proposals are removed (`propose_held = "keep"` keeps
them all).

An empty field always gets the file's best candidate. A field that already
has a value gets a proposal if the file is confident (0.8 or more) and
gives a different value. So a typo made by hand is caught the next time
`:propose` runs over the book, and review shows the value and the proposal
side by side. The comparison ignores case, accents, the shape of quotes and
punctuation. The option `propose_over` changes the threshold:

| `propose_over` | a field that has a value |
|---|---|
| `gaps` | gets no proposal |
| `sure` (default) | gets a proposal if the file is confident and differs |
| `any` | gets a proposal whenever the file's best candidate differs |

    :propose --over [filter]     as `any` for this run, and propose values that were barred before
    :propose --gaps [filter]     as `gaps` for this run
    :propose --only FIELDS ...   only those fields: title authors subject ids date publisher, or t a s i d p
    :propose --fresh ...         as if the fields were empty: the file's best reading, whatever the book says

A value that is clearly not a real value counts as empty: a title that is
a file name, a number or a heading, or an author that is a program, a web
site or a rank. `:junk` marks and lists the books with such a title or
author.

A one-word title counts as a title if it is a plain capitalised word
("Algebra", "Topology"), and as junk if it is left over from a file name
("infinite", "E807en", "tensorprod"). The option `one_word_titles` changes
this: `ok` accepts any single word as a title, and `junk` accepts none. Two
things protect a title whatever it looks like: listing it in `good_titles`
(`lulibre.o.good_titles = "Set, 1984"`), and confirming its record as good
(`gk`), after which nothing in that record is treated as junk.

**When one field went wrong across many books** (titles from a bad
download run, for example), narrow the list to those books, then run

    :propose --fresh --only title

This proposes each file's own title, whatever the record says. In review,
press `gr`, then `f` `t` to see only the titles, then `A` to accept them in
one go. `:clear FIELDS [filter]` blanks fields outright (`u` puts them
back), and `:propose --fresh` without `--only` reads every field of the
books again.

Rejecting a proposal (`r`) applies to that proposal only, so a later run
may propose the same value again. `N` rejects it for good: that value is
not proposed again for that book and field, unless you use `--over`. With
the option `review_reject = "always"`, `r` does what `N` does. In review,
`A` (accept everything above a confidence) asks before it includes
proposals that replace a value.

`gr` lists the proposals book by book, with the current value beside each.
The list and preview follow the cursor, so the title page is in view.

**The pages' verdict.** Each proposal's row is marked with what the book's
own pages say about it, compared with the book's current value:

| Mark | |
|---|---|
| `●` | the pages show the proposed value and not the current one (or the field is empty); or the proposed value is the current one and more (a subtitle) |
| `=` | the pages show both the proposed and the current value |
| `◐` | the pages show part of the proposed value |
| `·` | the pages can't tell: no readable text, or a field the pages can't settle (subjects) |
| `○` | the pages show neither value |
| `✗` | the pages show the current value and not the proposed one |

lulibre looks for a title, authors, a series or a publisher on the opening
pages. It looks for a date by its year, where a book gives its date (a
copyright line, arXiv's stamp), and for an identifier as the file's own,
not one it cites. Books whose proposals the pages support best come first,
so the proposals you can accept at a glance are at the top. `s` steps
through the orders: best supported, most confident (by the sources'
confidence), most disputed, and by id. The option `review_sort` sets the
starting order. To use other marks, replace
`require("lulibre.ui.review").marks` in init.lua.

Review, duplicates and orphans update themselves when the library changes:
a book removed with `:remove` leaves the panel.

| Key | |
|---|---|
| `a` `r` | accept, reject; on a book's own line, all of that book's proposals |
| `N` | reject, and never propose that value for that field of the book again |
| `e` | correct the proposed value, then accept it |
| `x` · `X` | show this book's other fields under its proposals · for every book |
| `e` on a shown field | edit the field in the same pass; the edit becomes an accepted proposal |
| `A` | accept everything at or above a confidence |
| `R` | reject everything still pending |
| `c` | propose blanking the field |
| `t` | convert the value to title case, and accept it |
| `s` | sort: best supported by the pages, most confident, most disputed, by id |
| `f` then a letter | show only one field's proposals: `t` title, `a` authors, `s` subject, `i` identifiers, `d` date, `p` publisher; `f` `f` shows all again. Accept-all and reject-rest then apply to that field only |
| `p` | more preview: shrink the panel; press again to restore it |
| `l` `h` | the next view, the previous view (the tabs in the bar; clicking a tab also works) |
| `D` | drop the proposals of the view shown: deleted, not rejected, so they can be proposed again |
| `w` | write the accepted proposals as one batch |
| `o` | show the next source's proposal for this field (one row per field) |
| `O` | for this field, show the next kind of source (CrossRef, Open Library, the title page, ...) in every book that has one |
| `m` | switch between one row per field and one row per proposal |
| `i` | show or hide, in place of the list, what the proposal under the cursor is based on |

**One row per field.** A title, the authors, a date, a publisher or a
series holds one value, so the proposals for it are alternatives. Review
shows the most confident one, with `2/3` before its source if there are
others. `o` steps to the next proposal. `O` shows the same kind of source
for that field throughout the view, so you can look at all the titles
CrossRef gave, then all the titles the title pages gave. Accepting takes
the proposal shown. `m` (or the option `review_rows = "all"`) shows every
proposal on its own row instead. Subjects and identifiers that are added or
removed are not alternatives, and always get a row each.

**What a proposal is based on.** While review is open, the panel in place
of the list shows the proposal under the cursor:

- where the proposal came from, and how confident it is;
- the pages' verdict in words, and what the book's own pages say about the
  proposed value (and about the value it would replace);
- the record behind the proposal (for an identifier, the record the
  identifier leads to, which is what accepting it would bring), with that
  record's title, people, date, type, length and identifiers, and how each
  compares with the pages;
- the other sources' values for the field.

`i` hides the panel and shows it again, and the option
`review_context = 0` starts without it. To show something else there,
replace `require("lulibre.ui.review").context` in init.lua. The function
gets the proposal and the field's other proposals, and returns rows.

`:review FILTER` limits review to the books a filter matches
(`:review author:unknown`), and `w` then writes only their proposals.

#### Runs, and review's tabs

Each round of proposing is a *run*: `gp`, `:propose`, `:enrich`, and the
dialog below, which is one run however many steps it takes. While a run is
in progress, the status line shows a badge beside the mode, in the warning
colour:

     NORMAL  ⟳ PROPOSING  280 books: records, step 2 of 2

and nothing tells you to open review until the run is done. Review shows
the runs as tabs in its bar, with the current tab highlighted:

     review  13 pending, 0 accepted   best borne out first   09:41 · 4 books (13)   all waiting (1140)

| Tab | Holds |
|---|---|
| `09:41 · 4 books (13)` | everything waiting for the books of the run started at 09:41, whether that run proposed it or it was waiting before |
| `⟳ 09:50 · 280 books (96)` | a run still in progress: what it has found so far. The view opens on its own when the run is done |
| `all waiting (1140)` | every waiting proposal |

`gr` opens on a run that is in progress or that you haven't seen yet, and
otherwise on everything. A "propose, then review" from the dialog opens its
own run when it is done, in the open review if there is one, so two
reviews never stack on each other. The first line of a run's view says
what the run is and which keys act on it. `D` there drops *what that run
added* and keeps what was waiting before; on a run still in progress, `D`
stops the run first. lulibre forgets a run when nothing waits for its books
any more, or when a later run covers the same books.

All of this is Lua, and you can change it in `init.lua`:

    local runs = require "lulibre.runs"
    runs.badge = function(run) return "busy: " .. (run.step or ""), "accent" end  -- other words, another colour
    runs.badge = function() end                                -- no badge
    require("lulibre.ui.review").banner = function() end       -- no line at the top of a run's view
    lulibre.map("review", "<C-n>", "next_view")                -- another key for the next tab

Copying from the page doesn't take the cursor out of review. Drag over a
name in the preview, or double-click a word, and the next key still goes to
review, so `e` then `<C-v>` puts the copied text into the field. (A plain
click in the preview, one that selects nothing, does move the cursor there.)

While the cursor is in review, duplicates, orphans or capture, the
preview's own keys still work: `P` for the page as an image, `]` `[` to
turn pages, `J` `K` to scroll, and the copying keys (`yy` ...). `?` lists
them.

Proposals are kept between sessions.

A book that already has a subject is offered another one only if the file
states a subject (an arXiv class, MSC codes, a shelf class). The one
exception is a narrower subject under the one the book has. A book filed
under `cs` whose pages are clearly about machine learning is offered
`cs/ml`, on the vocabulary's evidence alone. `:propose --only s subject:cs`
asks for exactly that.

### Propose, then review, from one dialog: `<Leader>pr`

`\pr` (`:propose-review`) opens a dialog that sets up the whole round in
one place and in order:

| Part | What it sets |
|---|---|
| Which books | the selection, everything the list shows, or the whole library |
| What to consult | the files themselves; the records stored on this machine; the services; CrossRef by title; the bibliographies first; subjects from shared references and from learned phrases; whether the sources are weighted |
| Which fields | a checkbox for each: title, authors, subject, date, publisher, series, identifiers |
| Existing values | as `propose_over` says, only gaps, or over any value that differs; as if the fields were empty; drop the proposals already waiting for these books |
| Then, in review | accept automatically what is at or above a confidence (never over a value a book has); show nothing below a confidence; the order of the books |

A line that can't be used is greyed out and says why ("nothing learned
yet: confirm records with gk, then :learn"). `Space` ticks a box or steps
through a choice, Enter types a value, and `w` (or Enter on the last lines)
starts. `:propose`, `:enrich`, `:refs` and `:review` with their flags can
do all of this by hand.

The whole round is one run (see "Runs, and review's tabs" above). The
status line shows the current step, the steps keep their closing lines for
the log, and when the run is done, review opens on the run's tab.

### Other dialogs

A few more actions have the same kind of dialog, which says what will
happen before it happens:

| Key | Dialog |
|---|---|
| `\e` | **Look up** the selection. Shows how many works each service would be asked about and in how many requests (nothing is asked to find this out), a checkbox for each service, then "ask, then review" or "ask nobody: propose from what is stored here" |
| `\c` | **Change at once**: add or remove a subject, or set the authors, series, publisher, date or language, for every selected book (the books under a heading, the marked ones). Empty lines change nothing, and one undo reverses all of it |
| `\d` | **Databases** kept on this machine: which are here, how old they are, and a checkbox for each to fetch |
| `\s` | **The selected waiting files** in the sync folder: which are new and which the library already has, and a choice of add, add and remove, or drop |

`\` then `Space` unmarks every book (`:mark none`).

### How far the sources agree

Several sources describe a book: its title page, a cataloguing block, the
data inside the file, an arXiv record. Two sources that give the same field
should agree. lulibre measures how far apart two values of a field are:
titles by their words, authors by their family names, dates by their years,
and subjects by how close they are in the tree. For each field of a book,
it works out:

- the **value** with most of the weight behind it;
- how many sources **agree** on it, shown in review beside the source:
  `title page 0.55  [2/3]`;
- the **disagreement**: 0 if every source says the same, towards 1 if they
  say unrelated things. `s` in review puts the books whose sources disagree
  most first, where a look is most needed.

### How far each source is trusted

`:weigh` measures every kind of source against the library as it is now.
For example: of the times the title page gave a title for a book whose
title is trustworthy, how often was it that title? `:weights` (`\w`) shows
the table. You can set any line by hand (Enter) or return it to the
measurement (`x`). `:weigh good` measures against only the records you
have confirmed (`gk`). Once you have confirmed a few dozen records, that
is the better measure: a field the library has wrong for many books (dates
taken from the files, for example) makes the sources that are right look
bad.

With the option `weigh_sources = true` (or its checkbox in the dialog), a
proposal's confidence no longer comes from its rule. It comes from the
sources that agree on the value, each weighted by its measured reliability.
The option is off unless you turn it on.

## Capture: `gc`

Capture pulls fields out of file names, titles or embedded metadata. Type a
pattern, and the table shows what it finds in each selected book:

    %author% - %title% (%year%)                       a template
    ^(.-) %- (.-) %((%d+)%)$ => author, title, year   a Lua pattern, then the names of its captures

| Key | |
|---|---|
| `p` · `s` | change the pattern · change what it is matched against (file name, title, authors, embedded title or author) |
| `w` · `P` | write what was captured · make proposals from it instead |
| `m` | mark the books that matched |
| `S` `L` | save the pattern as a named rule, load a rule |

## Layouts: pages that state their facts in known places

Some pages can be read by rule instead of by font size, and lulibre reads
them with more confidence:

| Layout | What is read |
|---|---|
| cataloguing data (the Library of Congress block on the back of a title page) | author, title, series and number, year, ISBN, and the subject its class number stands for (`QA247` is number theory) |
| series page (some thirty series of Springer, the AMS, Cambridge, Princeton and others) | the series and the volume's number, the publisher, the year (of the original edition, for a reprint) |
| series line (a series named explicitly: "Springer Undergraduate Mathematics Series", the line above "Series Editors", "Series: Lecture Notes in Physics") | the series and, if given, the volume's number |
| arXiv stamp | the submission date, from a first version's stamp only. A later version's stamp gives the date of that revision, and is not used as a date |
| received date ("Received 8 February 1972", "Received by the editors May 3, 1999") | the date a journal received the article |
| dated page (a date on its own line on the first page: "March 12, 2015", "Date: October 2009.") | that date |
| journal header ("Journal of Algebra 320 (2008) 1234–1256") | the year, and the journal as the publisher |
| copyright line ("© 2008 Elsevier Inc.", "Copyright © 1965, 1984 by McGraw-Hill") | the year (the latest, if several are listed together), and the publisher, if the holder is a publisher and not the author |
| a cover sheet with labelled fields; a thesis cover | as described under proposals |

What a layout reads is proposed like anything else, with the layout's name
as the source.

The word "series" proves nothing by itself ("Fourier Series", "a series of
lectures given at ..."). So a line counts as a series' name only if it is
set like a name, is not mathematics, and something next to it confirms it:
a volume number, the series' editors, an ISSN, or a publisher's name. Two
tables decide what counts, and you can add to them:

```lua
local layouts = require "lulibre.layouts"
layouts.not_series["bertrand"] = true      -- "Bertrand Series" is a sum, not a set of books
layouts.series_houses["polity"] = true     -- "Polity Series in ..." needs no other confirmation
```

A publisher on a copyright line is written in one form, whatever the line
says ("Springer-Verlag Berlin Heidelberg", "Springer Nature Switzerland AG"
and "Springer Science+Business Media" are all Springer). `layouts.houses`
is the list, as `{ pattern, name }`, and you can add to it. A holder that
is not on the list but looks like a publisher ("Chelsea Publishing
Company") is proposed as written, with less confidence. An author's own
copyright names no publisher.

An article's publisher is its journal. If the journal's publisher is also
known (from the page's copyright line, from a service's record, or because
the book already has it), the journal comes after it: `Elsevier: Journal of
Algebra`. A society's own journal names the society and stands alone, and
an archive that only registers the articles (JSTOR) is not named.
`layouts.journal_join` is the text between the two.

The four layouts that read a date are for books that have none. All but
the journal header are below the confidence at which a proposal replaces a
value (`propose_over = "sure"`), so they fill gaps and leave existing dates
alone. A date calibre took from the file (the day a PDF was made, not the
year the book came out) is one they would correct: `:propose --over --only
d FILTER` proposes dates over the existing ones, for review.

A layout of your own is a few lines in `init.lua`:

```lua
require("lulibre.layouts").add {
  name = "ams memoirs",
  marks = { "memoirs of the", "american mathematical society" },   -- all on one of the first pages
  fields = {
    series = "Memoirs of the American Mathematical Society",       -- a fixed value
    series_index = "Number%s+(%d+)",                                -- a pattern: its capture is the value
    pubdate = "(%d%d%d%d)%s+%S*%s*Volume",
    publisher = function(text, doc) return "AMS" end,               -- or a function
  },
  confidence = 0.85,
}
```

`marks` are Lua patterns, matched ignoring case, and the fields are read
from the page where all of them are found. Adding a series the series-page
layout doesn't know takes one line:
`table.insert(require("lulibre.layouts").series, { "Astérisque", "Société Mathématique de France" })`.
`:run candidates` shows what every layout reads from the book under the
cursor, which is how to try a layout out. Eight layouts come with lulibre.
More layouts pay off most for books from one publisher and era.

## Known good records: `gk`

Every record has a score from 0 to 1 for how complete and clean it looks:
a title that reads as a title, an author that is a name, a date, a subject
that says what the book is about, identifiers. A file name as a title, a
title in capitals or full of digits and odd characters, an author that is a
list or a role, and a catch-all subject (`math/general`) lower the score.

`gk` (`:good`) lists the records by score, best first, with what lowers
each score. The score only suggests; you decide what to confirm:

| Key | |
|---|---|
| `Space` | confirm the record as right, or remove the confirmation |
| `A` | confirm every record at or above a score (0.85 means nothing is visibly wrong) |
| `v` | show the records still to confirm, the confirmed ones, or all |
| `e` | edit the record |
| `L` | learn from the confirmed records (see below) |

`:good add` and `:good remove` do the same for the selection, and
`&is:good` lists the confirmed records. lulibre learns only from confirmed
records, so a mistake in an unchecked record is not learned and spread to
the rest.

## What marks a subject: `:learn` and `:terms`

`:learn` reads the indexed pages of every book. For each subject, it finds
the two- and three-word phrases that the subject's confirmed books use far
more than books of other subjects: "modular forms" and "class field theory"
for number theory, "gradient descent" for computing. It takes a few
seconds.

A phrase counts only if several of the subject's books use it, by at least
three different authors (so one author's habits don't count), and if it
also appears in some book's title, which keeps out cities, companies and
figures of speech. Text that many books share word for word (a publisher's
imprint, a series list) is removed first. A book teaches its subject and
the subjects above it; a catch-all subject teaches only the subjects above
it.

`:terms` shows what was learned, subject by subject, strongest first:

| Key | |
|---|---|
| `x` | drop the phrase: it will not be learned for that subject again |
| `a` | add a phrase of your own |
| `f` | narrow the list to the books whose pages contain the phrase |
| `d` | show the dropped phrases |
| `L` | learn again |

With `learned_tags = "suggest"`, if a book's pages contain at least two of
a subject's phrases, the edit form offers that subject for the book's tags,
naming the phrases ("learned: modular forms, elliptic curves"), with a
confidence of at most 0.3. This is a judgement from a handful of phrases on
a book's first pages, and it has been wrong more often than right, so it
is off unless you turn it on. `learned_tags = "propose"` makes `:propose`
use it too. Such a proposal is shown if it reaches `learned_tags_min`
(20%), instead of `propose_min`.

`:run holdout` measures how well this works on the library as it is now.
It splits the confirmed records into five parts. In turn, it leaves each
part out, learns the phrases from the other four, and guesses the subject
of every book left out, comparing the guess with the book's tags. It
reports how often a subject was guessed and how often the guess was one of
the book's tags, by subject and by how many phrases the book had. `--wrong`
names the books it got wrong, with the phrases that misled it. Nothing is
stored or changed, and it takes a few seconds. `:run holdout 10` splits the
records into ten parts.

Read the result with care. A book has several subjects and its tags name
one or two, so a guess "not among its tags" is sometimes a subject the book
should have. A few dozen confirmed books for a subject are also not many.
The measure is for seeing whether a change you made (more records
confirmed, a phrase dropped in `:terms`, a threshold in `lulibre.learn`)
made things better or worse.

Phrases that say how a book was published ("editorial board", "graduate
texts", "mathematics subject classification") are never learned for a
subject. `require("lulibre.learn").FURNITURE["lecture notes"] = true` in
`init.lua` adds one.

In the edit form, subjects that say what a book is about are listed before
catch-alls, however many books the catch-alls hold. The option
`subject_catchall` adds to the built-in catch-alls (`general`, `papers`,
`books`, `handbook`, `misc`, `other`).

## Looking books up: `:enrich`

For books with an identifier (already in calibre, or found in the file),
`:enrich` asks a service for the work's record and proposes what it says:

| Service | Asked by | Gives |
|---|---|---|
| arXiv | arXiv number | title, authors, the submission date, the subject its class stands for |
| CrossRef | DOI | title, authors, year; a book's publisher and ISBN |
| zbMATH Open | DOI or arXiv number | **the subject**, from the MSC codes each work is classified under by hand; the Zbl number |
| Open Library | ISBN | title, authors, publisher, year, series; the subject from the book's library class |
| OpenAlex | DOI, if CrossRef has nothing | title, authors, date |

None of the services needs an account or a key.

    :enrich [filter]             the selection, or the books a filter matches
    :enrich --plan [filter]      show what would be asked of which services, and ask nothing
    :enrich --offline [filter]   use only answers fetched before: nothing is asked
    :enrich --titles [filter]    also search CrossRef by title for books with no identifier

Every answer is stored in the index, including "there is no such record",
so each work is asked about once. A second run makes no requests, a
stopped run loses nothing, and `--offline` proposes again from the stored
answers without using the network. A "no such record" answer is trusted
for thirty days, then asked again.

#### Is the record this book's?

An identifier can be wrong: a DOI read from a reference list, a chapter's
or a review's DOI, the ISBN of the whole volume a chapter comes from. So
lulibre checks a record against the book before proposing anything from
it, whether the identifier was read from the file or is already in the
library:

| The record | |
|---|---|
| has the book's title, or its title appears word for word at the start of the file, or is the book's title plus a subtitle | is the book's record |
| is only similar (a shortened title, most of the words) | is the book's record unless the authors differ: a review "..., by Sutton and Barto" is not the book |
| has another title, but an author in common | is used, without pushing its title (0.5): another form of the title, or the volume this book is part of |
| has another title and no author in common | is left out, and what it proposed before is withdrawn. If the library holds the identifier, removing it is proposed (0.6) |
| says something the book's pages contradict, as read by rule (a cataloguing block, a copyright line, a series page, a cover sheet, a journal header, an arXiv stamp, a grammar): a year earlier than the one the pages print, or a publisher that is not theirs, their imprint or their journal | is left out the same way, with the reason. An ISBN the pages don't print is proposed for removal. If the pages state nothing of the kind, the record is not checked against them |

What was left out is listed in the log (`:messages`), and on the terminal
by `lulibre enrich`. Even from the book's own record, a value that is
clearly worse than the book's is offered at 0.6 or less, which means only
into an empty field or when `--over` asks. Examples are a title with words
left out ("Extending Python" for "Extending and Embedding Python"), and
authors with none of the book's names, or fewer of them.

A search by title is the weakest of these, because a search always returns
something. lulibre uses the record only if it is clearly the same work:

| The titles | The authors | Offered at |
|---|---|---|
| the same significant words | one family name in common | 0.90 |
| the same significant words, four or more | the book has none | 0.80 |
| one title is the other plus something after it (a subtitle, the author's name), sharing four words or more | in common · the book has none | 0.85 · 0.70 |
| three significant words or fewer ("Algebraic Geometry") | the book has none | not used |
| anything | both have authors, with no name in common | not used |

"Significant words" leaves out *the, of, and, to* and similar words. "An
introduction to the ipaddress module" and "An Introduction to Module
Theory" share two of three significant words, and are not the same title.
Before 0.2.0-alpha.1 they counted as the same, and such records were
offered at 0.95. `:run unmatch` lists the matches made that way that no
longer hold. `:run unmatch --fix` withdraws the proposals still waiting
from them, and proposes restoring what the books had before, as a run of
its own in review ("wrong title matches"). It asks no service anything,
since the answers were stored.

#### Checking the record against the file

A record claims that the file is a certain work, but only the file itself
is sure to be about this work. So before offering anything, lulibre also
checks the record against the book's own pages (`lulibre.verify`):

| The book's pages | |
|---|---|
| show neither the record's title nor any of its authors | the record is another work's: left out, as above |
| are much shorter than the edition the record describes (a 40-page file, a 404-page book), or the record is of a whole book and the pages don't show its title | the file is a **part** of that work (a chapter of a handbook). The record's title, authors and identifiers belong to the whole and are not offered; its publisher and year are |
| don't show the record's title | the title is not offered |
| show only some of its words, or name only some of its authors | that value is offered at 0.6 or less |
| could not be read (no text, a scan, garbled characters) | everything is offered 0.2 lower, since nothing could be checked |

A title found by a title search must appear on the pages, or the record is
not used. Words are compared folded (without case and accents). An accent
TeX left beside a letter ("Universit´e") is joined to it, and digits and
daggers beside a name ("Chamseddine1,3", "Joyner†") are separated from it.

A file's own metadata counts too. Publishers put a work's DOI in the PDF's
XMP packet (`prism:doi`, `dc:identifier`), and some in its Info
dictionary; an EPUB names its ISBN in its package. These are offered (0.9)
as the file's own, ahead of a DOI read from the pages, which may belong to
a cited work. An arXiv DOI (`10.48550/arXiv....`) is used as the arXiv
number.

### Checking the library against its files: `:verify` and `:run recheck`

`:verify [filter]` checks every book against its own file and changes
nothing. It reports whether the opening pages show the book's title and
name its authors, and where each DOI, ISBN and arXiv number the book has
appears: in the file's metadata, on the opening pages, further in, only in
the reference list, or nowhere. `--list title|authors|ids|unread` lists
every book of one kind.

`:run recheck` goes back over what lulibre has written, with the file as
the judge:

- A title that came from a catalogue record goes back to the book's
  previous title if the pages match the previous one better (more of it,
  in order). A title from anywhere else goes back only if the old title is
  in the largest font of the first pages and the new one hardly appears
  there. A name stuck on the end of the old title ("Noncommutative
  Geometry Alain") is removed, and junk and generic headings ("Front
  Matter") are never restored.
- Authors go back if the pages name none of the current authors and some
  of the previous ones.
- A DOI, ISBN or arXiv number lulibre added is removed if it appears only
  in the reference list, or its record is clearly another work's. One that
  lulibre removed but the file's own metadata names is restored.

Values you typed are left alone, and so are changes made outside lulibre
and books whose file could not be read.

    :run recheck [--list] [filter]   show what would change
    :run recheck --propose           put the changes in review, as a run
    :run recheck --apply             make the changes now, after taking a snapshot
    :run recheck --since SNAP        only what was written after a snapshot

`--apply` also withdraws the proposals still waiting from `:run unmatch
--fix`, since recheck settles the same books with the file as the judge.

### arXiv numbers by title, on this machine: `:run arxiv-titles`

With arXiv's own snapshot stored here (`:datasets`), `:run arxiv-titles
[filter]` looks up every book with no arXiv number by its title (and by
the part before a colon), in one pass through the file, without asking
anyone. A paper with the same title is used only if the book's pages show
that title and name its authors. Its number is then proposed, and
`:enrich --offline` proposes the rest of its record. It takes a minute or
so.

### Works no catalogue has: `:noncatalog`

No catalogue has a record of a handout, course notes, a chapter of the
Stacks project or a saved web page. Such a work has no DOI or ISBN of its
own, so a DOI or ISBN in its pages belongs to a work it cites, and a
record found by searching for its title belongs to another work. Marking
the book records this once:

| | |
|---|---|
| `:noncatalog add` | mark the selection |
| `:noncatalog remove` | remove the mark |
| `:noncatalog` | list the marked books (the filter `is:noncatalog`) |

For a marked book:

- a DOI or ISBN in its pages is not offered as the book's own;
- `:enrich` doesn't look the book up by DOI or ISBN, or search for its
  title. An arXiv number is still followed, since arXiv keeps such works;
- having no identifiers doesn't count against the book in `:good`, and
  `lulibre stats` counts it separately;
- when you mark it, the book's waiting proposals from CrossRef, Open
  Library, OpenAlex and zbMATH are withdrawn, and removing each DOI or ISBN
  it has is proposed (at 0.8, for review like anything else).

To mark many books at once, filter to them, select them all, and run
`:noncatalog add`; for example, filter on `author:"keith conrad"`. Check
what the filter caught first: `author:conrad` also finds Brian Conrad's
book with Springer, which has an ISBN and should keep it. An unexpected
removal in review is the sign of a book marked by mistake.

The mark is stored in lulibre's index. Nothing is written to calibre.

### How the services are asked

The services are free and run by other people, so lulibre asks as little
as it can:

- **One request at a time to each service, with a pause after each**: five
  seconds for arXiv, two for zbMATH and Open Library, one for CrossRef and
  OpenAlex. Each pace is well within what the service allows anonymous
  callers (arXiv: one every three seconds; Open Library: one a second;
  CrossRef: five a second, one at a time; OpenAlex: ten a second; zbMATH:
  "a reasonable rate"). The time of the last request is stored in the
  index, so a second lulibre, or the same command run again at once, keeps
  the same pace.
- **A slow answer is followed by a longer pause**, as long as the answer
  took, so a service under load is asked less (CrossRef asks for this).
- **Many works per request**, where the service accepts that: forty papers
  for arXiv, twenty DOIs for CrossRef, twenty ISBNs for Open Library.
  (zbMATH is asked one work at a time; it can't take several.)
- **arXiv's rules are the strictest, and lulibre keeps well within them.**
  Its [terms of use](https://info.arxiv.org/help/api/tou.html) allow "no
  more than one request every three seconds" on "a single connection at a
  time", and its [manual](https://info.arxiv.org/help/api/user-manual.html)
  asks that results be cached. A library with two hundred arXiv papers
  needs five requests, once.
- **A service that says "too many requests" is left alone.** After an HTTP
  429 or 503, nothing is retried: the service is not asked again for half
  an hour (arXiv) or five minutes (the others), or for as long as the
  service says, if that is longer. The run continues with the other
  services, and at the end says which service asked for a pause and until
  when. Run it again later for the books that were skipped.
- **Nothing is asked twice.** A failed request is not repeated within the
  same hour, and a failed batch is not split into single requests.

`:enrich --plan` reads the identifiers and prints how many requests each
service would get and about how long the run would take.

### Databases kept here

Some of what the services know can be downloaded whole, and then the
services are not asked at all:

    lulibre datasets                 list what is available, and ask which to fetch
    lulibre datasets list            only list
    lulibre datasets fetch NAME...   fetch these (or `all`); --force fetches even if they are up to date
    lulibre datasets add FILE...     use files you fetched yourself (they are linked, not copied)

| Dataset | Useful if you have | What it is | Size | Renewed |
|---|---|---|---|---|
| `arxiv` | arXiv preprints | arXiv's own snapshot: title, authors, classes, DOI and the date of each version of every paper. From Kaggle (`Cornell-University/arxiv`), fetched with Kaggle's program run through [pixi](https://pixi.sh) (`pixi exec kaggle`, which installs nothing). Kaggle requires an account, with its token in `~/.kaggle/` | 1.7 GB to fetch, 5.6 GB on disk | weekly |
| `openlibrary` | books with an ISBN | Open Library's monthly dumps of editions and authors: title, authors, publisher, year, series, library class | 9.7 GB | monthly |
| `zbmath` | arXiv preprints in mathematics | zbMATH's table of links to full texts (Zenodo, doi:10.5281/zenodo.8021789): the zbMATH number of an arXiv paper. It has no titles and no subjects, so those are still asked of zbMATH | 37 MB | as of June 2023 |

In the interface, `:datasets` lets you choose one to fetch, and fetches it
in the background.

The datasets are kept in lulibre's data folder (`~/.local/share/lulibre`),
beside the index. A file there may be a link to a file kept elsewhere, and
fetching then renews the file the link points to. A fetch that stops half
way leaves the old files as they were, and running it again resumes where
it stopped. A dataset that is here and as new as its source is left alone,
so you can run the command at any time.

`:enrich` uses whatever datasets are here before it asks any service:

- **arXiv papers** are read from the snapshot (ten seconds for its three
  million papers). arXiv is asked only about papers newer than the file.
- **Books with an ISBN** are looked for in Open Library's dump (a few
  minutes for its ten gigabytes, once: an ISBN the dump doesn't have is not
  looked for in it again until the file changes). Open Library is asked
  only about the rest.
- **An arXiv paper's zbMATH number** is proposed as an identifier
  (`zbmath:5635019`).

If there is no snapshot, lulibre also reads a hypergraph of arXiv (papers
as "edges", authors as "nodes"; one JSON document over many lines, named
`arxiv.json` in the data folder). It lacks the order of the authors, the
DOI and the submission date.

A hypergraph gives the authors in no order, so lulibre sorts them in the
order the paper's first page names them. If the page doesn't name them
all, the proposal says so and does not replace authors a book already has.
The submission date is still read from the stamp arXiv prints on the page.

lulibre checks what a record says before trusting it:

- An arXiv number or DOI that calibre already has is trusted. One that was
  read from the file's pages may belong to a work the file cites, so its
  record is left out unless the record's title is the book's title, or the
  title the file itself shows.
- arXiv keeps titles and names as typed, TeX included (`Erd\H{o}s`), and
  lulibre converts them to plain text. A title that still has mathematics
  in it fills a gap, but does not replace a title that reads well.
- The same people with shorter names ("S. Joffily" for "Sérgio Joffily")
  are not proposed; with fuller names, they are.

`contact_email`, if you set it, is sent with each request, because CrossRef
and Open Library allow more requests from callers they can reach. The
option is empty unless you set it, and nothing else about you is sent.
`enrich_services` sets which services are asked.

What the records say is proposed like anything else and decided in review.
A title or author from a record counts as more reliable than one read from
a title page, so with `propose_over = "sure"` it is proposed over a value
that differs.

## Grammars of publications: `:run grammars`

Some kinds of document always start the same way. Keith Conrad's handouts
put the title in capitals, with KEITH CONRAD smaller below it. A chapter of
the Stacks project puts its name in capitals, then its tag ("01H8") or its
contents. A Springer chapter puts its number and title in very large type.
A chapter of Elsevier's Handbook of Algebra has a DOI that gives its volume
and its place in the volume. A *grammar* describes a kind of document's
opening lines, line by line (their text, font size, capitals, bold), and
what follows if they match.

    :run grammars [filter]           show what each grammar finds; nothing is changed
    :run grammars --apply [filter]   store the parts and the non-catalog marks

`:propose` proposes what a grammar says about a title or authors, like
what the title page says (source `grammar: keith-conrad`). `--apply` marks
Conrad's handouts and the Stacks project's chapters as non-catalog.

**Parts of a whole.** A grammar can say which whole a file is part of, the
file's number in the whole, and how many parts there are. So can a record
much longer than the file. These values are custom fields (see below):
`#partof`, `#part`, `#parts`. `is:part` finds such books, and `:parts`
lists each whole with its parts in order and the missing numbers. For the
Stacks project, the order comes from its Makefile: lulibre reads it from a
book that contains the table "Chapters in reading order"
(`| # | Chapter | Pages | PDF |`).

Add your own grammars in init.lua or a module:

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

A line rule can test `pattern` (`nocase = true`), `upper`, `bold`,
`bigger` or `smaller` (than the page's body text), `largest`, or
`size = { min, max }`. It can `take` a field (the line, or the pattern's
capture; `case = "title"`) or `give` fixed values. `G.skip(n)`,
`G.opt(rule)` and `G.either{ ... }` combine rules. `text = { patterns }`
and `pages = { min, max }` test the whole file, and `read(doc, got)` can
work out more fields (or return false to reject the match after all).

With LPeg installed for lulibre's Lua (`:features` tells you), a line rule
can give `peg = PATTERN` instead of `pattern`. A grammar can also give one
LPeg pattern over its opening lines joined by newlines (`head` lines, 12 by
default). A table capture (`lpeg.Ct` with named `lpeg.Cg`) gives fields:

```lua
local lpeg = G.lpeg()            -- nil and the reason, if LPeg is not installed
local C, Cg, Ct, P, R, S = lpeg.C, lpeg.Cg, lpeg.Ct, lpeg.P, lpeg.R, lpeg.S
G.add { name = "caps-then-names",
  peg = Ct(Cg(C((R"AZ" + S" '-:,")^3), "title") * P"\n" * Cg(C((1 - P"\n")^1), "authors")) }
```

## Custom fields: `:custom`

calibre has a fixed set of fields. Your own metadata goes beside them, in a
database of lulibre's own (`<index>.custom.db`, beside the index). calibre's
database is never changed for custom fields, and rebuilding the index loses
nothing. A field is named the way calibre names a custom column
(`#partof`), so it can become a column later.

    :custom                          list the fields, their types, and how many books have each
    :custom add NAME [type] [help]   declare a field: text (the default), number, date or list
    :custom set NAME VALUE           set a field for the selection (an empty value removes it)

Otherwise a custom field works like the other fields. It is in the edit
form (`e`), it can be proposed and reviewed, and it is written the same way,
so it is in the journal and undo, snapshots and rollbacks restore it. The
preview shows it under the book's identifiers, and filters find it:

    #partof:handbook     #part:3     #part:none     has:#partof     no:#series2

lulibre's own custom fields are `#partof`, `#part` and `#parts` (parts of a
whole). Scripts read and write custom fields through `lulibre.custom` and
`lulibre.apply`.

### In calibre too

A custom field can also be a calibre custom column of the same name.
lulibre still keeps its own values, and writes every change to calibre's
column too.

    :custom column add NAME [heading]   ask calibre to add the column
    :custom column remove NAME         remove a column from calibre (any column); lulibre keeps its values
    :custom push NAME                  copy lulibre's values into the column, where calibre's differ
    :run columns                       add the columns for #partof, #part, #parts (an example script)

calibre adds a column only while the content server is stopped, so the
column waits (see below), and lulibre asks: restart now, or not now. Until
the column exists, and wherever calibre's value differs from lulibre's, the
preview says so under the book's custom fields (`not in calibre: #note
(lulibre only), #partof (calibre: …)`). `:custom` shows each field's state:
lulibre only, waiting for a restart, in calibre too, or how many books
differ.

### Changes that wait for the server to stop: `:offline`

Some calibredb commands refuse to run through the content server. They work
on the library folder, while nothing else has the library open.

| Command | What it does |
|---|---|
| `add_custom_column` | adds a column to calibre's database |
| `remove_custom_column` | removes a column and its values |
| `restore_database` | rebuilds `metadata.db` from the `metadata.opf` in each book's folder |
| `check_library` | vacuums the database, then reports where the database and the folders disagree |
| `backup_metadata` | writes the `metadata.opf` of each book changed since its last one was written |
| `catalog` | writes a catalogue of the library (CSV, BibTeX, EPUB …) |

Only calibre's own code writes a book's `metadata.opf`. A change made
through calibredb or the content server only marks the book. Each time the
server is stopped, lulibre first has calibre write these files
(`backup_metadata = true`), so `restore_database` would get them right (see
"The opf files" below).

lulibre queues these commands (in the history file beside the index) and
runs them the next time the server is stopped. They run the same way,
whatever stopped the server:

- `lulibre.service`, which runs before each start of the server's systemd
  unit. Set `server_hook = true`, and lulibre installs and enables the
  service for the unit that runs your server (see "lulibre's systemd units"
  below).
- "restart now": lulibre stops the server with the option `server_stop`,
  runs the commands, and starts the server with `server_start`
  (`systemctl --user stop calibre-server`, `… start …`).
- by hand, while the server is down: `lulibre offline`.

With `server_restart_at = "03:30"` (a time of day), lulibre also has
systemd restart the server every day at that time, so `lulibre.service`
runs at least daily.

If both `lulibre.service` and the "restart now" options are set up, a
restart from lulibre makes one copy of calibre's database, not two. The
service, which the restart's start of the server triggers, leaves the copy
and the opf files to the restart.

What lulibre offers when a change is queued depends on what has the
library open:

- nothing (no content server, or it is stopped): run the change now;
- the calibre program: the change waits until the program is closed;
- the content server: restart it now, or not now.

      :offline                 show what is waiting, and what failed
      :offline restart         restart the server now to run them
      :offline cancel ID
      lulibre offline [list | cancel ID]

A failed job is tried again the next time, and `:offline cancel` drops it.

### Copies of calibre's database: `:backup`

Before the server starts (whichever of the three ways above starts it),
lulibre copies `metadata.db`, and calibre's preferences beside it, to
`~/.local/share/lulibre/backups/<the index's name>/`, one folder per copy.
`backup_restart` sets when:

| `backup_restart` | |
|---|---|
| `always` | every start (the default) |
| `next` | the next start only; then not again until it is set to `next` again |
| `never` | only when you ask |
| a number | when the newest copy is that many days old |

lulibre keeps the newest `backup_keep` (5) copies. At the first change to
the library in a session, if the newest copy is older than `backup_max_age`
days (7), a popup offers to make one (`backup_too_old = false` turns the
popup off).

    :backup                    list the copies, and when they are made
    :backup now [why]          make a copy now (the server may be running)
    :backup check              check that calibre's database is intact
    :backup compare N          show what putting copy N back would change (1 is the newest)
    :backup restore N          put copy N back
    :backup next               or always, never, DAYS: set backup_restart (and in init.lua)
    :backup prune [keep]
    lulibre backup ...         the same, with no interface (restore needs --yes)

**Is it intact?** `:backup check` runs SQLite's integrity check on
`metadata.db`. The check only reads, so the server may be running. Each
copy is checked when it is made, and the list marks a copy that fails
(`FAILED`). The copy matches the database page for page, so a copy that
fails means calibre's database fails too. If calibre's database is
damaged, lulibre still starts: it warns, and continues with the library as
it last read it, so you can put a copy back. Pruning never removes the
newest copy that passed its check, so copying a damaged database again and
again doesn't push out the last good copy.

**Putting a copy back.** There are two ways back from a damaged database,
or from a change you want undone across the whole library:

- one of lulibre's copies (`:backup restore N`): everything calibre had at
  that moment;
- calibre's `restore_database`, which rebuilds the database from the books'
  `metadata.opf` files. It is only as current as those files (see "The opf
  files" below for which program writes them in your setup).

`:backup restore N` first shows how the copy differs from calibre's
database now:

- **books removed since:** their records come back. Their files don't, if
  calibre moved them to its trash. Restore those with the calibre program
  first, since calibre can't once the copy has their records.
- **books added since:** their records go, and their folders stay.
  `:orphans` finds them.
- **books changed since:** they go back to how they were, with how many
  differ in each field lulibre reads. calibre's last-modified time shows
  which books changed, so a book changed only in its comments, a custom
  column or its cover is counted, but no field is named.
- **folders renamed since:** a new title or author renames a book's folder.
  The copy's record names the old folder, so the record is pointed at the
  current folder.

Then it asks. The copy goes back once nothing has the library open, like a
new column (`:offline`): restart the server now, or wait for its next
start. Before anything changes, calibre's current database is copied and
kept; put that copy back to undo the restore. lulibre adjusts the copy, in
a staged file of its own, to the library folder as it is now:

- the renamed folders, as above;
- each book that differs is marked, so calibre writes its `metadata.opf`
  again;
- no book gets an id that a book added since had (that book's folder,
  `Title (id)`, is still there).

Then the staged file goes in through SQLite's own backup. If the database
is too damaged for that, the staged file replaces it. Nothing else in the
library folder is touched.

### The opf files

calibre keeps a copy of each book's record in the book's folder, as
`metadata.opf`. calibre reads these files when it rebuilds its database
(`restore_database`) and when it brings a book back from its recycle bin,
so they are worth keeping current. Only calibre's own code writes them,
and only some calibre programs do:

| What runs | What writes the opf files |
|---|---|
| the calibre program | the program, a changed book every few seconds |
| calibre's content server, started through lulibre's launcher | calibre's same writer, in the server |
| calibre's content server, as calibre documents it | nothing while it runs: changes are only marked. calibre writes the files each time the server is stopped (`lulibre offline`, which `lulibre.service` runs before each start) |
| nothing | calibre (`backup_metadata`), right after lulibre changes the library in its folder |

(The option `backup_metadata`, true by default, makes lulibre ask calibre
for the files at those times.)

While the calibre program is open, anything lulibre would do that the
program might also be doing waits: a change straight to the library's
folder, a file set aside from a book's folder, the changes queued for a
stopped server. The status line says so, and lulibre continues once the
program is closed.

lulibre never writes an opf file itself. Its launcher,
`contrib/calibre-server-opf.py` (installed in
`<prefix>/share/lulibre/contrib/`), starts calibre's content server with
calibre's own Python, and starts in it the thread the calibre program runs
to write the files. So one process serves the library, renames its book
folders and writes its opf files, as the program does. The launcher takes
the same arguments as `calibre-server`, after `--`:

    /opt/calibre/calibre-debug -e /usr/local/share/lulibre/contrib/calibre-server-opf.py -- [calibre-server options] LIBRARY

For a systemd unit that runs `calibre-server` (the one calibre's manual
gives, at <https://manual.calibre-ebook.com/server.html>, or your own),
set `opf_writer = "server"`. lulibre adds a drop-in to the unit,
`<unit>.d/lulibre-opf-writer.conf`, which replaces the unit's ExecStart
with the launcher's. The unit's own file is left as it is (see "lulibre's
systemd units" below).

A unit with sandboxing or hardening settings (`ProtectSystem`,
`ReadOnlyPaths`, `NoNewPrivileges` ...) doesn't get the drop-in; lulibre
shows the drop-in instead. With such settings, the service must still be
able to read the launcher and run `calibre-debug`; the status file below is
optional. For a new setup, lulibre ships calibre's manual's unit with this
change, in `<prefix>/share/lulibre/systemd/calibre-server.service`.

If the server is started some other way (an OpenRC or runit service, a
script, a container's command), replace `calibre-server ARGS` with
`calibre-debug -e <the launcher> -- ARGS`, using the calibre-debug of the
same calibre.

The launcher writes `~/.local/state/lulibre/calibre-server.json` while it
runs. lulibre reads the file to know that the opf files are being kept
current, and `:backup` shows which program keeps them current and how many
books' files are older than their record. **The launcher relies on
calibre's internals**, not on anything calibre promises. After a calibre
update, check that the server's log has `lulibre opf: calibre metadata
backup running`. If calibre has changed what the launcher relies on, the
server starts without the thread (the library stays reachable), the log
and the status file say why, and `:backup` shows it. With
`LULIBRE_OPF_REQUIRED=1` in the unit's environment, the server doesn't
start at all instead.

### lulibre's systemd units

Three options set what lulibre adds around the systemd unit that runs
calibre's content server, and lulibre keeps the units in line with them:

| Option | What lulibre installs |
|---|---|
| `server_hook = true` | `lulibre.service`, which runs `lulibre offline` before each start of the server's unit, enabled for that unit |
| `opf_writer = "server"` | the drop-in `<unit>.d/lulibre-opf-writer.conf`, which starts the server through the launcher, with calibre's opf writer in it |
| `server_restart_at = "HH:MM"` | `lulibre-restart.timer` and `lulibre-restart.service`, which restart the server every day at that time |

Turn an option off (or back to its default), and what it installed is
removed. lulibre finds the unit from the calibre-server running now, or
else from the unit files that start one (`~/.config/systemd/user/`,
`~/.local/share/systemd/user/`, `/etc/systemd/system/`).

- A user unit: lulibre writes the files and runs `systemctl --user`
  itself, when the interface starts and when one of the options is changed
  in the config window. If the drop-in changed, it offers to restart the
  server.
- A system unit: lulibre writes the files with sudo, in the terminal, after
  asking: when one of the options is changed in the config window, or with
  `lulibre units apply`. `lulibre.service` then runs as the server's
  `User=` (or as you).
- A server started some other way (an OpenRC or runit service, a script, a
  container): nothing is installed. Run `lulibre offline` before each start
  of the server, and start the server through the launcher as above.

      lulibre units            show what the options ask for, and what would change
      lulibre units apply      make the changes
      :units [apply]

## What books cite: `:refs`

The index holds each file's first pages, but a bibliography is on the last
pages. `:refs` reads the last pages (the option `refs_pages`, 14 by
default) and finds the bibliography's heading ("References",
"Bibliography", numbered or not). It cuts the text after the heading into
entries, by their numbering or by the hanging indent. Then it gives each
entry a key that recognises the same work in another book's list, however
each list writes it: a DOI or arXiv number if the entry has one, or else
the first author, year and first page.

    :refs                the selection
    :refs all            the whole library (a couple of thousand books take seconds)
    :refs --force ...    read again the books already read

Nothing is fetched: everything is read from the files, several at a time.
Each book is recorded when it is done, so a stopped run can be resumed.

Books that cite the same works are about the same topic. Once references
are read, the edit form offers, for a book's tags, the subject of the books
that share references with it ("shares references with 3 books of that
subject"). It does so if at least two books each share at least two cited
works with the book. A work that half the library cites counts for little,
and a work only two books cite counts for much. `lulibre.refs` gives
scripts the lists and the links between books.

References also say something about who wrote a book. People cite
themselves, so a name read from a title page that also heads several
entries of the book's own bibliography is proposed with more confidence
("cited 4 times in its references"). For a book with no author at all, the
edit form suggests the authors of the books that share the most references
with it. These are people who write on the same topics: a place to look,
not an answer.

Finding the heading needs only the text: the heading is a short line with
one of a few words and nothing else. Every line also records its font size
and position, for layouts that need them.

## Duplicates: `gd`

Duplicates are books whose files are byte-for-byte the same. Only files
that share a size are hashed (MD5), and the hashes are stored, so the scan
is quick.

`Space` chooses the copy to keep (by default, the record with the most
metadata), `s` skips a group, `m` marks the extra copies, `f` filters the
list to `is:dupe`, and `D` removes the extra copies. What a removed record
knew and the kept record doesn't becomes proposals for the kept copy.

`e` opens the edit form for the book under the cursor, and `r` opens the
review of its proposals. The duplicates panel moves aside while they are
open, and comes back up to date. `p` gives the preview more room.

In place of the list, the group's copies are shown side by side, field by
field, with the fields that differ in colour, and with their formats and
folders (`i` hides this panel and shows it again). The preview shows the
copy under the cursor, even one the list's filter leaves out, and stays on
it in the edit form.

`t` takes from the copy under the cursor. Every field where that copy's
record says something the kept copy's record doesn't is proposed for the
kept copy, whatever `propose_min` says, so these proposals are always
shown. Review opens on them, each marked with the book it came from.
Accept what you want, and `w` writes it. Nothing is removed.

## Orphans: `go`

| Found | Suggested |
|---|---|
| a record whose file is gone, and the file is elsewhere in the library | re-attach the file |
| a record whose file is gone, and another book is the same work | remove the record |
| a file in one of calibre's folders that calibre doesn't know about | move it out, if a book already holds the same bytes |
| a symbolic link in your own folder that points at a renamed book | repair the link |

In place of the list, the row is shown in full: a record with no file next
to the book that has its file, field by field, or a stray file or a link
with what it leads to (`i` hides this panel and shows it again).

- `Space` changes a row's action. On a heading ("Records with no file"),
  it changes every row under the heading at once. `w` carries out the
  actions.
- `e` and `r` open the edit form and the review for the row's book, as in
  duplicates. `t` on a record whose file is gone offers the record's values
  to the book that is the same work and has the file.
- `x` expands the row under the cursor to show what its columns cut off
  (the full verdict, the whole path, where a link points), and `X` expands
  every row.

Removed records go to calibre's recycle bin, and `u` brings them back.
Stray files are moved to `~/.local/share/lulibre/orphans/`, never deleted.
calibre renames a book's folder when its title or author changes. With
`repair_links = "auto"`, links are repaired after every such change.

## The sync folder: `gS`

Set `lulibre.o.sync_dir` to a folder where new files arrive. The tab line
along the top then has `2 Sync folder` between `1 Library` and
`3 Configuration`, with how many books each holds and which one the list
is showing. `2` (or `gS`, or a click on the tab) reads the folder and shows
it in place of the library, and `1` (or `gl`) goes back.

A file in the sync folder is *staged*: it is listed, filtered, searched and
previewed like a book, and `e`, `gc`, `:run propose`, `gr` and undo all
work on it. lulibre stores these edits, and nothing reaches calibre until
you use one of these keys:

| Key | |
|---|---|
| `S` | add the selection to the library with its staged metadata; the files stay in the folder |
| `X` | add the selection, then delete each file from the folder once calibre holds the same bytes |
| `D` | drop: take the selection out of the folder without adding it. The files are kept under `~/.local/share/lulibre/dropped/`, and `u` puts them back |

`=` marks a staged file the library already has. Adding it adds nothing,
and moving it only clears it out of the folder.

Some folders inside the sync folder have a meaning. A file added from
`non-catalog/` is marked as a work no catalogue has (`:noncatalog`), and a
file added from `good/` as a record known to be right (`gk`). `unsynced/`
is where a rollback puts books it takes out of the library (`--unsync`,
see below); files there are not waiting to be added.

### Beside the library: `gb`

`gb` (`:beside`) puts the sync folder in a column on the left, with the
library's list beside it. The list follows the file under the cursor. If
the library already has the same file, the list moves to that book
(`= 26`). Otherwise, the list narrows to the books whose title, authors or
tags contain the longest words of the file's title, so you see a copy under
another name before adding it twice. The preview shows the waiting file.
`Esc` moves to the library's list, and the preview then shows the book
there (`Tab` comes back).

| Key | |
|---|---|
| `S` | add the file to the library; it stays in the folder |
| `X` | add the file, then delete it from the folder |
| `D` | drop the file |
| `e` or Enter | edit the metadata the file will be added with |
| `r` | review the proposals waiting for the file |
| `m` | switch whether the library's list follows with similar books |
| `R` | read the folder again |

## Metadata that comes with the files

A `.bib` file beside a set of files, whose entries name those files in
`file = {...}`, is treated as the truth about them. The sync folder and
`:run onboard DIR` use it instead of reading title pages, and `:run
bib-import` matches its entries to books by content. A build can write such
a file next to its output. The fields used are `author`, `title`,
`date`/`year`, `publisher`, `series` with `number`, `keywords` (tags),
`doi`, `isbn`, `eprint` and `url`.

## BibTeX

    lulibre bib 'tag:math/algebra' > algebra.bib
    :bib FILE                    the selection
    yb  yk                       copy entries, or cite keys, to the clipboard

Entries have a `file` field, which Zotero, JabRef and BibDesk understand.

## OCR, and text that came out garbled

    :ocr [filter]                tesseract, for books with no usable text layer
    lulibre ocr 'is:needsocr'

`lulibre.o.ocr = "auto"` runs OCR after indexing, for the files that need
it. OCR reads the first `ocr_pages` pages into lulibre's index. The file
itself is left alone, unless `ocr_write` says otherwise:

| `ocr_write` | |
|---|---|
| `off` (default) | the PDF stays as it is |
| `replace` | `ocrmypdf` also gives each PDF read a text layer (every page; this takes a while), and the new PDF replaces the old one in calibre |
| `keep` | the same, but the old PDF is first copied to `ocr_originals`, a folder outside the library (by default `~/.local/share/lulibre/ocr-originals/`), so calibre never holds two copies. A folder inside the library is refused |

`:ocr --write [filter]` does only the text layer. The journal records each
replaced PDF, and `u` puts a kept original back.

**Garbled text.** Some PDFs set their text in fonts that don't say which
letter each glyph is. What comes out is `�` (U+FFFD), private-use
characters, or shifted letters ("zkdw dvvxpswlrqv" for "what
assumptions"). lulibre records each file's share of such characters (a
long run of them, such as the dots before a page number in a table of
contents, counts once). `is:needsocr` matches a file with more than 4% of
them, or with almost no text. (Mathematics set in fonts with its symbols in
the private-use area comes to 2 or 3%, and is left alone.)
`:run reread [filter]` reads those pages again:

1. with poppler's `pdftotext`, a separate reader that maps many such fonts
   that MuPDF doesn't. Its line boxes are kept, so the title page can still
   be read by font size. A page is replaced only if the new reading is
   readable and better;
2. by shifting the characters back, if one shift turns the file's longer
   pages into English (the pages must agree on the shift);

and then names the books that still need OCR. `text_fallback = "off"`
leaves poppler out.

## Features and the programs they need

lulibre runs without any of these programs. lulibre looks for a program
when a feature that needs it is used, and `:features` shows which are
installed and turned on.

| Feature | Programs | For |
|---|---|---|
| poppler | `pdftotext` | `:run reread` (`text_fallback`) |
| tesseract | `tesseract` | `:ocr` (`ocr`) |
| ocrmypdf | `ocrmypdf` | giving PDFs a text layer (`ocr_write`) |
| lpeg | the Lua module `lpeg` (a rock) | grammars written with LPeg patterns |

If a program is missing, lulibre says how to install it. With
`pixi_deps = true`, lulibre can also keep its own pixi environment (under
`~/.local/share/lulibre/pixi`) and offers to add the program there, asking
first. This is off by default, since it means running what pixi fetches.

Scripts may need Lua modules. `rocks_tree` names a luarocks tree whose
modules `require` finds (before the usual places). With
`rocks_install = true`, `lulibre.require_rock(module [, rock])` offers to
install a missing module there. This is off by default, for the same
reason.

A C module (a `.so`) built for a different Lua version than lulibre's
crashes whatever loads it. A `lua.h` of another version earlier on the
compiler's include path (`/usr/local/include` comes before `/usr/include`)
is enough to cause this. So lulibre first loads each C module once in a
child process, and refuses a module that crashes there, with a message,
instead of crashing with it. (Rebuild such a module against the right
headers: `luarocks --lua-version 5.5 install lpeg
LUA_INCDIR=/usr/local/include/lua/5.5`.)

## Without the content server

`lulibre.o.write_via` chooses how changes reach calibre: `"server"`,
`"direct"` (straight to the library folder, which calibre allows only while
none of its programs has the library open), or `"auto"`, the default,
which uses the server if it answers and direct otherwise.

## Snapshots: `:snapshot`, `:rollback`

The journal of changes is kept in its own file beside the index
(`<index>.history.db`), so rebuilding or deleting the index never loses it.
The journal holds:

- every field lulibre wrote, with the value it replaced;
- every book lulibre removed, added from the sync folder, restored or
  dropped;
- the changes made to calibre by other means (calibre's own window, the
  content server, another program). lulibre finds these by comparing the
  books with how they were the last time it looked, and logs them as one
  batch labelled `outside` when the next change is logged.

A snapshot is a position in the journal. No copy of the library is made.

| Command | |
|---|---|
| `:snapshot [NAME]` | take a snapshot now (named by the time, if no name is given) |
| `:snapshots [--all]` | list the snapshots, with how much has changed since each; `--all` includes retired ones |
| `:snapshot plan SNAP` | show what going back to a snapshot would do; nothing is changed |
| `:rollback SNAP` | go back to a snapshot: shows the plan, then asks |
| `:snapshot retire SNAP` | remove a snapshot from the list (`unretire` brings it back; nothing is deleted) |
| `:snapshot import FILE [NAME]` | make a snapshot from a copy of calibre's `metadata.db` kept from before |

`SNAP` is a snapshot's number or name. From the shell: `lulibre snapshot
list`, `lulibre snapshot rollback 3 --yes`.

A rollback works out, for each field changed since the snapshot, what the
field was then. It writes that value through calibre like any other
change, so the journal records it and `:undo` can reverse it:

- a field lulibre changed goes back to its old value;
- a field changed outside lulibre stays as it is, unless you use `--exact`;
- a field changed again by means the journal did not see (it is no longer
  what lulibre last wrote) is left alone and counted;
- a book added from the sync folder since the snapshot goes back to how it
  was when added, since what was done to it in the library is what the
  rollback undoes. With `--unsync`, the book leaves the library instead,
  and its files move to the sync folder's `unsynced/`;
- a book removed since the snapshot comes back from calibre's recycle bin,
  with its fields as they were, and a book restored since is removed again;
- `--fields` restores fields only: no book is brought back, removed or
  taken out.

Before writing anything, a rollback takes its own snapshot ("before going
back to ..."), so going back to that snapshot rolls forward again. Books
nothing has changed since are skipped, so going back to the same snapshot
a second time changes nothing.

Author and tag names are compared ignoring case, as calibre stores them: a
tag renamed from `math/topology` to `math/Topology` in calibre is the same
tag.

A snapshot imported from an older `metadata.db` is placed in the journal
at that copy's time. Where the copy differs from what the journal says the
library was at that time (a change nobody logged), the copy's values go
with the snapshot and count as changes made outside lulibre.

### The snapshot browser: `gz`

`gz` (or `:snapshots`) lists the snapshots along the bottom. In place of
the list, it shows what going back to the snapshot under the cursor would
do, with some of the books it would change.

| Key | |
|---|---|
| `Enter` | go back to the snapshot (asks first) |
| `n` | take a snapshot now |
| `x` | retire the snapshot, or bring it back |
| `a` | show the retired snapshots too |
| `E` `U` `F` | go back with `--exact`, `--unsync`, `--fields` (the title shows which are on) |

## When something goes wrong

`` ` `` opens the log console. The status line counts errors until the
console has shown them. `:history` lists every batch of changes, and
`:undo N` undoes one, leaving alone any field that was changed again since.

Removals are batches too. Undoing a removal re-adds each book from
calibre's recycle bin (`.caltrash` in the library folder), with its files,
cover and metadata, and the book comes back under a new id. This works as
long as calibre keeps the book in the bin, which calibre empties after some
days.

If lulibre itself crashes, `~/.local/state/lulibre/crash.log` has the
backtrace.
