# Lua API

lulibre runs Lua 5.4 or 5.5. `~/.config/lulibre/init.lua` runs at start, as
the first task. Empty, or missing, lulibre works the same: everything
below is there without it.

    :lua CODE                   Lua, as a task (dofile runs a file)
    lulibre run FILE [args]     a Lua file with no interface; print goes to stdout
    :restart-scripts            a new Lua state; init.lua runs first, as at start
    :tasks   :cancel ID|all

lulibre comes with these commands, which show what they find in a list
(`ls` prints it). Each is a function of the module `cmd`, whose `{ ls = true }`
returns what it found and shows nothing: `require("cmd").dupes { ls = true }`.

| | |
|---|---|
| `dupes [ls]` | books whose files hold the same bytes: files of the same size hashed, grouped by hash. Changes nothing |
| `orphans [ls]` | files a record names that are not on disk, files in the books' folders no record names, empty folders. Changes nothing |
| `tags [ls \| write]` | tags whose levels are split with "/", and each as calibre writes levels, with "."; with `write`, rewrites them, one operation `:undo` puts back |

## How scripts run

There is one Lua state. With the interface up it lives on a thread of its
own, with its own event loop and its own connection to the index;
headless, there is one thread. The interface and Lua talk by messages, and
neither waits for the other: a call that answers nothing is sent and
returns at once, and a call that answers (marked *waits* below) pauses its
task until the answer comes.

Scripts run as **tasks** that take turns: a script, a command's function,
a key's function, a callback, init.lua. A task gives the others their turn
where it waits, and only there (or at `taskman.yield()`): what it does
between two waits, no other task sees half done. A task that computes for
long holds the other tasks up, not the interface; after 2 s without
waiting it is reported, and `:cancel` stops it. A function that waits
must be called from a task.

A resource lives on the stack of the task that opened it: hold it in a
`<close>` variable, and it is released at the end of its scope, or when
the task fails or is cancelled.

    local txt = require "txt"
    local t <close> = txt.of(book)

`:restart-scripts` tears the state down and makes it again. The commands,
keys and callbacks Lua made go with the old state; the settings stay.

## Overriding lulibre's own behaviour

Redefine the function, from init.lua or a module of yours. lulibre calls
every function meant to be overridden through its module's table, at the
time of the call, so the redefinition takes effect from the next call.

    local propose = require "lulib._propose"
    local normalize = propose.normalize
    function propose.normalize(field, value)
      if field == "publisher" then value = value:gsub("^The ", "") end
      return normalize(field, value)
    end

A packaged module's internal functions (`lulib._review.actions`,
`lulib._propose.once` ...) are in its table too while the setting
`expose_modules` is true, the default, and redefining one changes what
lulibre does; with it false, they are not, and lulibre calls its own
whatever you redefine. The setting is read each time, so the command
line, options.lua and `:set` all reach it.

No file of yours replaces a packaged module: lulibre's own modules are
found first, then `lua/` in the configuration folder, then the module
prefix `path.modtree` names. A module of yours is required under a name
of its own.

Two parts are C's unless a handler of yours takes their place, set as a
field; setting it to nil gives the part back. A handler runs as a task,
so it can wait. setman and `lulib.opt` reach both by name, `ocr_eng` and
`store.calibre`, though they are no settings of the store: the command
line and the saved state hold none.

    utils.ocr_eng = function(path, page, lang) return utils.exec({ "my-ocr", path, tostring(page) }).stdout end

| | |
|---|---|
| `utils.ocr_eng = function(path, page, lang)` | reads a page for OCR in tesseract's place, for each page the indexer reads: the page's text, or a list of lines `{text=, size=, x0=, y0=, x1=, y1=, block=}`, or nil when it cannot |
| `store.calibre = function(book, fields)` | writes a book's changes in calibredb's place, for each book of a write; `fields` as `{title=, authors = "A & B", tags = "a, b", ...}`: true, or nil and why; it takes its own route to calibre |

## Settings: setman

    local pages <const>, ocr <const> = setman.get("pages", "ocr")
    setman.set("ocr", "auto")
    setman.set("ocr", nil)       -- back to what the saved state or the default says
    setman.save()                -- write the saved state now (with persistent = true)
    lulib.opt.ocr = "auto"       -- the same set, through the settings as a table
    lulib.opt.path.library       -- the same get

