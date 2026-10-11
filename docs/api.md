# Lua API

Scripts are Lua 5.4 or 5.5 and see one table, `lulibre`.

    :run NAME [args]            a script from ~/.config/lulibre/scripts or the bundled ones
    :lua lulibre.count("no:ids")
    lulibre run NAME [args]     the same script with no interface; print goes to stdout
    :tasks   :cancel ID|all

A script's arguments arrive as `...`. `lulibre.headless` is true when there
is no interface. Each C module is documented at the top of its
`src/lua/l_*.c`; this page is the summary.

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
`lulibre.each`, put results on the items, or use `table.insert`.

## The library

| | |
|---|---|
| `lulibre.ids(filter)` | `{ id, ... }` |
| `lulibre.books(filter)` | `{ book, ... }` |
| `lulibre.book(id)` | a book, or nil |
| `lulibre.count(filter)` | number |
| `lulibre.authors()` `lulibre.tags()` | `{ {name=, books=}, ... }`, most used first |
| `lulibre.sql(sql, ...)` | rows of a read-only query against the index |
| `lulibre.store(sql, ...)` | the same, but may write lulibre's own tables (`proposals`, `journal`, `kv`, `staged`); returns rows, rows changed, last insert id |
| `lulibre.reload()` | pick up changes calibre has made |
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
| `lulibre.text(id [, page])` | indexed text of one page, or of all indexed pages joined by form feeds |
| `lulibre.lines(id [, page])` | the page as lines: `{ {text=, size=, bold=, italic=, super=, rotated=, mono=, block=, x0=, y0=, x1=, y1=}, ... }` |
| `lulibre.files(id)` | `{ {path=, format=, status=, pages=, chars=, quality=, error=, title=, author=, ...}, ... }` |
| `lulibre.extract(path [, {pages=, layout_pages=}])` | *waits.* Read any file now: `{ pages=, chars=, quality=, meta={...}, page={ {text=, lines=}, ... } }` or nil, error |
| `lulibre.render(path, page [, width])` | *waits.* The page as a greyscale PGM string |
| `lulibre.page_put(id, page, {text=, lines=, src=})` | replace a page's indexed text, as OCR does |
| `lulibre.md5(path)` | *waits* the first time. Content hash, remembered in the index |

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
| `lulibre.current()` | id under the cursor |
| `lulibre.selection()` | ids an action applies to. With the cursor in a panel that follows the list, the book its row stands for; an error if that book is not in the list |
| `lulibre.mark(id [, on])` | mark, unmark, or toggle |
| `lulibre.filter([expr])` | get or set the list filter |
| `lulibre.jump(id)` | move the cursor to a book |
| `lulibre.exec(line)` | run a command line |
| `lulibre.command(name, fn [, help])` | define a `:` command; `fn(args)` runs as a task |
| `lulibre.map(modes, keys, target)` | bind keys to a command line or a function |
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
}
while true do
  local key, row = p:wait()        -- nil once the panel is closed
  if not key then break end
  if key == "<CR>" then lulibre.notify("row " .. row) end
end
```

Methods: `p:rows(rows)`, `p:title(s)`, `p:help(s)`, `p:columns(cols)`,
`p:cursor([row])`, `p:wait()`, `p:close()`, `p:is_open()`. Row styles: `dim
accent ok warn error`, and `head` and `note`, which show their first cell
across the whole width (a heading; text too long for a column). With `moves = true`, `wait()` also returns
`"<Move>"` when the cursor moves.

## Tasks, processes, helpers

| | |
|---|---|
| `lulibre.spawn(fn, ...)` | run `fn` as a task; returns its id |
| `lulibre.each(items, fn [, {jobs=, progress=}])` | *waits.* `fn(item, index)` over a list, several at a time |
| `lulibre.sleep(ms)` | *waits* |
| `lulibre.yield()` | give others a turn now |
| `lulibre.tasks()` `lulibre.cancel(id)` `lulibre.task_id()` | |
| `lulibre.system({"prog", "arg"} [, {stdin=, cwd=, timeout=}])` | *waits.* `{ code=, signal=, stdout=, stderr=, timed_out= }`, or nil, message |
| `lulibre.fold(s)` | search key: lower case, accents stripped |
| `lulibre.fuzzy(query, candidate)` | score, or nil |
| `lulibre.inspect(value)` | a readable rendering of any value |
| `lulibre.uv`, `require "luv"` | libuv, on the loop Lua runs on |

## Settings

| | |
|---|---|
| `lulibre.o.name` | read or write an option; see [Configuration](configuration.md) |
| `lulibre.settings.get(name)` | the same, as a function; with no name, every option as a table |
| `lulibre.settings.set(name, value)` | or `set{ pages = 8, ocr = "auto" }` for several |
| `lulibre.settings.reset(name)` | back to the default |
| `lulibre.settings.names()` | option names, in order |
| `lulibre.settings.info(name)` | `{ name=, value=, default=, type=, choices=, help= }` |
| `lulibre.settings.paths()` | `{ config_dir=, init=, scripts=, modules=, data_dir=, index=, library= }` |
| `lulibre.theme.name = "#rrggbb"` | colours; `lulibre.theme()` lists them |
| `lulibre.version` | `"0.1.0-beta.2"` |
| `lulibre.build` | `{ version=, major=, minor=, patch=, pre=, debug=, lua= }` |

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
| `lulibre.extract` | ranked metadata candidates from a file's pages |
| `lulibre.titlepage` `names` `ids` `subjects` `junk` `taxonomy` | the heuristics extract is built from: title pages, author names, DOI/ISBN/arXiv/MSC, subject vocabulary |
| `lulibre.suggest` | ranked values for a field |
| `lulibre.template` | patterns to named fields and back |
| `lulibre.bib` | BibTeX out and in; sidecar metadata |
| `lulibre.dupes` | identical files |
| `lulibre.orphans` | records without files, files without records, broken links |
| `lulibre.sync` | the sync folder: scan, add |
| `lulibre.net` | arXiv and CrossRef lookups |
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
