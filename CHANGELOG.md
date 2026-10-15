# Changelog

Versions follow [semantic versioning](https://semver.org). The version is
written in `src/version.h`.

## In development (since 0.2.0-alpha.1)

- Fixed: some Open Library records put the series under the title after a
  blank line ("Local Fields", line breaks, "Graduate Texts in Mathematics"),
  and the whole was proposed as the title. The part after the blank line is
  now the series, and no proposed value but a comment keeps a line break.
- Fixed: OCR replaced a page's text whatever it was, so a title page that
  read well could come back empty. A page is now read by OCR only when its
  own text is no text (little of it, or garbled), and replaced only when
  OCR reads it better; a garbled file has every page the index holds read,
  not only the first `ocr_pages`.

- Changed: each file's text keeps a garbled share (characters no font
  could map; a run of them once), and `is:needsocr` goes by it: little
  text, more than 4% unreadable, or almost no words (quality below 0.2).
  A word's share alone is no sign: mathematics has few long words, and
  Keith Conrad's handouts were being taken for scans. `:run reread`
  measures every file again (`lulibre.text_measure`).

- Fixed: roman numerals a catalogue had put in title case ("Lectures in
  Abstract Algebra: Ii. Linear Algebra", from Open Library) are put back in
  capitals in the records' titles.

- New: grammars may use LPeg patterns, per line (`peg = ...`) or over the
  opening lines, when LPeg is installed (`lulibre.features` names it).
- Fixed: a C module built for another Lua crashed lulibre when a script
  required it. Each C module is now loaded once in a child process first and
  refused, with the reason, if that crashes. `rocks_tree` is searched before
  the usual places.

- New: grammars of publications (`lulibre.grammars`): how a kind of
  document sets its opening lines, and what follows. Built in: Keith
  Conrad's handouts, the Stacks project's chapters (in the order of its
  Makefile), Elsevier's Handbook of Algebra (volume and place by DOI),
  numbered chapters in very large type. `:run grammars [--apply]`; their
  titles and authors are proposed by `:propose`. Your own in init.lua.
- New: custom fields (`:custom`): metadata of your own beside calibre's,
  in a database of lulibre's own beside the index (calibre's is never
  changed for them), named as calibre's custom columns (`#partof`). They are
  edited, proposed, reviewed, journaled, undone and rolled back like any
  field, shown in the preview, and filtered by (`#partof:handbook`,
  `has:#partof`).
- New: parts of a whole, as the custom fields `#partof`, `#part`, `#parts`:
  `is:part`, `:parts` (each whole, its parts in order, what is missing).

- New: the configuration window, `gC` / `:config`: every option with its
  value, default and the line of init.lua that sets it, and what it does;
  a value changed there is written to init.lua (kept as `init.lua.bak`
  first); `E` opens init.lua in `$EDITOR` (vim, vi), and it is read again
  when you leave. Options init.lua does not mention can be put in,
  commented out with their defaults (`config_add_core`,
  `config_add_scripts`), with full help, the values only, or no comment
  (`config_comments`).
- New: scripts declare options of their own, `lulibre.option(ns, {...})`,
  set in init.lua as `lulibre.cfg.ns.name`; init.lua wins over the script.
- New: `:run reread` reads garbled pages again with poppler's pdftotext,
  or moves shifted characters back ("zkdw" for "what"), and names what still
  needs OCR (`text_fallback`). Garbled text now counts against a file's
  quality, so `is:needsocr` finds it.
- New: OCR can give the PDF itself a text layer (`ocr_write = replace |
  keep`, with ocrmypdf), the original kept in `ocr_originals` outside the
  library; undo puts it back. `:ocr --write`.
- New: features say which programs they need (`:features`); with
  `pixi_deps = "on"` lulibre can keep them in a pixi environment of its own,
  asking first. `rocks_tree` and `rocks_install` do the same for Lua
  modules. All off by default.

