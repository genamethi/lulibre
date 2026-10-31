# Configuration

lulibre needs no configuration beyond where the library is. Settings come
from four places, each laid over the one below where it sets a value:

1. the command line: `-o name=value`, `-L DIR`;
2. what Lua sets: `setman.set` in init.lua or a script, and `:set` in the
   interface;
3. the saved state, `~/.local/state/lulibre/settings`, read only while the
   setting `persistent` is true;
4. the default.

What init.lua sets as lulibre starts (up to its first wait) lies under the
command line. A change made after that, by `:set`, a command, a key or a
script, replaces the command line's value.

    lulibre -o help           the settings, their values and what they do
    lulibre -o name=value     a setting for this run
    :set                      every setting, its value and where it is set
    :config                   the same as a form, in the bar's Configuration tab
    :set name                 a setting's value; :set name=value changes it
    lulibre --clean           start without init.lua
    lulibre -C DIR            another configuration folder (or $LULIBRE_CONFIG_DIR)

A name no setting has, given with `-o` or in the saved state, is held
while init.lua starts, for a setting a script makes (`setman.create`,
[the API](api.md)); one nothing made is said, and lulibre goes on.

`~/.config/lulibre/init.lua` is plain Lua. lulibre never writes into it;
lulibre-setup writes one only where there is none.

```lua
setman.set("path.library", "~/calibre-library")
setman.set("ocr", "auto")
```

`lulib.opt` is the settings as a table, as Neovim's `vim.opt`: a setting
read is `setman.get`, a setting assigned is `setman.set`.

```lua
-- lua/config/options.lua, loaded by `require "config.options"` in init.lua
local opt = lulib.opt
opt.path.library = "~/calibre-library"
opt.ocr = "auto"
opt.path.log = os.getenv("HOME") .. "/lulibre.log"
```

