# Lua API

Scripts are Lua 5.4 or 5.5 and see one table, `lulibre`.

    :run NAME [args]            a script from ~/.config/lulibre/scripts or the bundled ones
    :lua lulibre.count("no:ids")
    lulibre run NAME [args]     the same script with no interface; print goes to stdout
    :tasks   :cancel ID|all

A script's arguments arrive as `...`. `lulibre.headless` is true when there
is no interface. Each C module is documented at the top of its
`src/lua/l_*.c`; this page is the summary. A name that begins with `_`
(`lulibre._place_map`) is lulibre's own plumbing, used by its Lua runtime,
and may change without notice.

## How scripts run

With the interface up, Lua runs on a thread of its own, with its own event
loop and its own connection to the index. Nothing a script does holds up a
keystroke. Headless, there is one thread.

Scripts run as **tasks** that take turns. A function that *waits* (marked
below) parks its task until the result arrives, so it must be called from a
task: a script, a command, or `lulibre.spawn(function() ... end)`. A task
that only computes is paused every few milliseconds so others get a turn.

Because a turn can end between any two Lua operations, code shared by tasks
must not count in a shared variable (`n = n + 1` can lose a count). Use
`lulibre.each`, put results on the items, or use `table.insert`. A test and
a set (`if not busy then busy = true`) is not one step either: use
`lulibre.claim(t, key)`. A table other tasks read is built in a local and
put in place in one assignment.

Headless, `lulibre run` ends once no task runs and nothing they started is
pending: a luv handle left open (a timer, a socket) keeps it going, so close
what you open. An error in a luv callback is reported and makes the run
exit 1, like a task's.

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
| `lulibre.stage_refresh()` | after writing the `staged` table (the sync folder's files): rebuild the books, with negative ids, that stand for them |
| `lulibre.source([name])` | what the list shows, `"library"` or `"sync"`; sets it when given |

Filters are [the filter language](filters.md). A filter that does not say
`in:` applies to what the list is showing (the library, when headless).

A **book** is

```lua
{ id = 12, title = "...", author = "A & B", authors = { "A", "B" }, tags = { ... },
  year = 1996, pubdate = "1996-05-01", publisher = "...", series = "...", series_index = 3,
  lang = "eng", idents = { doi = "10.1/x", isbn = "..." }, formats = { "PDF" }, dir = "..." }
```

Library books have positive ids; files staged from the sync folder negative ones.

## Text and files

| | |
|---|---|
| `lulibre.text(id [, page])` | indexed text of one page, or of all indexed pages joined by form feeds, from the book's file (the one read best, a PDF first: the same file `text`, `lines`, `page_put`, the preview and verify's evidence read) |
| `lulibre.text_measure(id)` | measure again the text the index holds for a book's files (characters, quality), as indexing would now: after the measure has changed, or text was put there by other means; how many files were measured |
| `lulibre.lines(id [, page])` | the page as lines: `{ {text=, size=, bold=, italic=, super=, rotated=, mono=, block=, x0=, y0=, x1=, y1=, math=}, ... }`; `math`: the line with its mathematics marked up as TeX, when it has any |
| `lulibre.files(id)` | `{ {path=, format=, status=, pages=, chars=, quality=, error=, title=, author=, ...}, ... }`, the book's file first |
| `lulibre.extract(path [, {pages=, layout_pages=, tail=}])` | *waits.* Read any file now: `{ pages=, chars=, quality=, meta={...}, page={ {text=, lines=}, ... } }` or nil, error |
| `lulibre.render(path, page [, width])` | *waits.* The page as a greyscale PGM string |
| `lulibre.page_put(id, page, {text=, lines=, src=})` | replace a page's indexed text in the book's file, as OCR does |
| `lulibre.md5(path)` | *waits* the first time. Content hash, remembered in the index |
| `lulibre.index([{filter=, force=, retry=}])` | *waits.* Extract text from new or changed files (all of them with `force`, only matching books with `filter`): `{ files=, queued=, ok=, failed=, missing=, seconds= }` |

## Changing the library

