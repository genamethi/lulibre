# Lua API

lulibre runs Lua 5.4 or 5.5. `~/.config/lulibre/init.lua` runs at start, as
the first task. Empty, or missing, lulibre works the same: everything
below is there without it.

    :run NAME [args]            a script from ~/.config/lulibre/scripts
    lulibre run FILE [args]     a script with no interface; print goes to stdout
    :restart-scripts            a new Lua state; init.lua runs first, as at start
    :tasks   :cancel ID|all

## How scripts run

There is one Lua state. With the interface up it lives on a thread of its
own, with its own event loop and its own connection to the index;
headless, there is one thread. The interface and Lua talk by messages, and
neither waits for the other: a call that answers nothing is sent and
returns at once, and a call that answers (marked *waits* below) pauses its
task until the answer comes.

Scripts run as **tasks** that take turns: a script, a command's function,
a key's function, a callback, init.lua. A task gives the others their turn
where it waits, and only there (or at `lulibre.yield()`): what it does
between two waits, no other task sees half done. A task that computes for
long holds the other tasks up, not the interface; after 2 s without
waiting it is reported, and `:cancel` stops it. A function that waits
must be called from a task.

A resource lives on the stack of the task that opened it: hold it in a
`<close>` variable, and it is released at the end of its scope, or when
the task fails or is cancelled.

    local reading = require "lulibre.reading"
    local r <close> = reading.of(book)

`:restart-scripts` tears the state down and makes it again. The commands,
keys and callbacks Lua made go with the old state; the settings stay.

## Overriding lulibre's own behaviour

Redefine the function, from init.lua or a module of yours. lulibre calls
every function meant to be overridden through its module's table, at the
time of the call, so the redefinition takes effect from the next call.

    local proposals = require "lulibre.proposals"
    local normalize = proposals.normalize
    function proposals.normalize(field, value)
      if field == "publisher" then value = value:gsub("^The ", "") end
      return normalize(field, value)
    end

No file of yours replaces a packaged module: lulibre's own modules are
found first, then `lua/` in the configuration folder, then the module
prefix `mod_tree` names.

Two parts are C's unless a function of yours takes their place:

| | |
|---|---|
| `lulibre.ocr.read(path, page, lang)` | reads a page for OCR in tesseract's place: the page's text, or a list of lines `{text=, size=, x0=, y0=, x1=, y1=, block=}`; `ocr.read = nil` gives it back |
| `lulibre.stores.calibre(book, fields)` | writes a book's changes in calibredb's place: true, or nil and why; it takes its own route to calibre |

## Settings: setman

    local pages <const>, ocr <const> = setman.get("pages", "ocr")
    setman.set("ocr", "auto")
    setman.set("ocr", nil)       -- back to what the command line, the saved state or the default says
    setman.save()                -- write the saved state now (with persistent = true)

`get` returns the values in effect, in order. Code that may run again
while it waits (a callback, a command) takes its values once, at its
start, in `<const>` locals: they do not change under it. A `get` later in
the code returns the value at that moment. [Configuration](configuration.md)
lists the settings and their precedence.

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