- New: review shows one row per field, the surest proposal for it, with
  `2/3` when there are others: `o` steps to the next source, `O` takes the
  next kind of source for that field throughout the view, `m` switches to a
  row for every proposal (option `review_rows`).
- New: while review is open, the list's place shows what the proposal
  under the cursor rests on: the record behind it (for an identifier, the
  one it leads to), what the book's pages say of the value, and the other
  sources' values (`i` hides it; option `review_context`; replaceable as
  `require("lulibre.ui.review").context`).
- New: the snapshot browser, `gz` / `:snapshots`: what going back to each
  would do, shown where the list is; go back, take, retire.
- New: `:run arxiv-titles` finds arXiv numbers by title in arXiv's snapshot
  kept on this machine, taking a paper only when the pages show its title
  and people.
- New: panels can be shown in the list's window (`side = "main"`).

- New: the file decides. Every record `:enrich` finds is held against the
  book's own pages (`lulibre.verify`): one whose title and people are both
  missing there is another work's and left out; one of a work the file is
  only part of (a 40-page chapter, a 404-page edition) gives no title,
  authors or identifiers; a title the pages do not show is not offered;
  one shown in part, or people named in part, are offered at 0.6. A title
  search's record must have its title on the pages. Where the file could
  not be read, records are offered 0.2 lower.
- New: `:verify [filter]` holds the library against its files and changes
  nothing; `:run recheck` goes back over what lulibre wrote and, with the
  file deciding, puts back titles and authors a record replaced, takes off
  identifiers of cited or other works (`--propose` for review, `--apply`
  after a snapshot). Typed values are never touched.
- New: identifiers from a file's own metadata (a PDF's XMP and Info, an
  EPUB's package) are offered as its own (0.9); `lulibre.doc_metadata`.
- New: CrossRef's subtitle is kept ("MATLAB Deep Learning: With Machine
  Learning, ..."), and its page range and Open Library's page count are
  read, to tell a chapter from its book. (Records already kept have no
  subtitle; they get one when asked again.)
- Fixed: a DOI with parentheses in it (Elsevier's
  "10.1016/S1570-7954(96)80014-3") was cut at the first one.

- New: snapshots. `:snapshot NAME` marks a point in the journal of
  changes, and `:rollback SNAP` puts the library back to it: what lulibre
  changed since goes back, changes made outside lulibre stay (unless
  `--exact`), books added from the sync folder since go back to how they
  came (or out of the library to the sync folder's `unsynced/` with
  `--unsync`), removed books come back from calibre's recycle bin. A
  rollback first takes a snapshot of its own, so going back to that rolls
  forward. `:snapshot plan SNAP` shows what it would do, `:snapshots` lists
  them, `:snapshot retire` takes one out of the list, `:snapshot import
  FILE` makes one from an older copy of calibre's `metadata.db`. From the
  shell: `lulibre snapshot ...`.
- Changed: the journal now lives in a file of its own beside the index
  (`<index>.history.db`), moved there the first time this version opens
  the index; rebuilding or deleting the index no longer touches it.
  Changes made to calibre outside lulibre are now logged in it too (as
  `outside` batches), and so are books added to the library (by `:sync
  add`, `:orphans`, `:onboard`).
- New: folders under the sync folder: a file added from `non-catalog/` is
  marked non-catalog, one from `good/` known good; `unsynced/` holds books
  a rollback took back out and is not looked in for files to add.

- New: `:noncatalog add` marks the selection as works no catalogue has a
  record of (a handout, course notes, a chapter of the Stacks project).
  Such a book is not looked up by DOI or ISBN nor searched for by title,
  a DOI or ISBN in its pages is not offered as its own, and having no
  identifiers does not count against it. Marking withdraws what waits for
  it from catalogue records and proposes taking off a DOI or ISBN it
  holds. `is:noncatalog` filters by it; `:noncatalog remove` takes it back.
  The mark is kept in lulibre's index, not written to calibre.
- New: `:run holdout` tries the learned subjects on books they were not
  taught by: each fifth of the confirmed records is left out in turn, and
  the subject said for each book is held against its tags. It keeps and
  changes nothing. (`lulibre.learn` gained `census`, `work` and `model`
  for learning without storing the result.)
