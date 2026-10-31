# Keys and commands

`?` inside lulibre shows the keys of the window you are in first, then the
global keys (including the ones `init.lua` added), every place's and the
commands, under headings that open and close: `<CR>` or `za` on a heading,
`zR` and `zM` for all of them. `/` searches as you type and opens the
headings with a match. A heading stays as you left it the next time; `:help-plain`
shows every one open. Every key runs a command, and `:` runs a command by
name.

`:help TOPIC` opens these guides where they speak of TOPIC: a heading
(`:help filters`, `:help the leader key`), a command (`:help :enrich`, or
`:help enrich`), a setting (`:help 'ocr'`), a key (`:help gh`), a Lua
function (`:help uiman.list`); Tab completes it. With nothing headed so,
it lists the lines that mention TOPIC. In a guide, and on `?`'s keys and
commands, `K` or `<C-]>` follows the link on the cursor's line, `<C-t>`
goes back and `<Tab>` forward again. The guides are lulibre's and the
Markdown files in `docs/` under the configuration and data folders
([configuration](configuration.md)).

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
| `Space` | `mark toggle` | on a heading: every book under it. `:mark all`, `none`, `invert` |
| `V` | `visual` | select a range; `Esc` ends it |
| `gp` | `propose` | propose metadata for what is selected, from the files themselves and the online answers kept for them |
| `<Leader><Space>` | `mark none` | unmark every book |
| `R` | `reload` | read calibre's metadata again now, every book |

## The preview

| Key | |
|---|---|
| `J` `K` | scroll |
| `]` `[` | next and previous page |
| `P` | text ⇄ page image |
| `+` `-` `=` | zoom the image in, out, reset |
| `H` `L` | pan the image |
| `a` | if the page shown is past the indexed pages, read the file up to that page (`:addpages BOOK PAGE` does this for any book) |
| `v` | select text with the keys. A cursor appears in the page's text. `h` `j` `k` `l` and the arrows move it, `w` `b` move by words, `0` `$` go to the ends of the line, and `gg` `G` to the ends of the page. `v` starts a selection (pressing it again cancels the selection), and `V` selects the line. `y` or Enter copies and leaves, and `Esc` or `q` leaves. These keys belong to the place `select`: `keymap.set("select", "n", "down")` |

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

`setman.set("mouse", false)` gives the mouse back to the terminal. With the mouse
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
arguments (`:set` setting names and their allowed values, `:sort` keys, a filter for `:propose`), as the command says, a
command made in Lua too (`complete`, [the API](api.md)). `&` and `/` complete the filter language (`au` →
`author:`, `is:o` → `is:ocr`). History is kept between sessions,
separately for commands, filters and searches.

The mouse still selects in the preview and the panels while a field is
open. So you can drag over a title on the page, or a value in another row,
and paste it with `<C-v>`.

## Changing things

| Key | Command | |
|---|---|---|
| `e` | `edit` | the edit form for the selection: Enter or `e` types a field's value (`+a, -b` adds to a list and takes out of it), `x` drops a field's change, `w` writes them all (the place `form`) |
| `gr` · `r` | `review` · `review selection` | the proposals of every book that has any, or of the selection: `a` accepts, `e` edits first, `r` rejects, Space shows the next alternative |
| `u` | `undo` | put the last change back |
| `1` … `9` | `source N` | the bar's tab with that number |
| `gl` | `source library` | back to the library |
| `gS` | `source sync` | the files waiting in the sync folder (`path.sync`), read again |

The bar's tabs are the library, the sync folder once one is set, and
each screen made with `tab = true` ([the API](api.md)); clicking one, or
`:source NAME`, shows it.

## Other commands