| | |
|---|---|
| `lulibre.apply{ {id=, field=, value=, op=}, ... }` | *waits.* Write changes now, as one undoable batch. Returns `{ batch=, books=, applied=, unchanged=, failed={...}, links= }` |
| `lulibre.propose(id, field, value [, {op=, source=, confidence=}])` | queue a change for review (`gr`) |

`field` is one of `title authors tags series series_index publisher pubdate
identifiers languages`. `op` is `"set"` (default), or for the list fields
`"add"` / `"remove"`. More in `require "lulibre.edit"`: `current(book,
field)`, `undo([batch])`, `history()`, `remove(ids)`, `route()`.

## The interface

| | |
|---|---|
| `lulibre.notify(msg [, "error"])` | the message line (stderr when headless) |
| `print(...)` | the same; stdout when headless |
| `lulibre.log(text [, level])` | the log console: `"info"`, `"warn"`, `"error"`, `"debug"` (debug builds only) |
| `lulibre.progress(text \| nil)` | a note in the status line while a script works |
| `lulibre.status(name, text \| nil [, style])` | a badge in the status line, beside the mode, under a name of your own: set again to change it, with `nil` to take it away. `style`: `accent` (default) `ok` `warn` `error` `dim`. At most six at once |
| `lulibre.current()` | id under the cursor |
| `lulibre.selection()` | ids an action applies to. With the cursor in a panel that follows the list, the book its row stands for; an error if that book is not in the list |
| `lulibre.mark(id [, on])` | mark, unmark, or toggle |
| `lulibre.filter([expr])` | get or set the list filter |
| `lulibre.jump(id)` | move the cursor to a book |
| `lulibre.exec(line)` | run a command line |
| `lulibre.command(name, fn [, help])` | define a `:` command; `fn(args)` runs as a task |
| `lulibre.commands()` | every command there is: `{ {name=, help=}, ... }`, built in and defined |
| `lulibre.map(modes, keys, target [, about])` | bind keys to a command line or a function; `about` is what `?` shows for the key, `false` keeps it out. With a panel's name for `modes` (`"review"`), or a place's (`"panel"`, `"line"`, `"picker"`, `"pager"`, `"console"`), put a key on one of its actions |
| `lulibre.key(command [, mode])` | the keys bound to a command line (`"gr"`), or nil |
| `lulibre.hint(command)` | the same for a message: the keys, or `":command"` when there are none |
| `lulibre.maps()` | every global binding: `{ {modes=, keys=, command=}, ... }` |
| `lulibre.place_keys(place)` | the keys of `"panel"`, `"line"`, `"picker"`, `"pager"` or `"console"`, as lines of text |
| `lulibre.input{prompt=, default=, suggestions=, separator=, on_change=}` | *waits.* A line of text, or nil |
| `lulibre.confirm(question)` | *waits.* true for y or yes |
| `lulibre.pick(items [, {title=}])` | *waits.* Fuzzy-pick one: item, index |
| `lulibre.show(text [, title])` | a scrollable overlay; text may be a list of lines |
| `lulibre.clipboard(text)` | copy |
| `lulibre.clipboard()` | what was copied last, or nil |
| `lulibre.policy(option, question)` | apply an `auto` / `ask` / `never` option: true or false |

### Panels

A table a script fills and steers; the edit form, review and the tree
browser are Lua built on this.

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
`p:show()` (off the screen and back, around a panel opened on top of it),
`p:height(share)`, `p:keys(list)`, `p:tabs(names, current)`, `p:send(key
[, row])`. Row styles: `dim
accent ok warn error`, and `head` and `note`, which show their first cell
across the whole width (a heading; text too long for a column). With `moves = true`, `wait()` also returns
`"<Move>"` when the cursor moves, and with `reloads = true` it returns
`"<Reload>"` when the library has been read again, so the rows can be
brought up to date. `Esc` in a panel goes back to the window it was
reached from and leaves the panel open; with `dialog = true` (a form that
asks something) it closes the panel, as `q` does.

Tabs are names drawn in the bar after the title, the current one standing
out; when they do not all fit, the strip moves so that the current one is on
it. The panel only draws them: the script switches, on keys of its
choosing, and sets them again with `p:tabs`. A click on a tab makes
`wait()` return `"<Tab>"` and the tab's number. `p:send(key)` makes
`wait()` return `key` from another task: how a script that is not the
panel's own tells it that something it shows has changed.