- Fixed: `:learn` took phrases of a publisher's front matter for a
  subject's ("editorial board" for geometry, "graduate texts" for
  algebra). They are now left out (`learn.FURNITURE`). Run `:learn` again
  to be rid of the ones already learned.
- Fixed: a record was believed whenever the library held the identifier
  that led to it. But a DOI or ISBN in the library can be a cited work's
  (read off a reference list and accepted), a chapter's, a review's, or
  the ISBN of the whole book a chapter is from; the record then offered
  somebody else's title and authors at 0.95. Every record is now checked
  against the book (`net.fits`): the same title, or the record's title in
  the opening of the file, or the book's title with a subtitle; a looser
  likeness only when the authors do not differ. A record that fails is
  left out and named (`:messages`, or the terminal), what was proposed
  from it before is withdrawn, and when both its title and its authors
  are another work's, taking the identifier off the book is proposed.
- A record no longer presses a worse value on a good one. Offered at 0.6
  or less, so only where the field is empty or `--over` asks: a title
  that is the book's with words left out, authors with none of the
  book's names, authors that are some of the book's and nobody else (a
  catalogue's first author alone), and the title of a record known for
  the book's by its authors alone (the volume a chapter is from).
- A name spelled a little differently is the same name when authors are
  compared ("Bugrii" and "Bugrij"), and Open Library's "Cohen, Henri." is
  read as Henri Cohen.
- A DOI on a file's pages is taken for the file's own only near the top,
  or on a line of its own with its label; one that follows other words
  further down, or stands among the references, is offered at 0.5 as
  "perhaps a work it cites".

## 0.2.0-alpha.1

The second alpha: dialogs over what lulibre already does, how far sources
agree and how much each is believed, and runs of proposing that review
shows by themselves.

- `<Leader>pr` (`:propose-review`): a dialog for a whole round: which
  books, what is asked (files, kept records, services, bibliographies,
  learned subjects), which fields, how what is there is treated, and what
  review then shows; lines that cannot be used are greyed and say why.
- How far a book's sources agree is measured (`lulibre.consensus`): review
  shows how many agree on each proposal (`[2/3]`), and `s` can put the
  books whose sources disagree most first.
- `:weigh` measures how often each kind of source agrees with the library's
  own records, field by field; `:weights` (`<Leader>w`) shows the table and
  lets any weight be set by hand. With `weigh_sources = "on"` confidences
  are worked out from them. Off by default.
- More dialogs over what lulibre already does: `<Leader>e` looks the
  selection up (what would be asked of whom, a box for each service),
  `<Leader>c` makes one change to every selected book, `<Leader>d` shows
  the databases with boxes for which to fetch, `<Leader>s` adds, moves or
  drops the selected waiting files. `<Leader><Space>` unmarks every book.
- The arXiv stamp on a paper's first page gives a date only when it is a
  first version's: a later version's stamp is the day of that revision,
  and half the stamped papers carry one. arXiv's own record of a paper now
  outranks its stamp, and when a record gives the day the proposals read
  off the stamp or the number are withdrawn instead of left beside it.
- `lulibre.ui.form`: the dialog pane, for scripts.
- Each go of proposing is a run (`lulibre.runs`). While one is going on the
  status line carries a badge beside the mode (`⟳ PROPOSING  280 books:
  records, step 2 of 2`). Review shows the runs as tabs: one for each that
  still has something waiting, and "all waiting"; `l` and `h` (or a click)
  switch, and `D` drops what the run in view added, stopping it first if it
  is still going on. `gr` opens on what was just proposed.
- Fixed: "propose, then review" from the dialog told you to press `gr`
  after its first step, while the later steps were still working; that
  opened review on everything that waited, and the run's own review then
  came up over it. The steps now keep their closing lines for the log, and
  the run's proposals come up in the review that is open, if one is.
- Fixed: a round stopped with `:cancel` left the options the dialog had set
  for it (`weigh_sources`, `subject_learned`) in place.
- Fixed: looking a book up by its title (`:enrich --titles`, the dialog's
  "CrossRef by title") took a record when two words in three of a short
  title agreed, and offered it at 0.95: "An introduction to the ipaddress
  module" became "An Introduction to Module Theory". The titles must now
  say the same thing (the same telling words, or one the other with
  something run on after it), a short title counts only with an author in
  common, authors that disagree rule the record out, and the proposals
  carry 0.7 to 0.9 according to how well it fits. Of the 79 such matches
  in the library this was found in, 17 hold.
- `:run unmatch` goes back over what the earlier rule brought in, from the
  answers that were kept: it lists the matches that no longer hold, and
  with `--fix` withdraws what still waits from them and proposes, for
  review, putting back what the books said before.
- For scripts: `lulibre.status(name, text, style)` keeps a badge in the
  status line; panels take `tabs` and `p:tabs(names, current)`, and
  `p:send(key)` wakes a panel from another task. The badge
  (`runs.badge`) and the line at the top of a run's view
  (`review.banner`) are functions to replace.

## 0.2.0-alpha.0

The first alpha of 0.2.0: everything below is in it. (Put together on the
branch `0.2.0-dev` and merged into `main` as it went; builds of it are
numbered from 001 again.)

Added
- Thesis and dissertation cover pages are read by rule (title above "by",
  author after it, degree, program, institution, year, advisor), following
  Choudhury et al., JCDL 2020. It needs no font information, so it also works
  on pages read by OCR.
- `D` (`:sync drop`) takes staged files out of the sync folder without adding
  them; they are kept aside and `u` puts them back.
- With a sync folder set, a tab line shows `1 Library` and `2 Sync folder`
  with their counts and which one the list is showing; `1`, `2` or a click
  switch, and the keys that act on staged files are shown beside it.
- The command line completes: command names, option names and their values
  for `:set`, scripts for `:run`, the arguments of other commands, and the
  filter language at `&` and `/`. `Tab` takes the highlighted completion,
  `<C-n>` `<C-p>` move through them.
- History for the command, filter and search lines, kept between sessions.
  `Up` and `Down` recall entries that start with what has been typed.
- `lulibre.index{filter=, force=}` runs the indexer from a script and waits
  for it.
- Every panel's keys can be changed: `lulibre.map("review", "y", "accept")`.
  The title bar shows a panel's main keys and `?` lists them all, both
  written from the keys in force.
- The remaining fixed keys can be changed too: moving inside a panel and
  closing it, editing the line being typed, the picker, overlays and the
  console each have named actions, bound with `lulibre.map("panel", "n",
  "down")`. `?` lists them all with their keys.
- `c` clears a field in the edit form and in review. In the edit form `x`,
  which dropped the pending change, is now called revert.
- `<Leader>` in key bindings, set by the option `leader` (default `\`).
- `:reload-cfg` (`<Leader>R`) reads `init.lua` again.
- Hints and messages name keys as they are bound now, not as they were
  shipped. `lulibre.key`, `lulibre.hint` and `lulibre.maps` give scripts the
  same.

- Title case, after the APA manual. `gT` (`:titlecase`) rewrites the
  selected titles that are in CAPITALS; `t` does it for a field in the edit
  form and in review; titles proposed from files and `.bib` records arrive
  in title case when they were found in capitals (option `title_case`).
  `is:capstitle` filters for titles in capitals. For scripts:
  `lulibre.titlecase`, and `lulibre.lower` / `lulibre.upper`, which know
  accented, Greek and Cyrillic letters.
- The mouse selects text everywhere, not only in the preview: a drag in the
  list, a panel, the line being typed, the status line or an overlay copies
  what it covers; a double click the word; a triple click the row, or in a
  panel the whole cell including what its column cut off. `<C-y>` copies
  the line being typed.
- Windows are resized with the mouse, by dragging the line between two of
  them or a window's bar up or down, and from the keyboard with Alt and an
  arrow, or `<Leader>` and an arrow (`:resize left|right|up|down`). These
  keys, like any Alt combination and the leader, work from inside panels.
- `:propose` no longer stops at fields that have a value. When the file is
  confident and says something different from what the book holds, that is
  proposed too, so a value mistyped by hand gets corrected by the next run.
  The option `propose_over` (`gaps`, `sure`, `any`) sets how far the file is
  believed; `:propose --over` and `--gaps` do so for one run. A proposal
  that was rejected is not made again unless `--over` asks, and accepting
  everything above a confidence asks before replacing existing values.
- In review, `a` on a book's own line accepts all of that book's proposals
  (again: takes them back), and `r` there rejects those still pending.
- A by-line under the title ("By A. Name", "BY A. NAME*", "by NAME, A. B.",
  or "by" alone above the names) is read as the authors and proposed with
  confidence 0.85, as the page's own word rather than a guess from layout.
- Selecting text in the preview to copy it (a drag, a double click) no
  longer moves the cursor out of the window it was in, so in review the next
  key is still review's.
- Authors from title pages: ranks and roles ("Professor Emeritus") are
  never proposed, and the option `never_authors` adds terms of your own; a
  page that opens with its author's name alone on the first line is read
  that way (author 0.7, title from the next largest line); a name the
  leading pages give twice is proposed with 0.15 more confidence.
- Known good records. Every record has a score for how complete and clean
  it looks; `gk` (`:good`) lists them by it, and the ones you confirm are
  marked (`is:good`). `lulibre.quality` for scripts.
- `:learn` finds, from the confirmed records, the two- and three-word
  phrases that mark each subject, and `:terms` shows them for review: drop
  what does not belong, add your own. The edit form offers the subject a
  book's phrases point to, naming them, at no more than 0.6 confidence;
  the option `subject_learned` turns that into proposals, or off.
  `lulibre.phrases`, `lulibre.counter` and `lulibre.learn` for scripts.
- In the edit form, subjects that say what a book is about come before
  catch-alls such as `math/general` (option `subject_catchall`).
- `:enrich` asks five services, none of which needs an account: arXiv,
  CrossRef, zbMATH Open (which gives a mathematics paper its subject from
  the MSC codes), Open Library (books by ISBN, with the subject from the
  shelf class) and OpenAlex. Every answer is kept, so a work is asked about
  once and `--offline` proposes from what is kept. The options
  `enrich_services` and `contact_email`.
- `:enrich` keeps to each service's rules, arXiv's first (its terms: one
  request every three seconds, one connection). One request at a time,
  five seconds apart for arXiv and one for the others, across every running
  lulibre; forty arXiv papers, twenty DOIs or twenty ISBNs to a request; a service that answers "too
  many requests" is not asked again for half an hour and nothing is retried
  or asked one by one instead; `:enrich --plan` says what a run would ask
  before anything is asked. Old-style arXiv numbers with a subject class
  (`math.AG/0601001`) are looked up as arXiv files them.
- arXiv from a file: with a file of arXiv's records in the data folder
  (`~/.local/share/lulibre/arxiv.json`, or the option `arxiv_snapshot`),
  `:enrich` reads papers from it and asks arXiv only about those newer
  than the file. Both arXiv's own snapshot and a hypergraph of arXiv are
  read; from the second, authors are put in the order of the paper's first
  page. The snapshot is preferred where both are there, and betters the
  records that were read from a hypergraph.
- `:enrich` leaves out the record of a work the file only cites (an
  identifier found in the pages whose record has another title), puts TeX
  in arXiv's titles and names into plain text (`lulibre.detex`), and does
  not propose the same authors named less fully.
- Fixed: a hyphen or dash written another way (`Vanden‐Eijnden`,
  `Erdős–Kac`) made two values count as different.
- A layout for a series named in so many words: a line that is a series'
  name with a volume number, editors, an ISSN or a house's name beside it;
  the line above "Series Editors"; a "Series:" label. Names set over two
  lines are joined, names in capitals put in title case. "Fourier Series"
  and its like are known for what they are (`layouts.not_series`).
- The cataloguing block is read in the form the Library of Congress has
  used since 2015 (`Names: ... | Title: ... | Description: ...`), which was
  being taken for the old form and gave titles such as "Names: Miyagawa,
  Shigeru, author"; in the German national library's form; and not at all
  where it only says that a record exists. A title from a block printed in
  a scanned book is taken at 0.8, not 0.9. Found by stripping a copy of the
  library of all its metadata and proposing it back: titles proposed at 0.9
  or more went from 34% to 92% agreeing with the library's own.
- Embedded metadata in Latin-1 is read as such, not passed on as broken
  UTF-8.
- Computing has finer subjects. The vocabulary tells machine learning, AI,
  language processing, vision, complexity, algorithms, programming
  languages, information theory, systems and security apart (it knew one
  `cs`), thirty more arXiv classes have a subject of their own, and a finer
  subject under one a book already has (`cs/ml` for a book filed under
  `cs`) is proposed. `stat.*` is statistics, not computing.
- Help that can be found in: `?` shows the keys under headings that open
  and close (all but "Start here" closed to begin with), each key with what
  it does; `/` searches every key and command as you type; `K` on a key, or
  `:help TOPIC` anywhere, shows what the guides say about it. The guides are
  installed with lulibre. `:help-plain` is the old single page.
- `gp` proposes metadata for what is selected.
- `a` reads a file as far as the page being previewed, when that page is
  past what was indexed (`:addpages`); `lulibre.index { pages = N }`.
- A man page, `lulibre(1)`. `propose`, `enrich` and `refs` are commands of
  the command line too, and every script-backed command answers `-h`.
- The list as a tree. `gh` groups it by author, subject (subjects nest),
  series, publisher, year, format, or the folders of the calibre library;
  headings open and close (Enter, `l`/`h`, `za` `zo` `zc` `zR` `zM`, a
  click), show their counts, and stand for their books: `Space` marks them,
  `e` edits them, `r` reviews their proposals. `s` chooses the order of the
  books. Enter on a book opens the edit form. `:group`, `:fold`.
- `r` reviews the proposals of what is selected (`:review selection`).
- Text in the preview can be selected with the keys: `v` puts a cursor
  there, vim's movements move it, `v`/`V` select, `y` copies. A place of
  its own for keys: `lulibre.map("select", key, action)`.
- `gb`: the sync folder in a column beside the library, the list following
  the file under the cursor to the book that is the same file or to those
  that look like it; add, move, drop, edit and review from there.
- `lulibre datasets`: databases for looking books up without asking
  anybody. It says what there is (arXiv's records, Open Library's editions
  and authors, zbMATH's links to arXiv), each with a line on whom it is for,
  asks which to fetch, and can be run again whenever; `datasets add FILE`
  takes up files fetched by other means. `:datasets` in the interface.
- `:enrich` reads books by ISBN out of Open Library's dumps where they are
  here, and proposes an arXiv paper's zbMATH number from zbMATH's table of
  links, before asking either.
- An article's publisher is its journal, after the house behind it where
  that is known: `Elsevier: Journal of Algebra`. Read from a journal's
  heading and from CrossRef's and OpenAlex's records; houses are written one
  way (`layouts.house`), archives such as JSTOR are not named.
- `:arxiv-fetch` fetches arXiv's snapshot from Kaggle into the data folder,
  running Kaggle's program through pixi; not again within a week unless
  forced.
- `:enrich` paces each service by its published policy, read and linked in
  `net.lua` (Open Library and zbMATH two seconds), waits longer after a
  slow answer, and no longer sends `contact_email` to OpenAlex, which has no
  use for it.
- The publisher from the copyright line ("© Springer-Verlag Berlin
  Heidelberg 1999", "Copyright © 1984 by McGraw-Hill, Inc."), written one
  way per house (`layouts.houses`); an author's own copyright names none.
- Four layouts that read a date, for the books that have none: the day a
  journal received an article, a date on a line of its own on the first
  page, the year in a journal's heading, the year of a copyright line.
  `layouts.date(text)` and `layouts.journal(text)` for scripts.
- The series-page layout knows some thirty series of several publishers
  (and takes more: `layouts.series`), with the volume, the house and the
  year. An author read off a title page who also heads entries of the
  book's own references is proposed with more confidence; a book with no
  author is offered the authors of the books that share its references.
- `:refs` reads what each book cites from the bibliography on its last
  pages: the heading is found, the entries cut apart by numbering or hanging
  indent, and each given a key (DOI, arXiv number, or author, year and first
  page) by which the same work is known in another book's list. Books that
  share references suggest each other's subject in the edit form.
  `lulibre.extract` takes `tail = true` for a file's last pages.
- Fuller records teach more when `:learn` runs: a confirmed record counts by
  its score. The option `never_titles` adds to what marks a title as junk.
- Layouts: pages that say their facts in known places are read by rule. A
  book's cataloguing block gives author, title, series and number, year and,
  from its class number, the subject; a Springer series page the series and
  volume; the arXiv stamp the day of submission. Your own are a few lines
  (`require("lulibre.layouts").add{...}`): marks that identify the page and,
  for each field, a constant, a pattern or a function. Series and series
  number can now be proposed.
- One field at a time. `:propose --only title,ids` keeps to the fields
  named; `--fresh` proposes the file's reading whatever the record says, for
  when a field went wrong across many books; in review `f` and a letter
  shows only that field's proposals, and accept-all then speaks for it
  alone. `:clear FIELDS` blanks fields outright.
- A title of one word is no longer junk for being one word: "Algebra" and
  "Topology" are titles; "infinite" and "E807en" are still what a file name
  leaves behind. The option `one_word_titles` (`check`, `ok`, `junk`) sets
  the rule, `good_titles` lists titles to leave alone, and nothing in a
  record confirmed as good is treated as junk. (Every one-word title used
  to count as empty, so a bulk accept could replace it unasked, the edit
  form's "fill gaps" could overwrite it, and it scored as junk.)
- A value that is plainly not one is treated as empty when proposing: a
  title that is a number, a file name or a heading, an author that is a
  program, a site or a rank. `:junk` marks and lists such records.
- Title pages: a title that begins with "Introduction" is no longer taken
  for the heading that ends the front matter (no title was read from such
  pages at all); a smaller line that leads into the largest is part of the
  title ("Introduction to" above "Commutative Algebra"); a page set in one
  size has its title read from its first lines; "Professor A. Name" is A.
  Name.
- `lulibre.map` takes a description for the help overlay, or `false` to stay
  out of it.
- A warning when the password file can be read by other users.
- Review lists the books surest first: the one whose best proposal has the
  highest confidence at the top, with how many proposals wait for each. `s`
  switches to id order; the option `review_sort` sets the default.
- Review, duplicates and orphans refresh when the library changes under
  them (`reloads = true` gives a script's panel the same, as `"<Reload>"`).
  Proposals for a book that has been removed are no longer listed or counted.
- From duplicates and orphans, `e` opens the edit form for the row's book
  and `r` the review of its proposals; the panel steps aside meanwhile and
  comes back up to date. `:review FILTER` reviews only the matching books.
- `t` in duplicates and orphans takes from the row under the cursor: what
  its record says and the kept copy's (or the book that has the file) does
  not is proposed for that one, and review opens on those proposals.
- With the cursor in review, duplicates, orphans or capture, the preview's
  keys work (`P`, `]`, `[`, `J`, `K`), as do the copying keys and the
  console's. `p` shrinks the panel to give the preview room.
- A following panel shows its row's book in the preview even when the
  list's filter leaves that book out.
- Panels for scripts: `keys` and `pass`, `p:hide()`, `p:show()`,
  `p:height()`; `lulibre.ui.edit` and `lulibre.ui.review` take `{ ids = }`.

Changed
- After duplicates or orphan records are removed, the message says plainly
  what was kept from them and where it went.

## 0.1.0

The first release: what 0.1.0-beta.2 was, with nothing changed but the
version. A neovim-style interface to a calibre library for labelling and
fixing metadata: an index of the first pages of every file, a filter
language, an edit form with suggestions read from the files, proposals and
their review, capture by pattern, duplicates by content, orphans, a sync
folder, BibTeX in and out, OCR, undo, a Lua API. Changes reach calibre
through `calibredb`, by the content server or directly.

Tests
- The smoke test stops its private tmux server however it ends: a failed
  run used to leave its sessions, and the lulibre inside them, running.

## 0.1.0-beta.2

Fixed
- A lulibre run from its build tree (`./build/lulibre`) reads its Lua files
  from that tree, when each is first needed. If the tree was switched to
  another version while it ran, those files no longer fitted the binary and
  failed with errors that said nothing of the cause ("unknown option
  'propose_over'"). It now says so, at start and with any script error: which
  version the binary is, which the tree has become, and what to do.
- `test/forms.sh` could exit with failure after every check had passed.

## 0.1.0-beta

Fixed, from testing the alpha
- A field can be blanked: empty it and press `Enter`. Backspace in an
  emptied field no longer cancels it, review accepts an empty answer, and
  both forms show `(blank)` where a value is about to be removed.
- A command typed with the cursor in review, duplicates or orphans acts on
  the book that row shows. `:remove`, repeated on a row whose book had just
  been removed, took the list's next book instead; it is now refused.
- Orphans: the verdict no longer runs off the right edge. The column holds
  a short wording; `x` opens a row (`X` all rows) to show the full verdict,
  the whole path and where a link points.
- A filter in force is labelled in the status line, with how much of the
  library it leaves and how to clear it:
  `filter id:526   1 of 1999   <BS> shows all`.
- Panels follow files staged from the sync folder too.

Fixed, from a review of pointer lifetimes and leaks
- A use-after-free: closing the console (`` ` ``) while only one other
  window was open left the focus pointing at a freed window.
- A panel made the only window (`:only`) could not be closed; the list now
  takes its place.
- A script waiting on a question (`lulibre.input`) waited for ever when
  another prompt or a picker took over the bottom line; it is answered as
  cancelled.
- A mouse drag is dropped when its preview window closes, and its target is
  checked to be a preview before use.
- Messages still on their way to the Lua thread at exit are run, not
  dropped, so what they carry is freed.
- The indexer's progress report no longer keeps pointers into a finished
  job; `lulibre.extract` no longer leaks when called outside a task.

Tests
- `test/forms.sh` (`make check-forms`, part of `make e2e`): the edit form,
  review, removal and orphans, by keystroke, against a throwaway library.

## 0.1.0-alpha.2

Fixed
- A crash on the Lua thread, seen while writing: luv ran its callbacks on
  the coroutine of whichever task first loaded it, which could be gone.
- Removed books can be brought back with `u` (from calibre's recycle bin).
- A cover sheet that labels its fields ("Author(s): ...", as JSTOR's do) is
  trusted: 0.95 instead of 0.55.
- The preview opens at the first page that has text, and where a page shows
  none it says why (blank page, past the indexed pages, a scan needing OCR).
- A missing password file is reported as such before anything is written.
- Text pasted by the terminal is text: a line break in it no longer submits
  a field, and a paste outside a field no longer runs as keystrokes.
- Tests skip what needs the luv rock when it is not installed (Lua 5.4).

Added
- A crash log with a backtrace, `~/.local/state/lulibre/crash.log`; release
  builds keep their symbols.
- `lulibre.settings` (get, set, reset, names, info, paths); the option
  `config_dir`, `lulibre -C DIR`, `$LULIBRE_CONFIG_DIR`.
- Mouse: drag in the text preview to select and copy, double click a word,
  triple click a line; `<C-v>`, middle or right click paste into a field.

## 0.1.0-alpha

First version.
