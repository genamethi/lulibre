# Configuration

lulibre needs no configuration beyond where the library is. Settings come
from four places, each laid over the one below where it sets a value:

1. what Lua sets: `setman.set` in init.lua or a script, and `:set` in the
   interface;
2. the command line: `-o name=value`, `-L DIR`;
3. the saved state, `~/.local/state/lulibre/settings`, read only while the
   setting `persistent` is true;
4. the default.

    lulibre -o help           the settings, their values and what they do
    lulibre -o name=value     a setting for this run
    :set name                 a setting's value; :set name=value changes it
    lulibre --clean           start without init.lua
    lulibre -C DIR            another configuration folder (or $LULIBRE_CONFIG_DIR)

`~/.config/lulibre/init.lua` is plain Lua, and lulibre ships it empty.
lulibre never writes into it.

```lua
setman.set("path.library", "~/calibre-library")
setman.set("ocr", "auto")
```

Every setting Lua can set takes effect at once, except the files the
index opens with (`path.indexdb` and the files beside it), which are read
when it opens. `path.config` and `path.state` come from the command line
only: they say where init.lua and the saved state are.

With `persistent` true, lulibre writes the settings changed during a run
to the saved state when it exits (and on `setman.save()`), and starts from
them the next time; what init.lua or the command line sets still lies over
them. A value saved there stays until it is changed or the file is
removed.

`setman.get` gives a `path.*` setting left empty as the path in use:
`setman.get("path.indexdb")` is the index file lulibre opened.

## Settings

| Setting | Default | |
|---|---|---|
| `path.library` | | the calibre library folder; if not set, `$LULIBRE_LIBRARY`, or else the current directory |
| `path.indexdb` | | the index database; by default `<library's name>-<hash>.db` under `~/.local/share/lulibre/` |
| `path.journaldb` `path.customdb` `path.witdb` | | the journal of changes, your own `#fields`, the wits waiting for review; by default beside the index, `<index>.journal.db` and so on |
| `path.netdb` | | the online answers, for every library; by default `~/.local/share/lulibre/net.db` |
| `path.config` | | where init.lua and `lua/` are; by default `~/.config/lulibre`; command line only |
| `path.state` | | the saved settings; by default `~/.local/state/lulibre/settings`; command line only |
| `persistent` | `false` | keep the settings changed during a run, and start from them next time |
| `path.log` | | also append the log to this file |
| `path.crash` | | where a crash's report goes; by default `~/.local/state/lulibre/crash.log` |
| `jobs` | `0` | worker threads; 0 is one per core |
| `pages` | `6` | the first pages of each file read into the index |
| `ocr` | `never` | `auto`: OCR the files whose text is not usable; `always`: every file |
| `ocr_pages` `ocr_lang` | `3` `eng` | the pages OCR reads, and tesseract's language |
| `auto_index` | `auto` | `auto` · `ask` · `never`: read new or changed files when the interface starts |
| `mouse` | `true` | clicks select, the wheel scrolls |
| `leader` | `\` | the key `<Leader>` stands for |
| `blitter` | `auto` | how page images are drawn: `auto` · `pixel` · `sextant` · `quadrant` · `half` |
| `preview` | `text` | what the preview shows first: `text` · `image` |
| `path.sync` | | a folder of files waiting to be added to the library |
| `path.modtree` | | a module prefix searched after lulibre's own modules and yours; not in a pixi environment |
| `rank_coverage` `rank_agreement` `rank_track` | `45` `35` `20` | what ranking a parse weighs: the fields it fills, its agreement with the sources, its record of review decisions |
| `track_after` | `100` | review decisions the journal holds before a record of decisions counts |
| `similar_near` `similar_same` | `0.7` `0.95` | how much of one value found in another makes them near, and the same |
| `embed` | `false` | every change to a record is also written into the book's files, once per batch |
| `write_jobs` | `4` | calibredb processes at once through the content server; straight to the folder, one |
| `contact_email` | | sent to the metadata services with each request, when set |
| `server` `user` `path.password` | | calibre's content server, which changes go through while it holds the library. lulibre adds the library's name to the address (`#calibre-library`), as calibre's server names it, unless the address has one. lulibre never reads the password: calibredb gets the file's name |

## Colours

```lua
local c = uiman.theme
c.border = "#7982a9"      -- the line between windows
c.bar_bg = "#343a55"      -- a window's top line; the focused window's is `accent`
```

The colour names are `dim accent warn error ok cursor_bg cursor_bg_blur
visual_bg mark title border bar_bg bar_fg on_accent`. `uiman.theme()` returns them
with their values. The defaults assume a dark terminal.

## Keys, commands, scripts

```lua
keymap.set("n", "gu", "filter author:unknown", { desc = "books by nobody" })
keymap.set({"n", "v"}, "gx", function(o) uiman.notify(#o.selection .. " selected") end)
cmd.create("unlabelled", function(o) uiman.filter("author:unknown no:tags " .. o.args) end,
           { desc = "[filter]  books with neither an author nor a subject" })
```

`<Leader>` in a key sequence stands for the key in the setting `leader`.
`:restart-scripts` starts the scripts again in a new Lua state, init.lua
first. See [the Lua API](api.md).

lulibre finds its own modules first, then those in `~/.config/lulibre/lua/`,
then those under the prefix `path.modtree` names, then Lua's own places as Lua
and the environment (`LUA_PATH_5_5`, `LUA_CPATH_5_5`) set them. Nothing is
looked for in the current directory. To change what one of lulibre's
modules does, redefine its function: no file of yours replaces one.

## Where things are kept

| | |
|---|---|
| `~/.config/lulibre/` | `init.lua`, `lua/`, `scripts/` |
| `~/.local/state/lulibre/settings` | the saved settings, while `persistent` is true |
| `~/.local/share/lulibre/NAME-HASH.db` | the index of one library: what lulibre read from it and its files. A new version of its tables makes it again, keeping the sync folder's files |
| `~/.local/share/lulibre/NAME-HASH.journal.db` | beside the index, and never removed with it: every operation on the library, with where each value came from |
| `~/.local/share/lulibre/NAME-HASH.custom.db` | the fields of lulibre's own (`#name`) |
| `~/.local/share/lulibre/NAME-HASH.wit.db` | the wits waiting for review |
| `~/.local/share/lulibre/net.db` | every online answer, for every library |

lulibre honours `XDG_CONFIG_HOME`, `XDG_DATA_HOME` and `XDG_STATE_HOME`,
and each file has a `path.*` setting (above) that puts it elsewhere.

## Terminals

- **tmux.** The mouse needs `set -g mouse on`. Copies go through
  `tmux load-buffer -w`, so they land in a tmux paste buffer and, unless
  `set-clipboard` is `off`, in the terminal's clipboard. Page images are
  drawn with block characters, since tmux does not pass graphics through.
- **A terminal with the kitty graphics protocol** (ghostty, kitty), outside
  tmux: `blitter = "auto"` asks notcurses for real pixels. This is not
  tested yet; if it misbehaves, set `blitter = "sextant"`.
- **Over ssh**, outside tmux, copies use OSC 52, which the terminal must allow.