A panel normally takes every key. Given `keys` and `pass`, a key that is not
among `keys` and begins a global binding to one of the `pass` commands (named
by their first word) runs that binding instead: this is how `P` and `]`
reach the preview from inside review. When a following panel's row is a book
the list does not hold, the preview shows that book anyway.

The edit form and review can be opened for given books from a script:
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
| `lulibre.claim(t, key [, value])` | sets `t[key]` (to `value`, default true) if it is nil, as one step: true if this call set it. Tasks are interrupted between any two Lua operations, so a test followed by a set is not one; give it back with `t[key] = nil` |
| `lulibre.system({"prog", "arg"} [, {stdin=, cwd=, timeout=}])` | *waits.* `{ code=, signal=, stdout=, stderr=, timed_out= }`, or nil, message |
| `lulibre.fold(s)` | search key: lower case, accents stripped |
| `lulibre.lower(s)` `lulibre.upper(s)` | case for more than ASCII: accented Latin, Greek, Cyrillic |
| `lulibre.titlecase(s)` | the title in title case (APA) |
| `lulibre.phrases(text)` | the distinct two- and three-word phrases of a text |
| `lulibre.counter()` | counts phrases, or whole lines, over many texts: `c:add(text)`, `c:prune(min [, max])`, `c:of(text)`, `c:count(phrase)`, `c:add_lines(text [, same])`, `c:strip(text, min)` |
| `lulibre.fuzzy(query, candidate)` | score, or nil |
| `lulibre.inspect(value)` | a readable rendering of any value |
| `lulibre.uv`, `require "luv"` | libuv, on the loop Lua runs on |

## Settings

