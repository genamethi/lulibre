# Lua API

Scripts are written in Lua 5.4 or 5.5 and use one table, `lulibre`.

    :run NAME [args]            a script from ~/.config/lulibre/scripts or the bundled ones
    :lua lulibre.count("no:ids")
    lulibre run NAME [args]     the same script with no interface; print goes to stdout
    :tasks   :cancel ID|all

The [API reference](reference/index.html) documents each Lua module and its functions.

A script gets its arguments as `...`. `lulibre.headless` is true when there
is no interface. Each C module is documented at the top of its
`src/lua/l_*.c`, and this page sums them up. A name that begins with `_`
(`lulibre._place_map`) is internal to lulibre's Lua runtime and may change
without notice.

## How scripts run

With the interface up, Lua runs on its own thread, with its own event loop
and its own connection to the index, so a script never delays a keystroke.
Headless, there is one thread.

Scripts run as **tasks** that take turns. A function marked *waits* below
pauses its task until the result arrives, so call it from a task: a
script, a command, or `lulibre.spawn(function() ... end)`. A task that only
computes is paused every few milliseconds so other tasks get a turn.

A turn can end between any two Lua operations, so tasks must not count in
a shared variable: `n = n + 1` can lose a count. Use `lulibre.each`, store
results on the items, or use `table.insert`. A test and a set (`if not busy
then busy = true`) is not one step either; use `lulibre.claim(t, key)`.
Build a table that other tasks read in a local, and put it in place with
one assignment.

Headless, `lulibre run` ends when no task is running and nothing the tasks
started is pending. A luv handle left open (a timer, a socket) keeps the run
going, so close what you open. An error in a luv callback is reported and
makes the run exit with status 1, as a task's error does.

## The library

