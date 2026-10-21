# Keys and commands

`?` inside lulibre shows the current keys, including the ones `init.lua`
added, under headings that open and close. Enter opens a heading, `/`
searches all the keys as you type, and `K` shows what the guides say about
the key under the cursor. `:help TOPIC` shows the part of these guides about
a word (`:help enrich`, `:help filters`). Every key runs a command, and `:`
runs a command by name.

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
| `gh` | `pick group` | show the list as a tree: by author, subject, series, publisher, year, format, or folder (as the library is filed on disk). `:group count` orders the headings by size, `:group name` by name |
| `gH` | `group none` | the plain list again |
| `<CR>` | `enter` | on a heading: open or close it; on a book: the edit form |
| `l` `<Right>` `zo` · `h` `<Left>` `zc` · `za` | `fold open` / `close` / `toggle` | closing a heading that is already closed moves to the heading that contains it |
| `zR` `zM` | `fold all` / `none` | open, or close, every heading |
| `s` | `pick sort` | the order of the books: title, author, year, latest additions ... (`:sort -added`) |
| `gt` | `browse` | a tree in a left column: `f` switches the grouping, `l`/`h` open and close, `/` finds |
| `Space` | `mark toggle` | on a heading: every book under it. `:mark all`, `none`, `invert` |
| `V` | `visual` | select a range; `Esc` ends it |
| `gp` | `propose` | propose metadata for what is selected, from the files themselves |
| `<Leader>pr` | `propose-review` | a dialog that sets which books, what to consult, which fields and what review shows, then proposes and opens review |
| `<Leader>e` | `enrich-dialog` | look the selection up: shows what would be asked of which services, lets you choose the services, then runs and opens review |
| `<Leader>c` | `change` | one change to every selected book: add or remove a subject, set authors, series, publisher, date, language, title case |
| `<Leader>d` | `datasets-dialog` | the databases lulibre keeps on this machine; choose which to fetch (`:datasets`) |
| `<Leader>s` | `sync-dialog` | in the sync folder: shows what each selected file is, then adds, adds and removes, or drops the files |
| `<Leader><Space>` | `mark none` | unmark every book |
| `<Leader>w` | `weights` | how far each kind of source is trusted, field by field (`:weigh` measures them) |
| `e` · `r` | `edit` · `review selection` | the edit form, or the waiting proposals, for the selection: the range, or else the marked books, or else the books under the heading at the cursor, or else the book at the cursor |
| `R` | `reload` | read calibre's metadata again now |

## The preview

| Key | |
|---|---|
| `J` `K` | scroll |
| `]` `[` | next and previous page |
| `P` | text ⇄ page image |
| `+` `-` `=` | zoom the image in, out, reset |
| `H` `L` | pan the image |
| `a` | if the page shown is past the indexed pages, read the file up to that page (`:addpages BOOK PAGE` does this for any book) |
| `v` | select text with the keys. A cursor appears in the page's text. `h` `j` `k` `l` and the arrows move it, `w` `b` move by words, `0` `$` go to the ends of the line, and `gg` `G` to the ends of the page. `v` starts a selection (pressing it again cancels the selection), and `V` selects the line. `y` or Enter copies and leaves, and `Esc` or `q` leaves. These keys belong to the place `select`: `lulibre.map("select", "n", "down")` |

## Windows

The windows are the list, the previews and the console. Panels (review, the
edit form, the browse column ...) have their own keys, listed below.