`get` returns the values in effect, in order. Code that may run again
while it waits (a callback, a command) takes its values once, at its
start, in `<const>` locals: they do not change under it. A `get` later in
the code returns the value at that moment. A set in init.lua, as lulibre
starts, lies under the command line; a set after that replaces the command
line's value. [Configuration](configuration.md) lists the settings and
their precedence.

    setman.create("mine.colour", { default = "red", choices = { "red", "blue" }, help = "a colour of mine" })
    setman.info("mine.colour")   -- {name=, type=, default=, choices=, help=, value=, from=, made=}
    setman.ls()                  -- every setting's name, lulibre's first

`create` makes a setting of the script's own, which `get`, `set`,
`lulib.opt`, `:set`, its completion and the saved state know as they know
lulibre's (`-o help` lists lulibre's alone). `type` is `string`, `path`,
`integer`, `number` or `boolean`, by default as the default is.
`lulibre -o mine.colour=blue` gives it a value before it is made: one
made in init.lua or a packaged module, as lulibre starts, takes it, and a
value for a name nothing has made by then is said and dropped. Made again
under its name (`:restart-scripts`), its definition is replaced and its
value stays when it is still one. `info` says where the value comes from:
`default`, `saved`, `set` (init.lua, a script, `:set`) or `command line`.

## Events: evman

    local id = evman.add("records_changed", function(ev, ...) ... end, ...)
    evman.rm(id)

| Event | Payload |
|---|---|
| `cursor` | `{book=}`: the cursor came to rest on a book |
| `marks` | `{selection = {id, ...}}`: the marks changed |
| `records_changed` | `{ids=, fields=}`: the books' records changed; `fields` lists those lulibre changed, and is empty when the change was made in calibre |
| `holder` | `{holder = "none" \| "server" \| "program" \| "other"}`: who has the library open; `other`, a calibre program with another library open |
| `source_arrived` | `{book=, service=}`: an online answer came |
| `proposed` | `{book=}`: a book's proposals were made anew |

The callback runs as a task with the payload, then the values after the
function. A value given there is taken when `add` is called; a function
given there is called each time the event comes, before any callback
runs, and its results are passed in its place (all of them when it is
last, else the first). So when a value is taken is up to how the call is
written:

    local mode = setman.get("ocr")
    evman.add("cursor", function(ev, m) end, mode)                         -- when added
    evman.add("cursor", function(ev) local m <const> = setman.get("ocr") end) -- when the callback starts
    evman.add("cursor", function(ev, m) end, function() return setman.get("ocr") end) -- as the event comes

`evman.post("source_arrived", {book=, service=})` posts an event as lulibre
does.

