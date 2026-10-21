# Keys and commands

`?` inside lulibre shows the keys as they currently stand, including
anything `init.lua` has added, under headings that open and close: Enter
opens one, `/` searches all of them as you type, `K` shows what the guides
say about the key under the cursor. `:help TOPIC` shows the part of these
guides about a word (`:help enrich`, `:help filters`). Every key runs a
command; `:` runs one by name.

## The list

| Key | Command | |
|---|---|---|
| `j` `k` `<Down>` `<Up>` | `move +1` / `-1` | |
| `gg` `G` | `move top` / `bottom` | |
| `<C-d>` `<C-u>` `<C-f>` `<C-b>` | `move half-down` … | half and whole pages |
| `/` | `prompt search` | search without narrowing; matches are marked `›` |
| `n` `N` | `search next` / `prev` | |
| `&` | `prompt filter` | narrow the list as you type |
| `<BS>` | `filter` | show everything |
| `f` `ga` `gs` `gf` | `pick books` / `authors` / `subjects` / `filters` | fuzzy finders |
| `gh` | `pick group` | the list as a tree: by author, subject, series, publisher, year, format, or folder (as the library is filed on disk); `:group count` orders the headings by size, `:group name` by name |
| `gH` | `group none` | the plain list again |
| `<CR>` | `enter` | on a heading: open or close it; on a book: the edit form |
| `l` `<Right>` `zo` · `h` `<Left>` `zc` · `za` | `fold open` / `close` / `toggle` | closing a closed heading steps out to the one it is within |
| `zR` `zM` | `fold all` / `none` | open, or close, every heading |
| `s` | `pick sort` | the order of the books: title, author, year, latest additions ... (`:sort -added`) |
| `gt` | `browse` | tree in a left column: `f` switches facet, `l`/`h` open and close, `/` finds |
| `Space` | `mark toggle` | on a heading: every book under it. `:mark all`, `none`, `invert` |
| `V` | `visual` | select a range; `Esc` ends it |
| `gp` | `propose` | propose metadata for what is selected, from the files themselves |
| `<Leader>pr` | `propose-review` | a dialog: which books, what is asked, which fields, what review then shows; then propose, and review |
| `<Leader>e` | `enrich-dialog` | look the selection up: what would be asked of whom, boxes for the services, then go and review |
| `<Leader>c` | `change` | one change to every selected book: add or remove a subject, set authors, series, publisher, date, language, title case |
| `<Leader>d` | `datasets-dialog` | the databases kept on this machine, with boxes for which to fetch (`:datasets`) |
| `<Leader>s` | `sync-dialog` | in the sync folder: add, add and remove, or drop the selected files, having seen what each is |
| `<Leader><Space>` | `mark none` | unmark every book |
| `<Leader>w` | `weights` | how much each kind of source is believed, field by field (`:weigh` measures them) |
| `e` · `r` | `edit` · `review selection` | the edit form, or the waiting proposals, for what is selected: the range, else the marked books, else the books under the heading the cursor is on, else the book |
| `R` | `reload` | re-read calibre's metadata now |

## The preview

| Key | |
|---|---|
| `J` `K` | scroll |
| `]` `[` | next and previous page |
| `P` | text ⇄ page image |
| `+` `-` `=` | zoom the image in, out, reset |
| `H` `L` | pan the image |
| `a` | read the file as far as the page being shown, when it is past the pages that were indexed (`:addpages BOOK PAGE` does it for any book) |
| `v` | select text with the keys: a cursor comes out in the page's text. `h` `j` `k` `l` and the arrows move it, `w` `b` by words, `0` `$` to the ends of the line, `gg` `G` of the page; `v` begins a selection (again lets go of it), `V` takes the line; `y` or Enter copies and leaves, `Esc` or `q` leaves. These are the keys of the place `select`: `lulibre.map("select", "n", "down")` |

## Windows

The windows are the list, the previews and the console; panels (review, the
edit form, the browse column ...) are reached with their own keys, below.