| | |
|---|---|
| `lulibre.ids(filter)` | `{ id, ... }` |
| `lulibre.books(filter)` | `{ book, ... }` |
| `lulibre.book(id)` | a book, or nil |
| `lulibre.count(filter)` | number |
| `lulibre.authors()` `lulibre.tags()` | `{ {name=, books=}, ... }`, most used first |
| `lulibre.sql(sql, ...)` | rows of a read-only query against the index |
| `lulibre.store(sql, ...)` | the same, but may write lulibre's own tables (`proposals`, `journal`, `kv`, `staged`, `good`, `terms`, `refs`, `lookups`); returns rows, rows changed, last insert id |
| `lulibre.reload()` | pick up changes calibre has made |
| `lulibre.stage_refresh()` | after writing the `staged` table (the sync folder's files), rebuild the books with negative ids that represent the files |
| `lulibre.source([name])` | what the list shows, `"library"` or `"sync"`; sets it if given |

Filters use [the filter language](filters.md). A filter without `in:`
applies to what the list is showing (the library, when headless).

A **book** is

```lua
{ id = 12, title = "...", author = "A & B", authors = { "A", "B" }, tags = { ... },
  year = 1996, pubdate = "1996-05-01", publisher = "...", series = "...", series_index = 3,
  lang = "eng", idents = { doi = "10.1/x", isbn = "..." }, formats = { "PDF" }, dir = "..." }
```

Library books have positive ids, and files staged from the sync folder have negative ids.

## Text and files

| | |
|---|---|
| `lulibre.text(id [, page])` | the indexed text of one page, or of all indexed pages joined by form feeds. The text comes from the book's best-read file, a PDF first; `text`, `lines`, `page_put`, the preview and verify's evidence all use that file |
| `lulibre.text_measure(id)` | measure the text the index holds for a book's files again (characters, quality), as indexing would now. Use it after the measure has changed, or after text was stored by other means. Returns how many files were measured |
| `lulibre.lines(id [, page])` | the page as lines: `{ {text=, size=, bold=, italic=, super=, rotated=, mono=, block=, x0=, y0=, x1=, y1=, math=}, ... }`. `math` is the line with its mathematics marked up as TeX, if it has any |
| `lulibre.files(id)` | `{ {path=, format=, status=, pages=, chars=, quality=, error=, title=, author=, ...}, ... }`, the book's file first |
| `lulibre.extract(path [, {pages=, layout_pages=, tail=}])` | *waits.* Reads any file now: `{ pages=, chars=, quality=, meta={...}, page={ {text=, lines=}, ... } }`, or nil and an error |
| `lulibre.render(path, page [, width])` | *waits.* Returns the page as a greyscale PGM string |
| `lulibre.page_put(id, page, {text=, lines=, src=})` | replace a page's indexed text in the book's file, as OCR does |
| `lulibre.md5(path)` | *waits* the first time. Returns the content hash, stored in the index |
| `lulibre.index([{filter=, force=, retry=}])` | *waits.* Extracts text from new or changed files (all files with `force`, only matching books with `filter`): `{ files=, queued=, ok=, failed=, missing=, seconds= }` |

## Changing the library

| | |
|---|---|
| `lulibre.apply{ {id=, field=, value=, op=}, ... }` | *waits.* Writes changes now, as one batch that can be undone. Returns `{ batch=, books=, applied=, unchanged=, failed={...}, links= }` |
| `lulibre.propose(id, field, value [, {op=, source=, confidence=}])` | queue a change for review (`gr`) |

`field` is one of `title authors tags series series_index publisher pubdate
identifiers languages`. `op` is `"set"` (the default), or `"add"` /
`"remove"` for the list fields. `require "lulibre.edit"` has more:
`current(book, field)`, `undo([batch])`, `history()`, `remove(ids)`,
`route()`.

## The interface

| | |
|---|---|
| `lulibre.notify(msg [, "error"])` | the message line (stderr when headless) |
| `print(...)` | the same; stdout when headless |
| `lulibre.log(text [, level])` | the log console: `"info"`, `"warn"`, `"error"`, `"debug"` (debug builds only) |
| `lulibre.progress(text \| nil)` | a note in the status line while a script works |
| `lulibre.status(name, text \| nil [, style])` | a badge in the status line, beside the mode, under a name of your own. Call it again to change the badge, or with `nil` to remove it. `style` is `accent` (the default), `ok`, `warn`, `error` or `dim`. At most six badges show at once |
| `lulibre.current()` | the id under the cursor |
| `lulibre.selection()` | the ids an action applies to. With the cursor in a panel that follows the list, the book of the panel's row; an error if that book is not in the list |
| `lulibre.mark(id [, on])` | mark, unmark, or toggle a book |
| `lulibre.filter([expr])` | get or set the list filter |
| `lulibre.jump(id)` | move the cursor to a book |
| `lulibre.exec(line)` | run a command line |
| `lulibre.command(name, fn [, help])` | define a `:` command; `fn(args)` runs as a task |
| `lulibre.commands()` | every command, built in and defined: `{ {name=, help=}, ... }` |
| `lulibre.map(modes, keys, target [, about])` | bind keys to a command line or a function. `about` is what `?` shows for the key; `false` leaves the key out. With a panel's name for `modes` (`"review"`), or a place's name (`"panel"`, `"line"`, `"picker"`, `"pager"`, `"console"`), bind a key to one of its actions |
| `lulibre.key(command [, mode])` | the keys bound to a command line (`"gr"`), or nil |
| `lulibre.hint(command)` | the same, for a message: the keys, or `":command"` if there are none |
| `lulibre.maps()` | every global binding: `{ {modes=, keys=, command=}, ... }` |
| `lulibre.place_keys(place)` | the keys of `"panel"`, `"line"`, `"picker"`, `"pager"` or `"console"`, as lines of text |
| `lulibre.input{prompt=, default=, suggestions=, separator=, on_change=}` | *waits.* Returns a line of text, or nil |
| `lulibre.confirm(question)` | *waits.* Returns true for y or yes |
| `lulibre.pick(items [, {title=}])` | *waits.* Fuzzy-picks one item: returns the item and its index |
| `lulibre.show(text [, title])` | a scrollable overlay; text may be a list of lines |
| `lulibre.clipboard(text)` | copy text |
| `lulibre.clipboard()` | what was copied last, or nil |
| `lulibre.policy(option, question)` | apply an `auto` / `ask` / `never` option: returns true or false |

### Panels

A panel is a table of rows that a script fills and controls. The edit
form, review and the tree browser are written in Lua on top of panels.

```lua
local p <close> = lulibre.panel {
  title = "pick one", help = "Enter choose   q close",
  columns = { { "Id", 6 }, "Title", { "Year", 4 } },   -- width; 0 or less is a share of the rest
  rows = { { 12, "A title", 1996, id = 12, style = "ok" } },
  follow = true,        -- moving through rows moves the list to row.id
  height = 0.4,         -- or side = "left", width = 0.3
  keys = { "<CR>" },    -- the keys this script handles, and
  pass = "preview yank",-- the global commands its other keys may still reach
  tabs = { "this run (9)", "all waiting (212)" }, tab = 1,   -- names in the bar, one of them in view
}
while true do
  local key, row = p:wait()        -- nil once the panel is closed
  if not key then break end
  if key == "<CR>" then lulibre.notify("row " .. row) end
end
```

Methods: `p:rows(rows)`, `p:title(s)`, `p:help(s)`, `p:columns(cols)`,
`p:cursor([row])`, `p:wait()`, `p:close()`, `p:is_open()`, `p:hide()` and
`p:show()` (take the panel off the screen and back, around a panel opened
on top of it), `p:focus()` (move the cursor to the panel),
`p:height(share)`, `p:keys(list)`, `p:tabs(names, current)`,
`p:send(key [, row])`.

Row styles are `dim accent ok warn error`, plus `head` and `note`, which
show their first cell across the whole width (for a heading, or text too
long for a column).

With `moves = true`, `wait()` also returns `"<Move>"` when the cursor
moves. With `reloads = true`, it returns `"<Reload>"` when the library has
been read again, so the script can update the rows. `Esc` in a panel goes
back to the window you came from and leaves the panel open. With
`dialog = true` (a form that asks something), `Esc` closes the panel, as
`q` does.

Tabs are names drawn in the bar after the title, with the current tab
highlighted. If they don't all fit, the strip scrolls to keep the current
tab visible. The panel only draws the tabs: the script switches tabs on
keys of its choosing, and sets them again with `p:tabs`. A click on a tab
makes `wait()` return `"<Tab>"` and the tab's number.

`p:send(key)` makes `wait()` return `key`, from another task. A script that
doesn't own the panel uses it to tell the panel that something it shows
has changed.

A panel normally takes every key. With `keys` and `pass` given, a key that
is not in `keys` and starts a global binding to one of the `pass` commands
(named by their first word) runs that binding instead. That is how `P` and
`]` reach the preview from inside review. If a following panel's row is a
book the list does not hold, the preview shows that book anyway.

A script can open the edit form or review for given books:
`require("lulibre.ui.edit").run { ids = { 12 } }`, and the same for
`lulibre.ui.review`. `require("lulibre.ui.panels").over(p, fn, ...)` runs
`fn` with panel `p` out of the way.

## Tasks, processes, helpers

| | |
|---|---|
| `lulibre.spawn(fn, ...)` | run `fn` as a task; returns its id |
| `lulibre.each(items, fn [, {jobs=, progress=}])` | *waits.* `fn(item, index)` over a list, several at a time |
| `lulibre.sleep(ms)` | *waits* |
| `lulibre.yield()` | give others a turn now |
| `lulibre.tasks()` `lulibre.cancel(id)` `lulibre.task_id()` | |
| `lulibre.claim(t, key [, value])` | sets `t[key]` to `value` (true by default) if it is nil, in one step. Returns true if this call set it. Tasks can be interrupted between any two Lua operations, so a test followed by a set is not one step. Release the claim with `t[key] = nil` |
| `lulibre.system({"prog", "arg"} [, {stdin=, cwd=, timeout=}])` | *waits.* Returns `{ code=, signal=, stdout=, stderr=, timed_out= }`, or nil and a message |
| `lulibre.fold(s)` | the search key: lower case, accents removed |
| `lulibre.lower(s)` `lulibre.upper(s)` | change case beyond ASCII: accented Latin, Greek, Cyrillic |
| `lulibre.titlecase(s)` | the title in title case (APA) |
| `lulibre.phrases(text)` | the distinct two- and three-word phrases of a text |
| `lulibre.counter()` | counts phrases, or whole lines, over many texts: `c:add(text)`, `c:prune(min [, max])`, `c:of(text)`, `c:count(phrase)`, `c:add_lines(text [, same])`, `c:strip(text, min)`, `c:close()` (frees its memory now; Lua's collector does not see it) |
| `lulibre.fuzzy(query, candidate)` | a score, or nil |
| `lulibre.inspect(value)` | any value as readable text |
| `lulibre.uv`, `require "luv"` | libuv, on the loop Lua runs on |

## Settings

| | |
|---|---|
| `lulibre.o.name` | read or write an option (nil resets it to its default); see [Configuration](configuration.md) |
| `lulibre.setup{ name = value, ... }` | set several options at once |
| `lulibre.settings.get(name)` | read an option, as a function; with no name, every option as a table |
| `lulibre.settings.set(name, value)` | set an option, or several with `set{ pages = 8, ocr = "auto" }` |
| `lulibre.settings.reset(name)` | reset an option to its default |
| `lulibre.settings.names()` | option names, in order |
| `lulibre.settings.info(name)` | `{ name=, value=, default=, type=, choices=, help= }` |
| `lulibre.settings.paths()` | `{ config_dir=, init=, scripts=, modules=, data_dir=, index=, library=, installed=, bundled = { modules=, scripts= } }`. `scripts` and `modules` are yours; `bundled` is lulibre's own, in the runtime in use |
| `lulibre.theme.name = "#rrggbb"` | set a colour; `lulibre.theme()` lists them |
| `lulibre.version` | `"0.2.0-dev"` |
| `lulibre.build` | `{ version=, major=, minor=, patch=, pre=, debug=, lua=, number=, commit= }`. `number` is this build's number among the builds of its version (`"007"`) |

The configuration directory is the option `config_dir`:

```lua
lulibre.settings.get("config_dir")                 -- "/home/me/.config/lulibre"
lulibre.settings.set("config_dir", "~/dotfiles/lulibre")
```

Reading it gives the directory in use. Setting it changes where scripts and
modules are looked for from then on. Which `init.lua` is loaded was decided
at startup (`lulibre -C DIR`, or `$LULIBRE_CONFIG_DIR`).

## Modules

The part of lulibre written in Lua is under `lua/lulibre/`. The
[API reference](reference/index.html) documents each module in full; this table
sums them up.

| `require` | |
|---|---|
| `lulibre.edit` | apply, undo, history, remove; a field's current value; the write route |
| `lulibre.proposals` | add, list, accept, apply |
| `lulibre.quality` | a record's score, and the confirmed ones: `score(book)`, `ranked(opts)`, `set_good(ids, on)`, `is_good(id)`, `good_ids()`, `catchall(subject)` |
| `lulibre.learn` | learns which phrases mark a subject: `run()`, `terms(subject)`, `set(subject, phrase, state)`, `classify(text [, model])`, `suggest(text [, model])`, `candidate(id)`. Without storing the result: `census()`, `work{from=, census=}`, `model(got)`. `FURNITURE` lists phrases that are never learned |
| `lulibre.verify` | checks values against the book's own file: `evidence(id)` (the opening pages, or nil and why they can't be read), `title(ev, t)` → shown/partly/absent/unknown and the share, `phrase(ev, t)` (the share found in order), `headline(ev, t)` (in the largest font), `authors(ev, names)` → verdict, shown, named, `ident(ev, "doi:...")` → own/front/inside/cited/absent/unknown, `size(ev, rec)` → part/whole/larger, `record(ev, rec)` → `{title=, authors=, another=, part=, unread=}`, `book(id)` |
| `lulibre.doc_metadata(path)` | *waits* in a task, while a worker reads the file. Returns a PDF's XMP packet and Info dictionary, or an EPUB's package, as text. `require("lulibre.ids").from_metadata(text)` → `{ {kind=, value=, where=} }` |
| `lulibre.ui.context` | what a proposal is based on, for review's context panel: `rows(pr, others)`, `record_of(pr)` (the stored record a proposal came from, or that an identifier leads to), `source_class(src)` |
| `net.kept_record(kind, value)` | the stored record for a DOI, ISBN or arXiv number, without asking anyone. `net.arxiv_by_title(path, {[net.title_key(t)]=true})` looks papers up by title in arXiv's snapshot |
| `lulibre.panel{ side = "main" }` | a panel in the list's window for a while; the list comes back when the panel closes, and the focus stays where it was |
| `lulibre.panel{ preview = id or text }`, `p:preview(v)` | what the preview shows while the panel is open, whatever row the cursor is on: a book, or a note instead of one. `nil` lets the rows decide again |
| `require("lulibre.ui.panels").open(name, spec)` | opens a screen's panel with `lulibre.panel(spec)`, one per name at a time. If that screen is already open, moves the cursor to it, says so, and returns nil, so the screen returns. `panels.again(fn, ...)` runs fn and lets it open a second copy, as `:new` does |
| `require("lulibre.ui.panels").about(p, {fill=, columns=, title=, keys=}, row)` | a screen's "about" panel in place of the list, like review's. `fill(row)` returns its rows and title. `:update(row)`, `:toggle(row)`. It moves aside with `panels.over` |
| `lulibre.option(ns, { name = { default=, type=, choices=, help= } })` | declares a script's options and returns the namespace to read them from. `lulibre.cfg.NS.NAME` reads or sets one. `require "lulibre.options"` has `declare`, `get`, `set(ns, name, v, "file"|"script"|"session")`, `reset`, `from`, `list`, `namespaces` |
| `lulibre.config_file` | writes options to init.lua: `missing()`, `add(items)`, `write_value(item, v)` (nil resets to the default), `line_of(item)` |
| `lulibre.features` | finds the programs features need: `find(program)`, `status(f)`, `need(name)` (may offer pixi), `declare{ name=, programs=, used_for=, packages=, pixi= }` |
| `lulibre.in_terminal(argv)` | runs a program in the terminal, handing the terminal over as for the editor (headless: on the terminal lulibre runs in). Returns its exit status, or nil and a message |
| `lulibre.edit_file(path)` | opens a file in `$VISUAL`/`$EDITOR` (vim, vi), handing the terminal over. Returns the exit status |
| `lulibre.require_rock(module [, rock])` | requires a module, offering to install it into `mod_tree` if `rocks_install = true` |
| `lulibre.grammars` | recognises documents by their opening lines: `add{ name=, kind=, lines = { G.line{...}, G.skip(n), G.opt(r), G.either{...} }, text=, pages=, read=, noncatalog=, confidence= }`, `remove(name)`, `match(doc)` → `{ {grammar=, fields=} }`, `doc(id)` |
| `lulibre.ids` | finds identifiers in page text: DOIs, ISBNs, arXiv numbers, MSC areas |
| `lulibre.junk` | recognises titles and authors that are artefacts (build file names, error pages, the PDF's producer), matched against lower-case values |
| `lulibre.names` | recognises people's names: tells a name from an institution or a stray word, splits author lists, fixes capitals |
| `lulibre.subjects` | guesses a subject from the first pages' 1- to 3-word sequences |
| `lulibre.taxonomy` | decides subject names in one place (arXiv classes and MSC areas to tags) |
| `lulibre.options` | options of scripts and modules, each in its own namespace; `lulibre.option(ns, spec)` uses it |
| `lulibre.parts` | books that are parts of a whole (the custom fields #partof, #part, #parts): `set{ {id=, whole=, part=, parts=}, ... }` (one journaled change), `of(id)`, `wholes()` (parts in order, and missing numbers) |
| `lulibre.custom` | your own fields beside calibre's: `declare(name, {type=, help=})`, `field(name)`, `fields()`, `get(id, name)`, `all(id)`. Set them with `lulibre.apply{ {id=, field="#name", value=} }`. As calibre columns too: `column(name)`, `state(name)` → `{state = "lulibre" \| "waiting" \| "calibre", differ=}`, `differing(name)`, `add_column(name, {heading=, datatype=})`, `remove_column(name)` (both queued, see `lulibre.offline`), `calibre_books(name)`, `push(name)` |
| `lulibre.backup` | copies of calibre's database: `take(reason)` (→ `{path=, ts=, check="ok"\|"failed", problems=}`), `list()`, `last()`, `find(N or name)`, `age()` (days), `too_old([days])`, `prune([keep])`, `policy()`, `due()`, `set(value)`, `on_restart()`, `metadata()` (`calibredb backup_metadata`), `check([path])` (→ true, or false and the problems), `compare(copy)` (what putting the copy back would change; writes nothing), `describe(copy, diff)`, `restore(copy)` (queued, see `lulibre.offline`), `put_back(path)` (what the queued job does), `warn()` (replaceable: the offer) |
| `lulibre.overrides` | finds your own modules and scripts that replace lulibre's: `find()`, `warn()` (lists them in the console at start, once per file and again when lulibre's file changes; replaceable) |
| `lulibre.copy_db(src, dst [, opts])` | copies an SQLite database whole, with SQLite's backup, on a worker thread (call it from a task). `opts.amend` is SQL run on the copy afterwards, in one transaction, with `opts.attach` (`{name = path}`) attached read-only, `?1` bound to `opts.value`, and `opts.stubs`: names of SQL functions that only the database's own program has, so its triggers compile (they fail if called) |
| `lulibre.check_db(path)` | runs SQLite's integrity check, read-only, on a worker thread. Returns true; false and the problems (a list of lines); or nil and a message |
| `lulibre.calibre` | which calibre programs are running, seen from outside (`/proc/net/unix`; nothing is opened or locked): `running()` → `{db=, gui=}` (anything with a library open; the calibre program), or nil if it can't be told; `holds()`; `server()` → the status of calibre's server started through `calibre-server-opf.py` (`{pid=, opf_thread=, error=, calibre=, libraries=}`), or nil; `opf()` → `{by = "program" \| "server" \| nil, behind=, why=}`: which program keeps the books' metadata.opf files current, and how many are out of date |
| `lulibre.offline` | queues calibredb commands that wait for the content server to stop: `queue(argv, label)` (argv after `--with-library`, or a job of lulibre's own: `handlers`, by `argv[1]`), `jobs([status])`, `cancel(id)`, `run()` (the server must be stopped; first a copy of calibre's database, if `backup_restart` says so), `restart()` (with `server_stop`, `server_start`), `ask()` (restart now, or not now; replaceable), `already` (per command: is there nothing left to do?) |
| `lulibre.units` | sets up the systemd units that `server_hook`, `opf_writer` and `server_restart_at` ask for: `find()` (the unit that runs calibre-server), `plan()` (the changes, each with `files=`, `remove=`, `after=` (systemctl's); `manual=` or `cannot=` say why a change is shown, not made), `describe(plan)`, `apply(plan [, confirm])` (a system unit's changes through sudo, after `confirm`), `on_start()` (a user unit's changes, at start) |
| `lulibre.snapshots` | points in the journal to go back to: `observe()` logs changes made outside lulibre, `take(name)`, `list{all=}`, `find(what)`, `retire(id, on)`, `plan(id, {exact=, unsync=, fields=})`, `describe(plan)`, `rollback(id, opts)`, `summary(out)`, `import(path, name)`, `added(id, from, label)` for a book lulibre has just added. `values(row)` returns a books row in the journal's form |
| `lulibre.calibre_books(path)` | the books of another calibre `metadata.db` (read-only), as rows with the columns of the index's `books` |
| `lulibre.noncatalog` | marks works that no catalogue describes: `is(id)`, `set(ids, on)` → `{withdrawn=, removals=}`, `ids()`. `RECORDS` and `KINDS` say what counts as a catalogue's |
| `lulibre.propose` | decides what to propose for a book from its file: `book(id, {over=, only=, fresh=, again=})`, `wanted(book, candidates, opts)`, `same(field, a, b)`, `is_gap(field, value)`, `fields("t,a")` |
| `lulibre.extract` | ranked metadata candidates from a file's pages |
| `lulibre.refs` | reads what a book cites: `index_book(id)`, `of(id)`, `coupled(id)`, `subject(id)`, `key(entry)`, `entries(lines)`, `find(pages)` |
| `lulibre.layouts` | reads pages by rule: `add{name=, marks=, fields=, confidence=}`, `remove(name)`, `read(doc)`, `cip(text)`, `date(text)` (the date a text starts with, as YYYY-MM-DD), `journal(text)` (a journal heading: `{journal=, volume=, year=, pages=}`), `series_line(text)` (the series a page names, its volume, and the evidence), `copyright_holder(text)` (the publisher a copyright line names), `house(name)` (a publisher's name in its one standard form), `with_journal(publisher, journal)`. The tables `series`, `not_series`, `series_houses`, `houses` |
| `lulibre.titlepage` `names` `ids` `subjects` `junk` `taxonomy` | the heuristics extract is built from: title pages, author names, DOI/ISBN/arXiv/MSC, subject vocabulary |
| `lulibre.suggest` | ranked values for a field |
| `lulibre.datasets` | the databases kept on this machine: `list` (`{name=, title=, useful=, size=, from=, renewed=, files=}`), `get(name)`, `path(file)`, `status(ds)`, `state(ds)`, `fetch(ds, {force=})`, `adopt(file)` |
| `lulibre.runs` | rounds of proposing, kept while their proposals wait: `start{ids=, label=, fields=, min=, sort=, steps=}`, `step(run, name)`, `finish(run [, "failed" \| "cancelled"])`, `join{...}` (a handle for a `<close>` variable: the script's own run, or a step of the run its task is in), `list([scope])`, `running()`, `fresh()`, `covers(run, proposal)`, `own(run, proposal)`, `waiting(run)`, `drop(run)`, `on(fn)`. `badge(run)` returns what the status line shows, and can be replaced |
| `lulibre.ui.review` | `run{ids=, field=, run=}` or `run(filter)`, `show_run(run)`. `banner(view, key)` returns the line at the top of a run's view, and can be replaced |
| `lulibre.consensus` | measures how far a book's sources agree: `distance(field, a, b)`, `fuse(candidates, field)` (`{value=, confidence=, disagreement=, agree=, sources=, by=}`), `book(id)`, `kind(source)`, `learn([ids])`, `weight(kind, field)`, `set(kind, field, w)`, `table()` |
| `lulibre.ui.form` | a dialog of checkboxes, choices, values and actions: `run{title=, sections={{title=, items={{id=, kind=, label=, value=, choices=, off=}}}}}` returns the chosen action and the values |
| `lulibre.detex` | `plain(s)` converts TeX in a title or a name to plain text (`Erd\H{o}s` becomes `Erdős`), and returns whether any TeX is left. The tables `accents`, `letters` |
| `lulibre.titlecase` | `apply(s)`, `is_caps(s)`, `proposed(s)`; the tables `minor`, `prefixes`, `keep` |
| `lulibre.notation` | `render(s)` ($…$ in Unicode), `notation(s)` (the glossary), `title(s, case)`, `unicode(tex)`, `subscript(s)`, `superscript(s)`, `has_math(s)`; the lists `glossary`, `groups` |
| `lulibre.template` | patterns to named fields, and back |
| `lulibre.bib` | BibTeX export and import; sidecar metadata |
| `lulibre.dupes` | identical files. `pull(from, to)` proposes one book's values for another; `books_with(md5)` returns the books whose file has that hash (among the files hashed so far); `holders(path)` returns the books that already hold a file's bytes |
| `lulibre.orphans` | records without files, files without records, broken links |
| `lulibre.sync` | the sync folder: scan, add |
| `lulibre.ui.keys` | the panels' key tables: `of(panel)` returns `:action(key)`, `:hint(...)`, `:show()`; `define(panel, list)` gives a script's own panel a table |
| `lulibre.net` | asks metadata services and stores each answer: `arxiv(id)`, `crossref(doi)`, `zbmath{doi=|arxiv=}`, `openlibrary(isbn)`, `openalex(doi)`, `arxiv_prefetch(ids)` / `crossref_prefetch(dois)` / `openlibrary_prefetch(isbns)` (many in one request), `openlibrary_dump(isbns)` (read books from Open Library's dumps instead), `zbmath_links(arxiv_ids)`, `arxiv_snapshot(path, ids)` (read papers from a file of arXiv's records instead; `arxiv_snapshot_path()` returns the file), `in_order_of(names, text)`, `offline`, `kept(service, key)`. `request(service, url)` makes one paced request; `PACE` and `HOLD` are the seconds between requests and after a "too many requests"; `held(service)` / `hold(service, seconds)` read and set a service's pause |
| `lulibre.json` | encode, decode |

## Example

```lua
-- ~/.config/lulibre/scripts/year-from-arxiv.lua
-- Propose a date for books with an arXiv id and none: the id's first four digits say when.
local n = 0
for _, book in ipairs(lulibre.books("has:arxiv no:date")) do
  local yy = book.idents.arxiv:match("^(%d%d)%d%d%.")
  if yy then
    local year = (tonumber(yy) < 91 and 2000 or 1900) + tonumber(yy)
    if lulibre.propose(book.id, "pubdate", tostring(year), { source = "arXiv id", confidence = 0.9 }) then
      n = n + 1
    end
  end
end
print(n .. " proposals; gr reviews them")
```