| Command | |
|---|---|
| `run [script [args]]` | run a Lua script; with no argument, choose one |
| `lua code` | run a line of Lua and show what it returns |
| `tasks` · `cancel ID\|all` | list running scripts · stop them |
| `messages` · `console` | show the log in a pager · the live console |
| `index [force]` | extract text from new or changed files |
| `sort [-]key` | `id title author year series added modified` |
| `set name[=value]` | show or change a setting |
| `propose [filter]` · `review [filter]` · `enrich [filter]` | proposals for the books (from the grammars, the identifiers in their text and the online records), their review, and online lookups by the identifiers the records have or the text gave; without a filter, the selection |
| `restart-scripts` | a new Lua state; init.lua runs first, as at start |
| `move` `search` `prompt` `fold` `split` `only` `preview` `pick` `source` | the commands the keys above run, for binding your own keys (`:help` lists each command's arguments) |
| `echo text` | show a message |
| `config` | the settings, in the bar's Configuration tab ([configuration](configuration.md)) |
| `units [apply]` | lulibre's systemd units around calibre's content server ([workflows](workflows.md#calibres-server-and-lulibres-systemd-units)) |
| `help` · `help-plain` · `quit` | the same as `?` · the keys and commands as one long page · the same as `q`, `ZZ` |

## Inside a panel

The edit form and review are panels, and so are the panels scripts open
(`uiman.panel`). In a panel:

- `j` `k` `gg` `G` and the paging keys move.
- `q` closes the panel.
- `Esc` goes back to the window you came from and leaves the panel open. A
  dialog closes instead.
- `/` searches the rows, and `n` `N` move between matches, unless the panel
  uses those keys itself.
- `Tab`, `:` and `<C-w>` work as everywhere else.

The title bar shows a panel's main keys, and `?` lists all of them with
what each does.

## Keys that belong to a place

Moving inside a panel, editing the line being typed, the picker, an
overlay and the console each have their own keys, with named actions.
`keymap.set` with the place's name in place of the modes binds a key to an
action:

```lua
keymap.set("panel", "n", "down")        -- n moves down in every panel
keymap.set("line", "<C-g>", "cancel")   -- <C-g> leaves the line being typed
keymap.set("console", "x", "close")
keymap.del("line", "<C-k>")             -- unbind
keymap.set("panel", "n", "down", { desc = "the next row" })   -- what ? says the action does
keymap.set("console", "c", "clear", { hidden = true })       -- ? leaves the action out
scrnman.set("console", { hint = { "clear", "close" } })     -- what its bar shows
```

The hint a place shows (the console's bar, the picker's foot, the
overlay's title, the bottom line while typing, the message when
selecting in the preview, a panel with no hint of its own) is a list of its
actions, which `scrnman.set` changes; `hint = {}` shows none.

| Place | Actions |
|---|---|
| `panel` | `down` `up` `top` `bottom` `half-down` `half-up` `page-down` `page-up` `close` |
| `line` | `accept` `cancel` `paste` `copy` `complete` `next` `prev` `up` `down` `preview-up` `preview-down` `left` `right` `home` `end` `backspace` `delete` `kill-start` `kill-end` `kill-word` `word-left` `word-right` |
| `picker` | `accept` `cancel` `down` `up` `page-down` `page-up` |
| `pager` | `down` `up` `page-down` `page-up` `top` `bottom` `toggle` `open` `close` `all` `none` `search` `next` `prev` `follow` `back` `forward` `leave` (any other key closes it) |
| `console` | `up` `down` `half-up` `half-down` `top` `follow` `errors` `warnings` `notices` `everything` `clear` `close` |
| `select` | `left` `right` `up` `down` `word` `back` `start` `end` `top` `bottom` `mark` `line` `copy` `leave` |
| `form` | `edit` `drop` `write`: in the edit form and the forms of scripts (`uiman.form`); `drop` and `write` in a form that writes on `w` |

A screen made in Lua is a place too (`scrnman.create`, [the API](api.md)):
`review` (`accept` `edit` `reject` `next`) is lulibre's, and
`keymap.set("review", "y", "accept")` rebinds one.

`keymap.set("list", key, command or function)` and `keymap.set("preview",
...)` bind a key for that view alone: while it has the focus, in normal
mode, the key runs that, before a global binding of the same key.
`scrnman.set("console", { place = { kind = "column" } })` says where the
console opens, and `scrnman.set("preview", { place = { kind = "band", size =
0.4 } })` moves the preview (`band`, `column` or `tiled`).

A binding here is one key, or two in a row (`gg`). `?` lists every place
with its actions and their keys. In a panel, the movement keys take
precedence over the panel's own: a key bound to both moves.

## The leader key

`<Leader>` in a binding stands for the key in the setting `leader`, `\` by
default. Changing the setting changes every `<Leader>` binding at once.

```lua
setman.set("leader", ",")
keymap.set("n", "<Leader>i", "index")     -- ,i
```

`:restart-scripts` starts the scripts again in a new Lua state: the keys
go back to the built-in ones first, so a binding you removed from
`init.lua` is gone, and then init.lua runs.

Hints on screen (the status line, the tab line, messages such as "u
undoes") name the keys as they are bound now.

## Your own

```lua
keymap.set("n", "gu", "filter author:unknown", { desc = "books by nobody" })
keymap.set({"n", "v"}, "gx", function(o) uiman.notify(#o.selection .. " selected") end)
cmdman.create("unlabelled", function(o) uiman.filter("author:unknown no:tags " .. o.args) end,
           { desc = "[filter]  books with neither an author nor a subject" })
```

Modes are `"n"` (normal), `"v"` (selecting), or both. `desc` is what the
help overlay (`?`) shows for the key; `hidden = true` leaves it out. See
[the Lua API](api.md).