| Key | |
|---|---|
| `<C-w>w` `<C-w>W` | next window, the window before (`:focus next`, `:focus prev`) |
| `<C-w>h` `j` `k` `l` | window in that direction |
| `<C-w>v` `<C-w>s` | split with another preview, side by side or stacked |
| `<C-w>c` `<C-w>o` | close this window · close the others |
| `<M-Left>` `<M-Right>` `<M-Up>` `<M-Down>` | move the focused window's edge in that direction (`:resize left` ...) |
| `<Leader>` then an arrow | the same |
| `<C-w>>` `<C-w><` | grow or shrink the focused window |
| `` ` `` | the log console, without moving the focus |

## Panels

| Key | |
|---|---|
| `<Tab>` | from a window, go to the last panel used; in a panel, go to the next panel (`:focus panel`) |
| `<S-Tab>` | go to the previous panel (`:focus panel prev`) |
| `Esc` | in a panel, go back to the window you came from; the panel stays open. A dialog (the edit form, or a form that asks something) closes |
| `q` | close the panel |
| `:new` *command* | only one of each screen is open at a time: `gr` with review open goes to that review, and the same holds for every screen. `:new review` (or `:new` before any command that opens a screen) opens a second copy |
| `/` · `n` `N` | search the panel's rows, as in the list. Rows that contain the text are marked `›`, and the cursor moves to the first match as you type. `n` and `N` go to the next and previous match. If a panel uses `/` (help, the tree browser) or `N` (review: never again) itself, the panel's own key wins |

## The mouse

| | |
|---|---|
| click | select the row and focus the window. In the preview, only a plain click does this; a click that starts a selection leaves the cursor where it was |
| wheel | scroll what the pointer is over |
| drag in the text preview | select text; the text is copied when you release the button |
| double click · triple click there | select the word · the line |
| drag anywhere else | select what is drawn there: a row of the list, a cell of review, the line being typed, the status line, a help or message overlay |
| double click · triple click there | select the word · the row. In a panel, this selects the whole cell, including text its column cut off |
| drag the line between two windows | resize the windows |
| drag a window's bar up or down | resize the window against the window above (the review panel against the list) |
| middle or right click, while typing | paste |

A selection stays within the window (or line) where it started. It is
copied at once, and stays highlighted until the next key or click.

`lulibre.o.mouse = 0` gives the mouse back to the terminal. With the mouse
on, hold Shift to use the terminal's own selection.

## While typing

In the command line, a filter, a search, or a field of the edit form:

| Key | |
|---|---|
| `<C-v>` | paste what was last copied, as one line |
| `<C-y>` | copy the line as it is now |
| the terminal's own paste | the same as `<C-v>`: line breaks become spaces, and nothing is submitted |
| `<PageUp>` `<PageDown>` | scroll the preview without leaving the field |
| `Tab` | take the highlighted suggestion or completion |
| `<C-n>` `<C-p>` | move through the completions |
| `<C-a>` `<C-e>` `<C-u>` `<C-k>` `<C-w>` | go to the start, go to the end, delete to the start, delete to the end, delete a word back |
| `<C-Left>` `<C-Right>` (or with Alt) | move a word back or forward, like `b` and `w` |
| `<Up>` `<Down>` | history entries that start with what you typed (in a field: the suggestion list) |
| `Enter` · `Esc` | accept · cancel |

The command line completes as you type: command names, then each command's
arguments (`:set` option names and their allowed values, `:run` script
names, `:sort` keys). `&` and `/` complete the filter language (`au` →
`author:`, `is:d` → `is:dupe`). History is kept between sessions,
separately for commands, filters and searches.

The mouse still selects in the preview and the panels while a field is
open. So you can drag over a title on the page, or a value in another row,
and paste it with `<C-v>`.

## Changing things

| Key | Command | |
|---|---|---|
| `e` | `edit` | open the edit form for the selection |
| `gc` | `capture` | capture fields from names with a pattern |
| `gr` | `review` | review proposals: what was just proposed, if you haven't seen it yet, or else everything waiting (`l` `h` switch between the two in review) |
| `gT` | `titlecase` | convert titles in CAPITALS to title case |
| `gk` | `good` | list the records by score, to confirm the right ones |
| `u` | `undo` | undo the last batch. `:undo N` undoes a given batch, and `:history` lists the batches |
| `gd` | `dupes` | books with identical files |
| `go` | `orphans` | records without files, files without records, broken links |
| `2` `gS` | `sync` | read the sync folder and show it |
| `gb` | `beside` | the sync folder in a column beside the library: each waiting file next to the same book, or a book that looks like it |
| `1` `gl` | `source library` | back to the library |
| `3` `gC` | `source config` | open the config window, or move the cursor to it if it is open |
| `S` `X` `D` | `sync add` / `sync move` / `sync drop` | add staged files to the library, or move them out of the folder |
| `yb` `yk` `yp` `yy` | `yank bib` / `key` / `path` / `title` | copy to the clipboard |
| | `remove` | remove the selection from calibre (to its recycle bin; `u` undoes) |
| | `embed` | write calibre's metadata into the files themselves |

## Other commands

| Command | |
|---|---|
| `run [script [args]]` | run a Lua script; with no argument, choose one |
| `lua code` | run a line of Lua and show what it returns |
| `tasks` · `cancel ID\|all` | list running scripts · stop them |
| `messages` · `console` | show the log in a pager · the live console |
| `index [force]` | extract text from new or changed files |
| `sort [-]key` | `id title author year series added modified` |
| `set name[=value]` | show or change an option |
| `bib [file]` | write the selection as BibTeX |
| `propose` `enrich` `refs` `arxiv-fetch` `ocr` `onboard DIR` | shortcuts for `run` of those scripts |
| `backup` · `offline` · `custom` · `snapshot` · `units` | copies of calibre's database, changes that wait for the server, your own fields, points to go back to, calibre's server unit (see [Workflows](workflows.md)) |
| `move` `search` `prompt` `fold` `split` `only` `preview` `pick` `source` `yank` | the commands the keys above run, for binding your own keys (`:help` lists each command's arguments) |
| `echo text` | show a message |
| `help` · `help-plain` · `quit` | the same as `?` · the keys and commands as one long page · the same as `q`, `ZZ` |

## Inside a panel

The edit form, review, capture, duplicates, orphans and the tree browser are
panels. In a panel:

- `j` `k` `gg` `G` and the paging keys move.
- `q` closes the panel.
- `Esc` goes back to the window you came from and leaves the panel open. A
  dialog closes instead.
- `/` searches the rows, and `n` `N` move between matches, unless the panel
  uses those keys itself.
- `Tab`, `:` and `<C-w>` work as everywhere else.

The title bar shows a panel's main keys, and `?` lists all of them with
what each does.

You can change a panel's keys. Each panel has named actions (`?` lists
them). `lulibre.map` with the panel's name in place of the modes binds a key
to an action:

```lua
lulibre.map("review", "y", "accept")   -- y accepts, and is the key the hint shows
lulibre.map("review", "a", "")         -- a no longer does anything in review
```

The panels are `edit`, `review`, `dupes`, `orphans`, `capture` and `browse`.

## Keys that belong to a place

Moving inside a panel, editing the line being typed, the picker, an
overlay and the console each have their own keys, with named actions. You
bind them the same way:

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
with its actions and their keys. In a panel, the movement keys take
precedence over the panel's own: a key bound to both moves.

## The leader key

`<Leader>` in a binding stands for the key in the option `leader`, `\` by
default. Changing the option changes every `<Leader>` binding at once.

```lua
lulibre.o.leader = ","
lulibre.map("n", "<Leader>i", "index")     -- ,i
```

| Key | Command | |
|---|---|---|
| `<Leader>R` | `reload-cfg` | read `init.lua` again |

`:reload-cfg` first resets every key to the built-in bindings, so a binding
you removed from `init.lua` is gone. Then it runs the file. Options keep
their values unless the file sets them, and the command line's settings
(`-L`, `-o`) are applied again on top. The library and index are chosen at
start, so changing them needs a restart.

Hints on screen (the status line, the tab line, messages such as "u
undoes") name the keys as they are bound now.

## Your own

```lua
lulibre.map("n", "gu", "filter author:unknown")
lulibre.map("nv", "gp", "run propose")
lulibre.command("unlabelled", function(args)
  lulibre.filter("author:unknown no:tags " .. args)
end, "[filter]  books with neither an author nor a subject")
```

Modes are `"n"` (normal), `"v"` (selecting) or `"nv"`. See [the Lua API](api.md).