## Keys and commands: keymap, cmd

    keymap.set("n", "<Leader>t", "filter tag:none", { desc = "books with no tags" })
    keymap.set({"n", "v"}, "gx", function(o) print(#o.selection) end)
    keymap.del("n", "<Leader>t")

    cmd.create("hello", function(o) print(o.args, o.book, #o.selection) end, { desc = "say hello" })
    cmd.del("hello")

Modes are `n` (normal) and `v` (selecting). A key's right side is a
command line or a function. A function runs as a task with what the
interface was at when it was invoked: `{name=, args=, book=, selection =
{id, ...}}`. [Keys and commands](keys.md) has the key notation.

## The library

| | |
|---|---|
| `lulibre.ids(filter)` | `{ id, ... }` |
| `lulibre.books(filter)` | `{ book, ... }` |
| `lulibre.book(id)` | a book, or nil |
| `lulibre.count(filter)` | number |
| `lulibre.authors()` `lulibre.tags()` | `{ {name=, books=}, ... }`, most used first |
| `lulibre.sql(sql, ...)` | rows of a read-only query against the index; the journal is `history.journal` |
| `lulibre.store(sql, ...)` | the same, but may write lulibre's own tables: proposals, lookups, kv, staged, custom fields |
| `lulibre.reload()` | waits: read calibre's records again, when calibre has changed them |

A **book** is `{ id, title, authors = {...}, author = "A & B", tags =
{...}, year, pubdate, publisher, series, series_index, lang, idents =
{doi=, isbn=, ...}, formats = {...}, dir }`. Filters are [the filter
language](filters.md).

### Changing it: lulibre.library

    local library = require "lulibre.library"
    local batch, err = library.apply({
      { book = 12, field = "title", value = "Topics in Additive Combinatorics" },
      { book = 12, field = "tags", value = "math", op = "add" },
    }, "a label")                      -- waits
    library.undo(batch)                -- waits
    library.command({ "add_custom_column", "partof", "Part of", "text" })  -- waits
    library.holder()                   -- "none" | "server" | "program" | "other"

One call is one operation, one batch of the journal. It runs through
calibre's content server when the server holds the library, straight to
the folder when nothing does, and waits while calibre's program has it
open, or a calibre program has another library open. `op` is `set` (the default), `add` or `remove`; add and remove apply
to lists (authors, tags, identifiers, languages) and keep the other items.
Several changes to one field apply in order. A field of lulibre's own is
`"#name"`. A change with `proposal=`, `proposed=` and `source=` keeps where
its value came from; with no `value` it keeps the field as it is, which
records a rejected proposal. `apply` returns nil when nothing was to
change, and nil and why when the operation failed. With the setting
`embed`, each operation also writes the records into the books' files.

## Reading files

    local reading = require "lulibre.reading"
    local r <close>, err = reading.of(book)   -- waits: the book's file, as lines
    local r <close> = reading.load(file)      -- waits: a file by its id in the index

| | |
|---|---|
| `r.text` | the lines joined: a line break between lines, a blank line before a paragraph, a form feed between pages |
| `#r`, `r:line(i)` | the lines: `{text=, page=, n=, start=, stop=, size=, x0=, y0=, x1=, y1=, math=, bold=, italic=, super=, rotated=, mono=, block=, index=}`; `start` and `stop` as `string.sub` takes them |
| `r:line_at(pos)` | the line at a position of `r.text`, or nil on a page break |
| `r:largest(page)` `r:height(page)` | the largest line size on a page, and how far down its lines reach |
| `r.meta` | the file's own metadata: `{title=, author=, subject=, keywords=, creator=, producer=}` |
| `r.file` `r.pages` | |

## Grammars and proposals

    local grammar = require "lulibre.grammar"
    local lpeg = require "lpeg"
    local field, line, eol = grammar.field, grammar.line, grammar.eol
    local here = grammar.page(1) * grammar.bold
    grammar.add("my-series", lpeg.Ct(grammar.skip_to(here) * field("title", line) * eol * field("authors", line)),
                "My Series")

A grammar is an LPeg pattern matched from the start of a reading's text.
`field(name, patt)` captures a field's value with its positions. The
predicates test the line at the current position: `largest`, `bold`,
`block` (a paragraph's first line), `page(n)`, `near_top(share)`, and
`at(function(line, reading) ... end)` for one of yours. `skip_to(p)` passes
whole lines up to the first where `p` holds. `grammar.parse(r)` returns
every grammar's parse of a reading.

| | |
|---|---|
| `proposals.propose(book, w)` | waits: read, parse, rank and keep the book's proposals; `w` is `proposals.settings()` |
| `proposals.of(book)` | `{ {field=, alts = { {id=, value=, parse=, score=, agree=, disagree=}, ... } }, ... }` |
| `proposals.accept(id [, value])` | waits: the proposal, or the value edited from it, as an operation |
| `proposals.reject(id)` | waits: kept in the journal; the field keeps its value |
| `lulibre.rank`, `lulibre.track`, `lulibre.sources` | ranking: coverage, agreement with the sources, and each parse's record of review decisions |
| `lulibre.similar.compare(kind, a, b)` | `"equal"`, `"contains"`, `"contained"`, `"near"` or `"differs"`, then both scores; kind `text`, `people`, `tags`, `date`, `ident` |

## Online lookups

    local net = require "lulibre.net"
    net.ask("crossref", "10.1000/xyz")   -- waits: the answer, false when there is no record, or nil and why
    net.enrich(book)                     -- waits: asks every service the book's identifiers allow
    net.records(book)                    -- the kept answers, as fields

A service is defined with `require("lulibre.net.service").define(name,
{ident=, pace=, hold=, batch=, request=, record=})`; Crossref, Open
Library and arXiv come with lulibre. Every answer is kept in the index's
`lookups`, and a kept one is not asked for again. A service is asked no
sooner than its pace, as many works at once as its batch, and is left
alone for its hold when it says it is asked too much.

## The interface

| | |
|---|---|
| `lulibre.notify(msg [, "error"])` `print(...)` | the message line, and the log |
| `lulibre.exec(line)` | run a command line |
| `lulibre.mark(id [, on])` `lulibre.jump(id)` | |
| `lulibre.filter([text])` | waits: the filter, or set it |
| `lulibre.pick(items [, {title=}])` | waits: the item picked and its index, or nil |
| `lulibre.input{prompt=, default=, suggestions=, separator=, on_change=}` | waits: the text, or nil |
| `lulibre.key(command [, mode])` `lulibre.maps()` `lulibre.commands()` | waits |
| `lulibre.panel{...}` | a panel of rows the task that opened it steers; `p:wait()` waits for its keys |
| `lulibre.clipboard([text])` `lulibre.edit_file(path)` `lulibre.in_terminal(argv)` | wait |
| `lulibre.index{pages=, force=, filter=}` | waits: index the files |
| `lulibre.system(argv [, {stdin=, cwd=, timeout=}])` | waits: `{code=, stdout=, stderr=, ...}` |
| `lulibre.spawn(fn, name)` `lulibre.sleep(ms)` `lulibre.yield()` | tasks |

Each C module documents itself at the top of its `src/lua/l_*.c`.