Any other name is a field of the table like any other, so options of your
own can be kept there too. lulibre-setup writes the values chosen on its
screen to `lua/config/options.lua`. With `persistent` true, what this file
sets is set again at each start, over the saved state.

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
| `path.library` | | the calibre library folder; if not set, `$LULIBRE_LIBRARY`, else the current directory when it is a library; else, on a terminal, lulibre asks whether to open the library calibre opened last (`library_path` in calibre's `global.py.json`), then about calibre's content server when one is running (found among the processes, with the port it listens on); the answers hold for that run |
| `path.indexdb` | | the index database; by default `<library's name>-<hash>.db` under `~/.local/share/lulibre/` |
| `path.journaldb` `path.customdb` `path.witdb` | | the journal of changes, your own `#fields`, the wits waiting for review; by default beside the index, `<index>.journal.db` and so on |
| `path.netdb` | | the online answers, for every library; by default `~/.local/share/lulibre/net.db` |
| `path.config` | | where init.lua and `lua/` are; by default `~/.config/lulibre`; command line only |
| `path.state` | | the saved settings; by default `~/.local/state/lulibre/settings`; command line only |
| `persistent` | `false` | keep the settings changed during a run, and start from them next time |
| `path.log` | | also append the log to this file |
| `path.crash` | | where a crash's report goes; by default `~/.local/state/lulibre/crash.log` |
| `jobs` | `0` | worker threads; 0 is one per core |
| `pages` | `10` | the first pages of each file read into the index |
| `ocr` | `auto` | `never`: no OCR; `auto`: OCR the files whose text is not usable; `always`: every file |
| `ocr_pages` `ocr_lang` | `3` `eng` | the pages OCR reads, and tesseract's language |
| `auto_index` | `auto` | `auto` · `ask` · `never`: read new or changed files when the interface starts |
| `mouse` | `true` | clicks select, the wheel scrolls |
| `leader` | `\` | the key `<Leader>` stands for |
| `blitter` | `auto` | how page images are drawn: `auto` · `pixel` · `sextant` · `quadrant` · `half` |
| `preview` | `text` | what the preview shows first: `text` · `image` |
| `path.sync` | | a folder of files waiting to be added to the library: its ebook files are read with calibre's records, and each is a book in `in:sync` (2 or gS shows them) |
| `path.modtree` | | a module prefix searched after lulibre's own modules and yours; not in a pixi environment |
| `rank_coverage` `rank_agreement` `rank_track` | `45` `35` `20` | what ranking a parse weighs: the fields it fills, its agreement with the sources, its record of review decisions |
| `track_after` | `100` | review decisions the journal holds before a record of decisions counts |
| `similar_near` `similar_same` | `0.7` `0.95` | how much of one value found in another makes them near, and the same |
| `embed` | `false` | every change to a record is also written into the book's files, once per batch |
| `expose_modules` | `true` | the internal functions of lulibre's modules are in their tables, and redefining one changes what lulibre does; `false`: lulibre calls its own |
| `write_jobs` | `4` | calibredb processes at once through the content server; straight to the folder, one |
| `contact_email` | | sent to the metadata services with each request, when set |
| `server` `user` `path.password` | | calibre's content server, which changes go through while it holds the library. lulibre adds the library's name to the address (`#calibre-library`), as calibre's server names it, unless the address has one. lulibre never reads the password: calibredb gets the file's name |
| `server_hook` | `false` | lulibre's systemd unit runs `lulibre offline` before each start of calibre's content server's unit: calibre's records read, the changes that wait made ([workflows](workflows.md#calibres-server-and-lulibres-systemd-units)) |
| `opf_writer` | `off` | `server`: calibre's content server starts with calibre's own opf writer, through a drop-in on its unit |
| `server_restart_at` | | `HH:MM`: a timer restarts calibre's content server every day at that time |

`:config` (the bar's Configuration tab) shows every setting as a form, in
the list's place: its value, where the value comes from, and, in a band
below, what the setting under the cursor does, its default and what it
takes. `e` or Enter types a value, Space takes the next of its choices
(true or false), `d` gives it its default back and `c` shows only the
settings not at their default. A change takes effect at once and holds
for the run, or is kept with `persistent` true.

## Colours

```lua
local c = uiman.theme
c.border = "#7982a9"      -- the line between windows
c.bar_bg = "#343a55"      -- a window's top line; the focused window's is `accent`
```

The colour names are `dim accent warn error ok cursor_bg cursor_bg_blur
visual_bg mark title border bar_bg bar_fg on_accent`. `uiman.theme()` returns them
with their values. The defaults assume a dark terminal.

## Keys and commands

```lua
keymap.set("n", "gu", "filter author:unknown", { desc = "books by nobody" })
keymap.set({"n", "v"}, "gx", function(o) uiman.notify(#o.selection .. " selected") end)
cmdman.create("unlabelled", function(o) uiman.filter("author:unknown no:tags " .. o.args) end,
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

## One way to lay out a configuration

init.lua can stay a list of `require`s, one module of `lua/config/` for
each kind of thing:

```
~/.config/lulibre/
  init.lua
  lua/config/
    options.lua     settings
    keymaps.lua     keys
    cmds.lua        commands
    events.lua      what runs when something happens
```

```lua
-- init.lua
require "config.options"
require "config.keymaps"
require "config.cmds"
require "config.events"
```

```lua
-- lua/config/options.lua
local opt = lulib.opt
opt.path.library = "~/calibre-library"
opt.ocr = "auto"
```

```lua
-- lua/config/keymaps.lua
keymap.set("n", "<Leader>u", "filter author:unknown", { desc = "books by nobody" })
```

```lua
-- lua/config/cmds.lua
cmdman.create("untagged", function(o) uiman.filter("subject:none " .. o.args) end,
              { desc = "[filter]  books with no subject" })
```

```lua
-- lua/config/events.lua
evman.add("records_changed", function(ev)
  if #ev.fields == 0 then uiman.notify(#ev.ids .. " books changed in calibre") end
end)
```

## Where things are kept

| | |
|---|---|
| `~/.config/lulibre/` | `init.lua`, `lua/`, `docs/` |
| `~/.config/lulibre/docs/`, `~/.local/share/lulibre/docs/` | guides of your own, Markdown files `:help` reads after lulibre's (and their folders'): each heading is a tag, and so is what a table's first column names in `code` (a command under a `Command` heading, a setting under `Setting`, a key under `Key`) |
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