| | |
|---|---|
| `lulibre.o.name` | read or write an option (nil puts it back to its default); see [Configuration](configuration.md) |
| `lulibre.setup{ name = value, ... }` | set several options at once |
| `lulibre.settings.get(name)` | the same, as a function; with no name, every option as a table |
| `lulibre.settings.set(name, value)` | or `set{ pages = 8, ocr = "auto" }` for several |
| `lulibre.settings.reset(name)` | back to the default |
| `lulibre.settings.names()` | option names, in order |
| `lulibre.settings.info(name)` | `{ name=, value=, default=, type=, choices=, help= }` |
| `lulibre.settings.paths()` | `{ config_dir=, init=, scripts=, modules=, data_dir=, index=, library=, installed=, bundled = { modules=, scripts= } }` (`scripts`, `modules`: yours; `bundled`: lulibre's own, in the runtime in use) |
| `lulibre.theme.name = "#rrggbb"` | colours; `lulibre.theme()` lists them |
| `lulibre.version` | `"0.2.0-dev"` |
| `lulibre.build` | `{ version=, major=, minor=, patch=, pre=, debug=, lua=, number=, commit= }`; `number` is this build's number among the builds of its version (`"007"`) |

The configuration directory is the option `config_dir`:

```lua
lulibre.settings.get("config_dir")                 -- "/home/me/.config/lulibre"
lulibre.settings.set("config_dir", "~/dotfiles/lulibre")
```

Reading it gives the directory in effect. Setting it changes where scripts
and modules are looked for from then on; which `init.lua` is loaded was
decided at startup (`lulibre -C DIR`, or `$LULIBRE_CONFIG_DIR`).

## Modules

The runtime written in Lua lives under `lua/lulibre/`; each file opens with
its own documentation.

| `require` | |
|---|---|
| `lulibre.edit` | apply, undo, history, remove; a field's current value; the write route |
| `lulibre.proposals` | add, list, accept, apply |
| `lulibre.quality` | a record's score, and the confirmed ones: `score(book)`, `ranked(opts)`, `set_good(ids, on)`, `is_good(id)`, `good_ids()`, `catchall(subject)` |
| `lulibre.learn` | what marks a subject: `run()`, `terms(subject)`, `set(subject, phrase, state)`, `classify(text [, model])`, `suggest(text [, model])`, `candidate(id)`; without keeping the result: `census()`, `work{from=, census=}`, `model(got)`; `FURNITURE` (phrases never learned) |
| `lulibre.verify` | the file decides: `evidence(id)` (the opening pages, or nil and why they cannot be read), `title(ev, t)` → shown/partly/absent/unknown and share, `phrase(ev, t)` (share standing in order), `headline(ev, t)` (in the largest type), `authors(ev, names)` → verdict, shown, named, `ident(ev, "doi:...")` → own/front/inside/cited/absent/unknown, `size(ev, rec)` → part/whole/larger, `record(ev, rec)` → `{title=, authors=, another=, part=, unread=}`, `book(id)` |
| `lulibre.doc_metadata(path)` | *waits* in a task (a worker reads the file). A PDF's XMP packet and Info dictionary, or an EPUB's package, as text; `require("lulibre.ids").from_metadata(text)` → `{ {kind=, value=, where=} }` |
| `lulibre.ui.context` | what a proposal rests on, for review's context panel: `rows(pr, others)`, `record_of(pr)` (the kept record a proposal came from or an identifier leads to), `source_class(src)` |
| `net.kept_record(kind, value)` | the record kept for a doi, isbn or arXiv number, asking nobody; `net.arxiv_by_title(path, {[net.title_key(t)]=true})` looks papers up by title in arXiv's snapshot |
| `lulibre.panel{ side = "main" }` | a panel in the list's window for a while, the list coming back when it closes; the focus stays where it was |
| `lulibre.option(ns, { name = { default=, type=, choices=, help= } })` | declare a script's options; returns the namespace to read them from. `lulibre.cfg.NS.NAME` reads or sets one; `require "lulibre.options"`: `declare`, `get`, `set(ns, name, v, "file"|"script"|"session")`, `reset`, `from`, `list`, `namespaces` |
| `lulibre.config_file` | init.lua as lulibre writes it: `missing()`, `add(items)`, `write_value(item, v)` (nil: back to the default), `line_of(item)` |
| `lulibre.features` | the programs features need: `find(program)`, `status(f)`, `need(name)` (may offer pixi), `declare{ name=, programs=, used_for=, packages=, pixi= }` |
| `lulibre.edit_file(path)` | open a file in `$VISUAL`/`$EDITOR` (vim, vi), handing over the terminal; the exit status |
| `lulibre.require_rock(module [, rock])` | require, offering to install into `rocks_tree` when `rocks_install = "on"` |
| `lulibre.grammars` | grammars of publications: `add{ name=, kind=, lines = { G.line{...}, G.skip(n), G.opt(r), G.either{...} }, text=, pages=, read=, noncatalog=, confidence= }`, `remove(name)`, `match(doc)` → `{ {grammar=, fields=} }`, `doc(id)` |
| `lulibre.ids` | identifiers in page text: DOIs, ISBNs, arXiv numbers, MSC areas |
| `lulibre.junk` | titles and authors that are artefacts (build file names, error pages, the PDF's producer), against lower-cased values |
| `lulibre.names` | people's names: telling a name from an institution or a stray word, splitting author lists, fixing capitals |
| `lulibre.subjects` | a subject guessed from the first pages' 1- to 3-word sequences |
| `lulibre.taxonomy` | the one place subject names are decided (arXiv classes, MSC areas to tags) |
| `lulibre.options` | options of scripts and modules, each in a namespace of its own: what `lulibre.option(ns, spec)` uses |
| `lulibre.parts` | books that are parts of a whole (the custom fields #partof, #part, #parts): `set{ {id=, whole=, part=, parts=}, ... }` (one journaled change), `of(id)`, `wholes()` (parts in order, numbers missing) |
| `lulibre.custom` | custom fields beside calibre's: `declare(name, {type=, help=})`, `field(name)`, `fields()`, `get(id, name)`, `all(id)`; set them with `lulibre.apply{ {id=, field="#name", value=} }`. In calibre too: `column(name)`, `state(name)` → `{state = "lulibre" \| "waiting" \| "calibre", differ=}`, `differing(name)`, `add_column(name, {heading=, datatype=})`, `remove_column(name)` (both queued: `lulibre.offline`), `calibre_books(name)`, `push(name)` |
| `lulibre.backup` | copies of calibre's database: `take(reason)` (→ `{path=, ts=, check="ok"\|"failed", problems=}`), `list()`, `last()`, `find(N or name)`, `age()` (days), `too_old([days])`, `prune([keep])`, `policy()`, `due()`, `set(value)`, `on_restart()`, `metadata()` (calibredb backup_metadata), `check([path])` (→ true, or false and the problems), `compare(copy)` (what putting it back would change; writes nothing), `describe(copy, diff)`, `restore(copy)` (queued: `lulibre.offline`), `put_back(path)` (what the queued job does), `warn()` (replaceable: the popup) |
| `lulibre.overrides` | your own modules and scripts used in place of lulibre's own: `find()`, `warn()` (said in the console at start, once per file and again when lulibre's changes; replaceable) |
| `lulibre.copy_db(src, dst [, opts])` | an SQLite database copied whole (SQLite's backup, on a worker thread; from a task). `opts.amend`: SQL run on the copy afterwards, in one transaction, with `opts.attach` (`{name = path}`) attached read only, `?1` bound to `opts.value`, and `opts.stubs` (names of SQL functions only the database's own program has, for its triggers to compile; they fail if called) |
| `lulibre.check_db(path)` | SQLite's integrity check, read only, on a worker thread: true; false and the problems (a list of lines); nil and a message |
| `lulibre.calibre` | which of calibre's programs are running, seen from outside (`/proc/net/unix`; nothing is opened or locked): `running()` → `{db=, gui=}` (anything with a library open; calibre's program), or nil where it cannot be told; `holds()`; `server()` → the status of calibre's server started through `calibre-server-opf.py` (`{pid=, opf_thread=, error=, calibre=, libraries=}`), or nil; `opf()` → `{by = "program" \| "server" \| nil, behind=, why=}`: who keeps the books' metadata.opf current, and how many are behind |
| `lulibre.offline` | calibredb commands that wait for the content server to be stopped: `queue(argv, label)` (argv after `--with-library`, or a job of lulibre's own: `handlers`, by `argv[1]`), `jobs([status])`, `cancel(id)`, `run()` (the server must be stopped; a copy of calibre's database first, as `backup_restart` says), `restart()` (with `server_stop`, `server_start`), `ask()` (restart now, or not now: replaceable), `already` (per command: is there nothing left to do?) |
| `lulibre.snapshots` | points in the journal to go back to: `observe()` logs changes made outside lulibre, `take(name)`, `list{all=}`, `find(what)`, `retire(id, on)`, `plan(id, {exact=, unsync=, fields=})`, `describe(plan)`, `rollback(id, opts)`, `summary(out)`, `import(path, name)`, `added(id, from, label)` for a book lulibre has just added; `values(row)` a books row as the journal spells it |
| `lulibre.calibre_books(path)` | the books of another calibre `metadata.db` (read only), as rows with the columns of the index's `books` |
| `lulibre.noncatalog` | works no catalogue has a record of: `is(id)`, `set(ids, on)` → `{withdrawn=, removals=}`, `ids()`; `RECORDS`, `KINDS` (what counts as a catalogue's) |
| `lulibre.propose` | what to propose for a book from its file: `book(id, {over=, only=, fresh=, again=})`, `wanted(book, candidates, opts)`, `same(field, a, b)`, `is_gap(field, value)`, `fields("t,a")` |
| `lulibre.extract` | ranked metadata candidates from a file's pages |
| `lulibre.refs` | what a book cites: `index_book(id)`, `of(id)`, `coupled(id)`, `subject(id)`, `key(entry)`, `entries(lines)`, `find(pages)` |
| `lulibre.layouts` | pages read by rule: `add{name=, marks=, fields=, confidence=}`, `remove(name)`, `read(doc)`, `cip(text)`, `date(text)` (the date a text opens with, as YYYY-MM-DD), `journal(text)` (a journal heading: `{journal=, volume=, year=, pages=}`), `series_line(text)` (the series a page names, its volume, and what bears it out); `copyright_holder(text)` (the publisher a copyright line names), `house(name)` (a publisher written the one way its house is), `with_journal(publisher, journal)`; the tables `series`, `not_series`, `series_houses`, `houses` |
| `lulibre.titlepage` `names` `ids` `subjects` `junk` `taxonomy` | the heuristics extract is built from: title pages, author names, DOI/ISBN/arXiv/MSC, subject vocabulary |
| `lulibre.suggest` | ranked values for a field |
| `lulibre.datasets` | databases kept on this machine: `list` (`{name=, title=, useful=, size=, from=, renewed=, files=}`), `get(name)`, `path(file)`, `status(ds)`, `state(ds)`, `fetch(ds, {force=})`, `adopt(file)` |
| `lulibre.runs` | goes of proposing, remembered while their proposals wait: `start{ids=, label=, fields=, min=, sort=, steps=}`, `step(run, name)`, `finish(run [, "failed" \| "cancelled"])`, `join{...}` (a handle for a `<close>` variable: a run of the script's own, or a step of the run its task is in), `list([scope])`, `running()`, `fresh()`, `covers(run, proposal)`, `own(run, proposal)`, `waiting(run)`, `drop(run)`, `on(fn)`; `badge(run)` is what the status line says, and may be replaced |
| `lulibre.ui.review` | `run{ids=, field=, run=}` or `run(filter)`, `show_run(run)`; `banner(view, key)` is the line at the top of a run's view, and may be replaced |
| `lulibre.consensus` | how far a book's sources agree: `distance(field, a, b)`, `fuse(candidates, field)` (`{value=, confidence=, disagreement=, agree=, sources=, by=}`), `book(id)`, `kind(source)`, `learn([ids])`, `weight(kind, field)`, `set(kind, field, w)`, `table()` |
| `lulibre.ui.form` | a dialog of boxes, choices, values and actions: `run{title=, sections={{title=, items={{id=, kind=, label=, value=, choices=, off=}}}}}` returns the action chosen and the values |
| `lulibre.detex` | `plain(s)`: TeX in a title or a name put into plain text (`Erd\H{o}s` is `Erdős`), and whether none is left; the tables `accents`, `letters` |
| `lulibre.titlecase` | `apply(s)`, `is_caps(s)`, `proposed(s)`; the tables `minor`, `prefixes`, `keep` |
| `lulibre.notation` | `render(s)` ($…$ in Unicode), `notation(s)` (the glossary), `title(s, case)`, `unicode(tex)`, `subscript(s)`, `superscript(s)`, `has_math(s)`; the lists `glossary`, `groups` |
| `lulibre.template` | patterns to named fields and back |
| `lulibre.bib` | BibTeX out and in; sidecar metadata |
| `lulibre.dupes` | identical files; `pull(from, to)` proposes one book's values for another; `books_with(md5)` the books whose file has that hash (of the files hashed so far), `holders(path)` the books that already hold a file's bytes |
| `lulibre.orphans` | records without files, files without records, broken links |
| `lulibre.sync` | the sync folder: scan, add |
| `lulibre.ui.keys` | the panels' key tables: `of(panel)` gives `:action(key)`, `:hint(...)`, `:show()`; `define(panel, list)` gives a script's own panel one |
| `lulibre.net` | metadata services, each answer kept: `arxiv(id)`, `crossref(doi)`, `zbmath{doi=|arxiv=}`, `openlibrary(isbn)`, `openalex(doi)`, `arxiv_prefetch(ids)` / `crossref_prefetch(dois)` / `openlibrary_prefetch(isbns)` (many in one request), `openlibrary_dump(isbns)` (read books from Open Library's dumps instead), `zbmath_links(arxiv_ids)`, `arxiv_snapshot(path, ids)` (read papers from a file of arXiv's records instead; `arxiv_snapshot_path()` says which file), `in_order_of(names, text)`, `offline`, `kept(service, key)`; `request(service, url)` is one paced request, `PACE` and `HOLD` the seconds between requests and after a "too many requests", `held(service)` / `hold(service, seconds)` the pause a service is under |
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