## Keys and commands: keymap, cmdman

    keymap.set("n", "<Leader>t", "filter tag:none", { desc = "books with no tags" })
    keymap.set({"n", "v"}, "gx", function(o) print(#o.selection) end)
    keymap.del("n", "<Leader>t")
    keymap.set("review", "y", "accept", { desc = "take it" })   -- a place's or screen's action (keys.md)

    cmdman.create("hello", function(o) print(o.args, o.book, #o.selection) end, { desc = "say hello" })
    cmdman.create("greet", function(o) print("hello " .. o.args) end, {
      desc = "NAME  say hello to NAME",
      complete = { "world", "you" },          -- or "filter", "setting", "command", "help", or
      -- complete = function(lead, line) return { "world", { text = "you", detail = "the reader" } } end,
    })
    cmdman.del("hello")
    cmdman.ls()                 -- waits: every command, { {name=, help=}, ... }, lulibre's and yours
    cmdman.get("hello")         -- waits: one, {name=, help=}, or nil

Modes are `n` (normal) and `v` (selecting). A key's right side is a
command line or a function. A function runs as a task with what the
interface was at when it was invoked: `{name=, args=, book=, selection =
{id, ...}}`, where `name` is the command's name, or a key's keys as
typed. `complete` says what completes the command's arguments at the `:` prompt:
a list of words, the filter language, settings, command names, or a
function. The function runs as a task, asked once each time the
arguments reach a new word, with the word typed so far and the whole
line; its list (words, or `{text=, detail=}`) fills the popup when it
comes, and the prompt narrows it as you type. `cmdman.create` with a name in use replaces that command; in
front of one of lulibre's own, `cmdman.del` and `:restart-scripts` bring
lulibre's back. [Keys and commands](keys.md) has the key notation.

## What scripts reach

| | |
|---|---|
| `taskman` `uiman` `setman` `evman` `keymap` `cmdman` `scrnman` | globals: tasks, the interface, settings, events, keys, commands, screens |
| `lulib` | a global: `version`, `build`, `headless`, `opt` (the settings as a table) |
| `utils` | a global: `exec`, `md5`, `index` (below), and the handler `ocr_eng` (above) |
| `bookman` `store` `wit` `net` `txt` `expr` `lex` `iter` `mesr` `trust` `curl` `sql` `lsqlite3` | modules, by `require` |

## The library: bookman

    local bookman = require "bookman"

| | |
|---|---|
| `bookman.ids(filter)` | `{ id, ... }` |
| `bookman.books(filter)` | `{ book, ... }` |
| `bookman.get(id)` | a book, or nil |
| `bookman.get(id, field)` | the field's value as a string, `""` when it has none (an unknown author too); `identifier:TYPE` one identifier's value; nil when there is no such book |
| `bookman.count(filter)` | number |
| `bookman.authors()` `bookman.tags()` | `{ {name=, books=}, ... }`, most used first |
| `bookman.files(id)` | what the index holds of the book's files: `{ {path=, format=, outcome=, pages=, ...}, ... }` |

A **book** is `{ id, title, authors = {...}, author = "A & B", tags =
{...}, year, pubdate, publisher, series, series_index, lang, idents =
{doi=, isbn=, ...}, formats = {...}, dir }`. Filters are [the filter
language](filters.md).

The index itself is the file `setman.get("path.indexdb")`, and the journal
`setman.get("path.journaldb")`: SQLite files a script reads with `sql`
(below).

### Changing it: store

    local store = require "store"
    local batch, err = store.apply({
      { book = 12, field = "title", value = "Topics in Additive Combinatorics" },
      { book = 12, field = "tags", value = "math", op = "add" },
    }, "a label")                      -- waits
    store.undo(batch)                  -- waits
    store.command({ "add_custom_column", "partof", "Part of", "text" })  -- waits
    store.holder()                     -- "none" | "server" | "program" | "other"
    store.reload()                     -- waits: calibre's records read again, when calibre has changed them

One call is one operation, one batch of the journal. Each change goes to
the store that holds its field, named in the journal: `calibre` for
calibre's records, written by calibredb (or `store.calibre`, above);
`custom` for a field of lulibre's own (`"#name"`); `stage` for a file in
the sync folder (a book id below 0). calibredb runs through calibre's
content server when the server holds the library, on the library's
folder itself when nothing does, and waits while calibre's program has it
open, or a calibre program has another library open. `op` is `set` (the default), `add` or `remove`; add and remove apply
to lists (authors, tags, identifiers, languages) and keep the other items.
Several changes to one field apply in order. A field of lulibre's own is
`"#name"`. A change with `proposal=`, `proposed=` and `source=` keeps where
its value came from; with no `value` it keeps the field as it is, which
records a rejected proposal. `apply` returns nil when nothing was to
change, and nil and why when the operation failed. With the setting
`embed`, each operation also writes the records into the books' files.

## A file's text: txt

    local txt = require "txt"
    local t <close>, err = txt.of(book)   -- waits: the book's file, as lines
    local t <close> = txt.load(file)      -- waits: a file by its id in the index
    local meta = txt.metadata(file)       -- waits: its XMP and Info dictionary, or an EPUB's package document, as text

| | |
|---|---|
| `t.text` | the lines joined: a line break between lines, a blank line before a paragraph, a form feed between pages |
| `#t`, `t:line(i)` | the lines: `{text=, page=, n=, start=, stop=, size=, x0=, y0=, x1=, y1=, math=, bold=, italic=, super=, rotated=, mono=, block=, index=}`; `start` and `stop` as `string.sub` takes them |
| `t:at(pos)` | the line at a position of `t.text`, or nil on a page break |
| `t:largest(page)` `t:height(page)` | the largest line size on a page, and how far down its lines reach |
| `t.meta` | the file's own metadata: `{title=, author=, subject=, keywords=, creator=, producer=}` |
| `t.file` `t.pages` | |

## Patterns: expr

    local expr = require "expr"
    expr.find(s, patt [, init])     -- as string.find
    expr.match(s, patt [, init])    -- as string.match
    expr.gmatch(s, patt)            -- as string.gmatch
    expr.gsub(s, patt, repl [, n])  -- as string.gsub: repl a string, a table or a function

`s` is a string or a txt; `patt` a Lua pattern, or an LPeg pattern made
with LPeg's constructors, which `expr` reaches (`expr.P`, `expr.C`,
`expr.Cmt`, ...). An LPeg pattern is searched for from `init`, as a Lua
pattern is; `-expr.B(1) * patt` matches only at the start. A gsub over a
txt returns a string.

| | |
|---|---|
| `expr.where(test)` | matches, consuming nothing, where the line at the position passes `test(line, t)`; never over a string |
| `expr.largest` `expr.bold` `expr.block` `expr.page(n)` `expr.near_top(share)` | the same, where the line is the largest on its page, bold, a paragraph's first, on page n, in the top share of its page |
| `expr.line` `expr.eol` | a line's text up to its line or page break; the breaks after it |
| `expr.upto(p)` | whole lines up to the first where `p` matches |
| `expr.list(words)` | any of the words or phrases, as whole words, the longest first |
| `expr.chain(step, ...)` | a function applying its steps in order: a function, or `{patt, repl}` for gsub |
| `expr.fold(s)` `expr.lower(s)` `expr.upper(s)` | without case, accents or styled letters (as filters compare); case beyond ASCII |

### Ready-made patterns: lex

    local lex = require "lex"
    expr.match("ISBN 0-387-90040-3", lex.isbn)          --> "9780387900407"
    for doi in expr.gmatch(t, lex.doi) do ... end
    expr.match("arXiv:1012.6008v1 [math.CO]", lex.arxiv) --> "1012.6008", "math.CO"

| | |
|---|---|
| `lex.isbn` | an ISBN, 10 or 13 digits, captured as 13; hyphens between the digits, or spaces after the label ISBN |
| `lex.issn` | an ISSN after its label, captured as `0012-7094` |
| `lex.doi` | a DOI, with or without `doi:` or `https://doi.org/`, captured in lower case without them |
| `lex.labelled` | `{isbn=, doi=, arxiv=}`: the patterns that match only with the label before the number |
| `lex.arxiv` | an arXiv number after `arXiv:`, captured without its version; then the class, when the margin stamp gives one |

An identifier's pattern matches only where its check digit is right, and
captures the canonical form `mesr.canonical` gives.

## Sequences: iter

    local iter = require "iter"
    iter(books):filter(function(b) return b.year end):map(function(b) return b.title end):totable()
    for size, files in iter(files):group(function(f) return f.size end) do ... end

As Neovim's `vim.iter`: over a list (its values), a table (its keys and
values) or an iterator function, and itself a `for` loop's iterator.
`filter`, `map` (an item made nil is dropped), `each`, `fold(acc, f)`,
`totable`, `find`, `any`, `all`, `take(n)`, `skip(n)`, `enumerate`,
`join(sep)`, `next`. And:

| | |
|---|---|
| `it:group(key)` | key and the list of its items, the keys in the order first met |
| `it:diff(other, key)` | the items whose key no item of `other` has |

## Grammars and wits: exprman, wit

    local expr, exprman = require "expr", require "exprman"
    local here = expr.page(1) * expr.bold
    exprman.add("my-series", expr.Ct(expr.upto(here) * exprman.field("title", expr.line) * expr.eol
                                    * exprman.field("authors", expr.line)), "My Series")

A grammar is a pattern matched from the start of a book's text, kept by
name in `exprman`: `exprman.add(name, pattern [, group [, version]])`,
`exprman.remove(name)`, `exprman.names()`, and `exprman.parse(t [, book [,
names]])`, every grammar's parse of a text, or the named ones'. What a grammar
finds in a file is kept until the file is read again or the grammar's
`version` changes: change it when you change the pattern. A book the text
shows to be of `group` raises its grammar's values by `rank_group`. `exprman.field(name, patt)` captures a field's value with its
positions: what `patt` captures, or what it matches when it captures
nothing (`expr.P "KEITH CONRAD" / "Keith Conrad"`). A grammar's pattern
gets the text and the book as LPeg's extra arguments (`expr.Carg(1)`,
`expr.Carg(2)`), so a match-time capture can read what the text does not
hold, the book's record; a field made so is `{ value= }`. A field of
lulibre's own is `"#name"`. `examples/grammars/` has three grammars
written for groups of books. expr's line predicates test the line at the current position:
`expr.largest`, `expr.bold`, `expr.block` (a paragraph's first line),
`expr.page(n)`, `expr.near_top(share)`, and `expr.where(test)` for one of
yours. The packaged grammar is `front` (`exprman._front`).

A **wit** is a value for a book's field, with the source that gave it,
kept until a review writes or rejects it. `:propose` makes them from the
grammars' parses, the file's identifiers and the online records, and adds
them to the current review; `:review` shows it. Accepting and rejecting
only mark; `wit.write` does what is marked. A review keeps its own proposals
and marks, and writing in one changes no other. A field is named as calibre's metadata sources name
it: `title`, `authors`, `publisher`, `series`, `pubdate`, `tags`, and
`identifier:TYPE` for one identifier (`identifier:isbn`, its value
`9780387900407`), which accepting adds to the book's identifiers.

    local wit = require "wit"

| | |
|---|---|
| `wit.set(book, wits [, review])` | replaces the book's wits, keeping what is marked: each `{field=, value=, source=, score=, agree=, disagree=, file=, start=, stop=, hidden=}`, a field's in rank order |
| `wit.get(book [, {review=, deep=}])` | `{ {field=, alts = { {id=, value=, source=, score=, agree=, disagree=, start=, stop=, hidden=, decision=, edited=}, ... } }, ... }`; hidden ones only if deep |
| `wit.accept(id [, value])` `wit.reject(id)` `wit.unmark(id)` | mark a field's wit, or take the mark off |
| `wit.write([review])` | waits: what is marked, as one operation, and takes it from the review: the batch and how many fields |
| `wit.current()` `wit.open(review)` `wit.new([name])` `wit.name(review, name)` `wit.discard(review)` `wit.reviews()` `wit.books([{review=, deep=}])` | the reviews |
| `wit.prune([review])` | drops the proposals whose value the record now holds |
| `lulib._propose.propose(book, w)` | waits: rank the book's values, reading only what was not kept, and keep them in the current review; `w` is `lulib._propose.settings()` |
| `lulib._ids` | a file's identifiers, and which are its own: `in_text`, `in_metadata`, `in_name`, `of`, `book` |
| `lulib._check` | how much of a value is on a file's pages, and whether a record is this book: `count`, `share`, `title`, `length`, `record`, `minor` |
| `lulib._kept` | what was worked out from a file, kept while the file is as it was read |
| `lulib._rank`, `trust`, `lulib._sources` | ranking: coverage, agreement with the sources, and each parse's record of review decisions |
| `mesr.found(value, text [, skip])` | how many of value's words the text holds as whole words, then how many there are; skip, a table of folded words not to count |
| `mesr.cmp(kind, a, b)` `mesr.score(kind, a, b)` `mesr.fuzzy(query, s)` | `"equal"`, `"contains"`, `"contained"`, `"near"` or `"differs"`, then both scores; kind `text`, `people`, `tags`, `date`, `ident`, or a field's name, compared as its kind (`pubdate` as a date, `identifier:isbn` as an identifier) |

## Online lookups

    local net = require "net"
    net.ask("crossref", "10.1000/xyz")   -- waits: the answer, false when there is no record, or nil and why
    net.enrich(book)                     -- waits: asks every service the book's identifiers allow
    net.records(book)                    -- the kept answers, as fields

A service is defined with `require("net.service").define(name,
{ident=, pace=, hold=, batch=, request=, record=})`; Crossref, Open
Library and arXiv come with lulibre. Every answer is kept, for every
library, in the file `path.netdb`, and a kept one is not
asked for again. A service is asked no
sooner than its pace, as many works at once as its batch, and is left
alone for its hold when it says it is asked too much.

## Databases: sql

    local sql = require "sql"
    local db = sql.open(path)                 -- raises when it cannot
    for _, row in ipairs(sql.run(db, "SELECT name FROM t WHERE instr(fold(name), ?) > 0", "erdos")) do ... end

| Call | Does |
|---|---|
| `sql.open(path [, flags])` | an lsqlite3 connection, waiting up to 5 seconds for a write another holds; by default read and write, the file and its folders made when not there; `flags` as lsqlite3's (`sqlite3.OPEN_READONLY`) |
| `sql.run(db, query, ...)` | the rows, each a table by column name, with the values bound to the `?`s; raises the error |

The connection is
[lsqlite3](https://lua.sqlite.org/home/doc/tip/doc/lsqlite3.wiki)'s, built
into lulibre, with everything else it does. Every connection it opens has lulibre's two SQL functions:
`fold(s)`, s without case, accents or styled letters, the key filters
compare by; and `find(s, pattern)`, a Lua pattern match. Queries
run on the Lua thread and do not wait like the calls above: a long one
holds the other tasks up.

## Requests: curl

    local curl = require "curl"
    local r, err = curl.req(url, { method = "PUT", headers = { ["User-Agent"] = "me" },
                                      body = "...", timeout = 5000 })
    -- waits: { status=, headers=, body=, url= }, or nil and why

libcurl on lulibre's own loop: a task waits for its answer while the
others run, any number of requests run at once, and a cancelled task's
request is cancelled with it. Every status is an answer; an error is a
request that got none (refused, timed out, cancelled). Redirects are
followed, and `url` is where the answer came from. `headers` are by
lower-case name, repeated ones joined by ", ". The method is GET, or POST
with a body; `timeout` is in milliseconds.

## The interface: uiman

| | |
|---|---|
| `uiman.notify(msg [, "error"])` `print(...)` | the message line, and the log |
| `uiman.exec(line)` | run a command line |
| `uiman.mark(id [, on])` | |
| `uiman.jump(id)` | waits: the list's cursor to a book; false if the book is not in the list |
| `uiman.filter([text])` | waits: the filter, or set it |
| `uiman.pick(items [, {title=}])` | waits: the item picked and its index, or nil |
| `uiman.input{prompt=, default=, suggestions=, separator=, on_change=}` | waits: the text, or nil |
| `uiman.key(command [, mode])` | waits: the keys bound to a command line, or nil |
| `uiman.pager(title, text [, {markdown = true}])` | the text in the pager, as `?` and the guides are shown: in a plain text, a line that does not begin with a space is a heading; Markdown is laid out, and its links lead into the guides |
| `uiman.maps()` | waits: every global binding, `{modes=, keys=, command=, about=, hidden=}`; a key bound to a function has `callback`, the function, in place of `command` |
| `scrnman.create(name, {title=, actions=, hint=, place=, tab=, views=})` | a screen: its actions (`{name, keys, what it does}`) and those its hint shows; where its views go, `place = {kind=, size=}` with kind `band` (along the bottom), `column` (down the left), `over` (in the list's place), `tiled` (beside the focused window), `float` (a box above the windows) or `overlay` (over all of them), unless the one opening a view says otherwise; `tab = true` gives it a tab in the bar, which runs the command named as the screen, and its view stands in the list's place while it is open. `views = { about = {kind=, size=} }` names windows beside the main one: `uiman.panel{screen = name, view = "about"}` opens one, and it closes with the screen's main panel. Made again under its name, it replaces the one before |
| `scrnman.set(name, {hint=, title=, place=})` | a screen's, or one of lulibre's places' (`console`, `pager`, `picker`, `select`, `panel`, `line`), hint and title; `hint = {}` shows none. `place = {kind=, size=}` moves a screen's views, the console (the next time it opens) or `preview` (`band`, `column` or `tiled`, at once). Until `:restart-scripts` |
| `uiman.panel{...}` | a panel of rows the task that opened it steers; with `screen=`, a key bound to one of the screen's actions comes back from `p:wait()` as the action's name; with `form = true`, its rows (`{label, value}`) are a form's fields, and the place `form`'s `edit` asks for a field's value on the line, `p:wait()` returning `"edit"`, the row and the value; `p:wait()` waits for its keys; one task at a time waits on a panel, and a second one's `p:wait()` raises |
| `uiman.clipboard([text])` `uiman.edit_file(path)` `uiman.in_terminal(argv)` | wait |
| `uiman.progress(text)` `uiman.status(name, text [, style])` `uiman.log(text [, level])` | |
| `uiman.theme.<name> = colour` | the interface's colours |

`uiman.list` shows a sequence, one item to a row, and `uiman.form` a
record, one field to a row. Each waits until it is closed, and reads its
items again after each key it handles and each event it refreshes on.
Without the interface (`lulibre run`) a list prints its rows.
Both take `uiman.panel`'s `title`, `help`, `columns`, `follow`, `preview`,
`height`, `side`, `focus`, `dialog`, `pass` and `screen`.

A list's keys are a screen's actions: `scrnman.create` names the screen
and its actions, with the keys each is on by default and what it does;
`keymap.set(screen, key, action)` rebinds them as it rebinds a place's
(keys.md), and the list's bar shows the hint's actions with the keys they
are on now. A key bound to no action of the screen does nothing in it,
but for `?`, which shows help with the screen's actions first.

    scrnman.create("todo", {
      actions = { { "mark", "t", "tag the book todo" } },     -- name, keys, what it does
      hint = { "mark" },                                     -- shown in the bar
    })
    uiman.list {
      title = "books", screen = "todo", columns = { "Title", "Authors" }, follow = true,
      items = function() return bookman.books("tag:none") end,   -- a list, an iter, or a function giving one
      row = function(b) return { b.title, b.author, id = b.id } end,
      actions = { mark = function(b) return store.apply({ { book = b.id, field = "tags", value = "todo", op = "add" } }) end },
      refresh = { "records_changed" },     -- or { records_changed = function(ev) ... end }, run first
    }

    uiman.form {
      title = "pages", record = function() return { pages = setman.get("pages") } end,
      fields = { { "pages", "Pages read" } },                  -- names, or { name, label }
      edit = function(field, value) setman.set(field, value) end,
    }

| | |
|---|---|
| `items` | a list, an iter, or a function giving one |
| `row(item)` | the item's cells, with `id=` (a book) and `style=` as a panel's rows; by default the item itself when it is a table, else the item as text |
| `screen` | the screen it is (`scrnman.create`); a form's keys are the place `form`'s (`edit`, on e and Enter), and a screen given to it adds its actions |
| `actions` | `{ [action] = function(item, i) }`: what one of the screen's actions does to the item under the cursor; its error, raised or nil and why, is shown |
| `refresh` | event kinds that read the items again |
| `record` | a form's record: a table, or a function giving it |
| `fields` | the fields a form shows, in order; by default every one, by name |
| `edit(field, value, record)` | takes a field edited by the screen's action `edit`; nil and why refuses it |

## Tasks, processes, indexing: taskman, utils

| | |
|---|---|
| `taskman.spawn(fn, ...)` | a task running `fn(...)`; its id |
| `taskman.sleep([ms])` | waits: ms milliseconds, or with none until `taskman.wake` |
| `taskman.wake(id)` | ends task id's sleep now, timed or not: true if it slept |
| `taskman.self()` | the running task's id; nil outside a task |
| `taskman.yield()` | waits: the other tasks take a turn |
| `taskman.tasks()` `taskman.cancel(id)` | |
| `utils.exec(argv [, {stdin=, cwd=, timeout=}])` | waits: `{code=, stdout=, stderr=, ...}` |
| `utils.index{pages=, force=, filter=}` | waits: index the files |
| `utils.md5(path)` | waits: the file's MD5, kept in the index |

Each C module documents itself at the top of its `src/lua/l_*.c`.
