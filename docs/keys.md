# Keys and commands

`?` inside lulibre shows this list as it currently stands, including anything
`init.lua` has added. Every key runs a command; `:` runs one by name.

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
| `gt` | `browse` | tree in a left column: `f` switches facet, `l`/`h` open and close, `/` finds |
| `Space` | `mark toggle` | `:mark all`, `none`, `invert` |
| `V` | `visual` | select a range; `Esc` ends it |
| `R` | `reload` | re-read calibre's metadata now |

## The preview

| Key | |
|---|---|
| `J` `K` | scroll |
| `]` `[` | next and previous page |
| `P` | text ⇄ page image |
| `+` `-` `=` | zoom the image in, out, reset |
| `H` `L` | pan the image |

## Windows

| Key | |
|---|---|
| `<Tab>` `<C-w>w` | next window |
| `<C-w>h` `j` `k` `l` | window in that direction |
| `<C-w>v` `<C-w>s` | split with another preview, side by side or stacked |
| `<C-w>c` `<C-w>o` | close this window · close the others |
| `<C-w>>` `<C-w><` | resize |
| `` ` `` | the log console, without moving the focus |

## The mouse

| | |
|---|---|
| click | select the row, focus the window |
| wheel | scroll what it is over |
| drag in the text preview | select text; it is copied when the button is released |
| double click · triple click there | the word · the line |
| middle or right click, while typing | paste |

`lulibre.o.mouse = 0` hands the mouse back to the terminal. With it on, hold
Shift to make the terminal's own selection.

## While typing

In the command line, a filter, a search, or a field of the edit form:

| Key | |
|---|---|
| `<C-v>` | paste what was last copied, as one line |
| the terminal's own paste | the same: line breaks become spaces, nothing is submitted |
| `<PageUp>` `<PageDown>` | scroll the preview without leaving the field |
| `Tab` | take the highlighted suggestion or completion |
| `<C-n>` `<C-p>` | move through the completions |
| `<C-a>` `<C-e>` `<C-u>` `<C-k>` `<C-w>` | start, end, delete to start, to end, a word back |
| `<Up>` `<Down>` | history: entries that start with what has been typed (in a field: the suggestion list) |
| `Enter` · `Esc` | accept · cancel |

The command line completes as you type: command names, then what each
command takes (`:set` option names and their allowed values, `:run` script
names, `:sort` keys); `&` and `/` complete the filter language (`au` →
`author:`, `is:d` → `is:dupe`). History is kept between sessions, separately
for commands, filters and searches.

The mouse still works in the preview while a field is open, so a title or a
name can be dragged over on the page and pasted with `<C-v>`.

## Changing things

| Key | Command | |
|---|---|---|
| `e` | `edit` | edit form for the selection |
| `gc` | `capture` | fields from names by pattern |
| `gr` | `review` | go through proposals |
| `u` | `undo` | `:undo N` for a given batch; `:history` lists them |
| `gd` | `dupes` | books with identical files |
| `go` | `orphans` | records without files, files without records, broken links |
| `2` `gS` | `sync` | read the sync folder and show it |
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
| `propose` `enrich` `ocr` `onboard DIR` | shortcuts for `run` of those scripts |
| `help` · `quit` | `?` · `q`, `ZZ` |

## Inside a panel

The edit form, review, capture, duplicates, orphans and the tree browser are
panels. `j` `k` `gg` `G` and paging move within one; `q` or `Esc` closes it;
`Tab`, `:` and `<C-w>` keep their meaning. The title bar shows a panel's
main keys, and `?` lists all of them with what each does.

A panel's keys can be changed. Each has named actions (`?` lists them), and
`lulibre.map` with the panel's name in place of the modes puts a key on one:

```lua
lulibre.map("review", "y", "accept")   -- y accepts, and is the key the hint shows
lulibre.map("review", "a", "")         -- a no longer does anything in review
```

The panels are `edit`, `review`, `dupes`, `orphans`, `capture` and `browse`.
Moving and closing (`j k gg G q Esc`) are the same in every panel and are
not configurable, nor are the keys of the line being typed or of a picker.

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