| Key | |
|---|---|
| `<C-w>w` `<C-w>W` | next window, the window before (`:focus next`, `:focus prev`) |
| `<C-w>h` `j` `k` `l` | window in that direction |
| `<C-w>v` `<C-w>s` | split with another preview, side by side or stacked |
| `<C-w>c` `<C-w>o` | close this window · close the others |
| `<M-Left>` `<M-Right>` `<M-Up>` `<M-Down>` | move the line beside the focused window that way (`:resize left` ...) |
| `<Leader>` then an arrow | the same |
| `<C-w>>` `<C-w><` | grow or shrink the focused window |
| `` ` `` | the log console, without moving the focus |

## Panels

| Key | |
|---|---|
| `<Tab>` | from a window, the panel last in; in a panel, the next one (`:focus panel`) |
| `<S-Tab>` | the panel before (`:focus panel prev`) |
| `Esc` | in a panel, back to the window it was reached from; the panel stays open. A dialog (the edit form, a form that asks something) closes |
| `q` | close the panel |
| `:new` *command* | one of each screen is open at a time: `gr` with review open goes to that review, and so for every screen. `:new review` (any command that opens a screen) opens another beside it all the same |
| `/` · `n` `N` | search the panel's rows, as in the list: the rows holding the text are marked `›` and the cursor goes to the first as it is typed; `n` and `N` the next and the one before. Where a panel has its own `/` (help, the tree browser) or `N` (review: never again), the panel's own stays |

## The mouse

| | |
|---|---|
| click | select the row, focus the window (in the preview only a plain click does: one that starts a selection leaves the cursor where it was) |
| wheel | scroll what it is over |
| drag in the text preview | select text; it is copied when the button is released |
| double click · triple click there | the word · the line |
| drag anywhere else | select what is drawn there: a row of the list, a cell of review, the line being typed, the status line, a help or message overlay |
| double click · triple click there | the word · the row; in a panel, the whole of the cell, including what its column cut off |
| drag the line between two windows | resize them |
| drag a window's bar up or down | resize it against the window above (the review panel against the list) |
| middle or right click, while typing | paste |

A selection stays within the window (or line) it began in. It is copied at
once and stays highlighted until the next key or click.

`lulibre.o.mouse = 0` hands the mouse back to the terminal. With it on, hold
Shift to make the terminal's own selection.

## While typing

In the command line, a filter, a search, or a field of the edit form:

| Key | |
|---|---|
| `<C-v>` | paste what was last copied, as one line |
| `<C-y>` | copy the line as it stands |
| the terminal's own paste | the same: line breaks become spaces, nothing is submitted |
| `<PageUp>` `<PageDown>` | scroll the preview without leaving the field |
| `Tab` | take the highlighted suggestion or completion |
| `<C-n>` `<C-p>` | move through the completions |
| `<C-a>` `<C-e>` `<C-u>` `<C-k>` `<C-w>` | start, end, delete to start, to end, a word back |
| `<C-Left>` `<C-Right>` (or with Alt) | a word back, a word on, as `b` and `w` |
| `<Up>` `<Down>` | history: entries that start with what has been typed (in a field: the suggestion list) |
| `Enter` · `Esc` | accept · cancel |

The command line completes as you type: command names, then what each
command takes (`:set` option names and their allowed values, `:run` script
names, `:sort` keys); `&` and `/` complete the filter language (`au` →
`author:`, `is:d` → `is:dupe`). History is kept between sessions, separately
for commands, filters and searches.

The mouse still selects while a field is open, in the preview and in the
panels, so a title on the page or a value in another row can be dragged over
and pasted with `<C-v>`.

## Changing things

| Key | Command | |
|---|---|---|
| `e` | `edit` | edit form for the selection |
| `gc` | `capture` | fields from names by pattern |
| `gr` | `review` | go through proposals: what was just proposed if you have not looked at it yet, else everything that waits (`l` `h` switch between the two in review) |
| `gT` | `titlecase` | titles in CAPITALS to title case |
| `gk` | `good` | the records by score, to confirm the right ones |
| `u` | `undo` | `:undo N` for a given batch; `:history` lists them |
| `gd` | `dupes` | books with identical files |
| `go` | `orphans` | records without files, files without records, broken links |
| `2` `gS` | `sync` | read the sync folder and show it |
| `gb` | `beside` | the sync folder in a column beside the library: each waiting file next to the book that is the same, or looks like it |
| `1` `gl` | `source library` | back to the library |
| `S` `X` `D` | `sync add` / `sync move` / `sync drop` | staged files into the library, or out of the folder |
| `yb` `yk` `yp` `yy` | `yank bib` / `key` / `path` / `title` | copy to the clipboard |
| | `remove` | remove the selection from calibre (to its recycle bin; `u` undoes) |
| | `embed` | write calibre's metadata into the files themselves |

## Other commands

| Command | |
|---|---|
| `run [script [args]]` | run a Lua script; with no argument, pick one |
| `lua code` | run a line of Lua and show what it returns |
| `tasks` · `cancel ID\|all` | scripts that are running · stop them |
| `messages` · `console` | the log in a pager · the live console |
| `index [force]` | extract text from new or changed files |
| `sort [-]key` | `id title author year series added modified` |
| `set name[=value]` | show or change an option |
| `bib [file]` | write the selection as BibTeX |
| `propose` `enrich` `refs` `arxiv-fetch` `ocr` `onboard DIR` | shortcuts for `run` of those scripts |
| `backup` · `offline` · `custom` · `snapshot` · `units` | copies of calibre's database, changes that wait for the server, fields of your own, points to go back to, calibre's server unit (docs/workflows.md) |
| `move` `search` `prompt` `fold` `split` `only` `preview` `pick` `source` `yank` | what the keys above run, to bind your own (`:help` gives each one's arguments) |
| `echo text` | show a message |
| `help` · `help-plain` · `quit` | `?` · the keys and commands as one long page · `q`, `ZZ` |

## Inside a panel

The edit form, review, capture, duplicates, orphans and the tree browser are
panels. `j` `k` `gg` `G` and paging move within one; `q` closes it, and `Esc`
goes back to the window it was reached from, leaving it open (a dialog
closes); `/` searches its rows and `n` `N` step through them, unless the
panel has those keys for itself; `Tab`, `:` and `<C-w>` keep their meaning. The title bar shows a panel's
main keys, and `?` lists all of them with what each does.

A panel's keys can be changed. Each has named actions (`?` lists them), and
`lulibre.map` with the panel's name in place of the modes puts a key on one:

```lua
lulibre.map("review", "y", "accept")   -- y accepts, and is the key the hint shows
lulibre.map("review", "a", "")         -- a no longer does anything in review
```

The panels are `edit`, `review`, `dupes`, `orphans`, `capture` and `browse`.

## Keys that belong to a place

Moving inside a panel, editing the line being typed, the picker, an overlay
and the console each have keys of their own, with named actions, bound the
same way:

```lua
lulibre.map("panel", "n", "down")        -- n moves down in every panel
lulibre.map("line", "<C-g>", "cancel")   -- <C-g> leaves the line being typed
lulibre.map("console", "x", "close")
lulibre.map("line", "<C-k>", "")         -- unbind
```

| Place | Actions |
|---|---|
| `panel` | `down` `up` `top` `bottom` `half-down` `half-up` `page-down` `page-up` `close` |
| `line` | `accept` `cancel` `paste` `copy` `complete` `next` `prev` `up` `down` `preview-up` `preview-down` `left` `right` `home` `end` `backspace` `delete` `kill-start` `kill-end` `kill-word` `word-left` `word-right` |
| `picker` | `accept` `cancel` `down` `up` `page-down` `page-up` |
| `pager` | `down` `up` `page-down` `page-up` `top` (any other key closes it) |
| `console` | `up` `down` `half-up` `half-down` `top` `follow` `errors` `warnings` `notices` `everything` `clear` `close` |

A binding here is one key, or two in a row (`gg`). `?` lists every place
with its actions and the keys they are on. In a panel, movement keys come
before the panel's own: a key bound to both moves.

## The leader key

`<Leader>` in a binding stands for the key the option `leader` names, `\` by
default. Changing the option moves every `<Leader>` binding at once.

```lua
lulibre.o.leader = ","
lulibre.map("n", "<Leader>i", "index")     -- ,i
```

| Key | Command | |
|---|---|---|
| `<Leader>R` | `reload-cfg` | read `init.lua` again |

`:reload-cfg` first puts every key back to the built-in ones, so a binding
you took out of `init.lua` is gone, then runs the file. Options keep their
values unless the file sets them, and what the command line set (`-L`, `-o`)
is applied on top again. The library and index are chosen at start; changing
them needs a restart.

Hints on screen (the status line, the tab line, messages such as "u undoes")
name the keys as they are bound now.

## Your own

```lua
lulibre.map("n", "gu", "filter author:unknown")
lulibre.map("nv", "gp", "run propose")
lulibre.command("unlabelled", function(args)
  lulibre.filter("author:unknown no:tags " .. args)
end, "[filter]  books with neither an author nor a subject")
```

Modes are `"n"` (normal), `"v"` (selecting) or `"nv"`. See [the Lua API](api.md).
