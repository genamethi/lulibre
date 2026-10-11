# Configuration

`~/.config/lulibre/init.lua` is plain Lua, loaded at startup.

    lulibre config            print it with every option and the values in effect
    lulibre config --write    save a first one, if none exists
    lulibre -o help           the options, one per line
    lulibre -o name=value     override one for this run
    :set name=value           inside the interface, until it closes
    lulibre --clean           start without init.lua
    lulibre -C DIR            use another configuration directory (or $LULIBRE_CONFIG_DIR)

## Options

```lua
local o = lulibre.o
o.library = "~/calibre-library"
```

| Option | Default | |
|---|---|---|
| `library` | | calibre library directory (else `$LULIBRE_LIBRARY`, else the current directory) |
| `server` `user` `password_file` | | calibre content server, for changes |
| `write_via` | `auto` | `auto` · `server` · `direct`: how changes reach calibre |
| `index` | | index database (default under `~/.local/share/lulibre/`) |
| `pages` | `6` | first pages of each file indexed as text |
| `layout_pages` | `2` | of those, pages kept as lines tagged with font size |
| `jobs` | `0` | worker threads; 0 is one per core |
| `ocr` | `never` | `never` · `auto` · `always` |
| `ocr_pages` `ocr_lang` | `3` `eng` | pages per file the OCR pass reads; tesseract language |
| `write_jobs` | `6` | `calibredb` processes at once (direct writes run one at a time) |
| `sync_dir` | | folder of files waiting to be added |
| `orphans_dir` | | where stray files are set aside |
| `preview` | `text` | `text` · `image`: what the preview shows first |
| `blitter` | `auto` | `auto` · `pixel` · `sextant` · `quadrant` · `half`: how page images are drawn |
| `mouse` | `1` | clicks and the wheel |
| `review_open` | `0` | `1`: review starts with every book's other fields shown |
| `log_file` | | also append the log to this file (`$LULIBRE_LOG` does the same) |
| `config_dir` | | where `init.lua`, `scripts/` and `lua/` are looked for; reads as the directory in effect |

From Lua the same options are `lulibre.settings.get(name)` and
`lulibre.settings.set(name, value)`; `lulibre.settings.paths()` says where
everything is.

### Things lulibre may do on its own

These take `"auto"` (do it), `"ask"` (ask first; means no where there is
nobody to ask, as in `lulibre run`) or `"never"`:

| Option | Default | |
|---|---|---|
| `auto_index` | `auto` | index new or changed files at start (`ask` only says how many wait) |
| `repair_links` | `ask` | after a rename, fix links in your own folders that pointed at the book |
| `carry_metadata` | `auto` | before a duplicate or orphan record is removed, keep what only it knew as proposals |
| `sync_propose` | `ask` | propose metadata for files new to the sync folder |

## Colours

```lua
local c = lulibre.theme
c.border = "#7982a9"      -- the line between windows
c.bar_bg = "#343a55"      -- a window's top line; the focused window's is `accent`
```

Names: `dim accent warn error ok cursor_bg cursor_bg_blur visual_bg mark
title border bar_bg bar_fg on_accent`. `:lua lulibre.theme()` lists them with
their values. The defaults assume a dark terminal.

## Keys, commands, scripts

```lua
lulibre.map("n", "gu", "filter author:unknown")       -- a command line
lulibre.map("nv", "gx", function()                    -- or a function
  lulibre.notify(#lulibre.selection() .. " selected")
end)
lulibre.command("unlabelled", function(args)
  lulibre.filter("author:unknown no:tags " .. args)
end, "[filter]  books with neither an author nor a subject")
```

Scripts in `~/.config/lulibre/scripts/NAME.lua` run with `:run NAME` or
`lulibre run NAME`; modules in `~/.config/lulibre/lua/` can be `require`d.
See [the Lua API](api.md).

## Where things are kept

| | |
|---|---|
| `~/.config/lulibre/` | `init.lua`, `scripts/`, `lua/`. Another directory: `lulibre -C DIR`, `$LULIBRE_CONFIG_DIR`, or the option `config_dir` |
| `~/.local/share/lulibre/NAME-HASH.db` | the index of one library. Derived from the library and rebuilt at will, except for what lulibre alone knows: the undo journal, proposals, staged files' metadata, saved capture rules, file hashes |
| `~/.local/share/lulibre/orphans/` | stray files set aside |

`XDG_CONFIG_HOME` and `XDG_DATA_HOME` are honoured.

## Terminals

- **tmux.** The mouse needs `set -g mouse on`. Copies go through
  `tmux load-buffer -w`, so they land in a tmux paste buffer and, unless
  `set-clipboard` is `off`, in the terminal's clipboard. Page images are
  drawn with block characters, since tmux does not pass graphics through.
- **Directly in a terminal with the kitty graphics protocol** (ghostty,
  kitty): `blitter = "auto"` asks notcurses for real pixels. Not yet tested;
  set `blitter = "sextant"` if it misbehaves.
- **Over ssh**, outside tmux, copies use OSC 52, which the terminal must allow.
