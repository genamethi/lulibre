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

With the mouse: a click selects a row and focuses its window; the wheel
scrolls what it is over. Hold Shift to select text. `lulibre.o.mouse = 0`
turns this off.

## Changing things

| Key | Command | |
|---|---|---|
| `e` | `edit` | edit form for the selection |
| `gc` | `capture` | fields from names by pattern |
| `gr` | `review` | go through proposals |
| `u` | `undo` | `:undo N` for a given batch; `:history` lists them |
| `gd` | `dupes` | books with identical files |
| `go` | `orphans` | records without files, files without records, broken links |
| `gS` | `sync` | read the sync folder and show it |
| `gl` | `source library` | back to the library |
| `S` `X` | `sync add` / `sync move` | staged files into the library |
| `yb` `yk` `yp` `yy` | `yank bib` / `key` / `path` / `title` | copy to the clipboard |
| | `remove` | remove the selection from calibre (to its recycle bin) |
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
`Tab`, `:` and `<C-w>` keep their meaning. Its own keys are shown in its
title bar.

## Your own

```lua
lulibre.map("n", "gu", "filter author:unknown")
lulibre.map("nv", "gp", "run propose")
lulibre.command("unlabelled", function(args)
  lulibre.filter("author:unknown no:tags " .. args)
end, "[filter]  books with neither an author nor a subject")
```

Modes are `"n"` (normal), `"v"` (selecting) or `"nv"`. See [the Lua API](api.md).
