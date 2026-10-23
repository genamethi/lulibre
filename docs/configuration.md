# Configuration

`~/.config/lulibre/init.lua` is plain Lua. lulibre loads it at startup.

    lulibre config            print init.lua with every option and the value in effect
    lulibre config --write    write a first init.lua, if there is none
    lulibre -o help           list the options, one per line
    lulibre -o name=value     set an option for this run
    :set name=value           set an option in the interface, until it closes
    lulibre --clean           start without init.lua
    lulibre -C DIR            use another configuration directory (or $LULIBRE_CONFIG_DIR)

## Options

```lua
local o = lulibre.o
o.library = "~/calibre-library"
```

| Option | Default | |
|---|---|---|
| `library` | | the calibre library folder. If not set, `$LULIBRE_LIBRARY`, or else the current directory |
| `server` `user` `password_file` | | the calibre content server that changes go through |
| `write_via` | `auto` | `auto` · `server` · `direct`: how changes reach calibre |
| `server_stop` `server_start` | | shell commands that stop and start the content server. lulibre uses them for the changes that wait for the server to stop (`:offline`). If empty, those changes wait for the server's next restart |
| `server_hook` | `false` | `true`: install `lulibre.service`, which runs `lulibre offline` before each start of the server's systemd unit (see "lulibre's systemd units" in [Workflows](workflows.md)) |
| `opf_writer` | `off` | `server`: start the server's unit through lulibre's launcher, so calibre's own writer keeps the books' metadata.opf files current while the server runs |
| `server_restart_at` | | a time of day, `HH:MM`, at which `lulibre-restart.timer` restarts the server every day. If empty, the server is never restarted |
| `backup_restart` | `always` | when to copy calibre's database before the server starts: `always`, `next` (once), `never`, or a number of days (`:backup`) |
| `backup_keep` | `5` | how many copies are kept |
| `backup_too_old` `backup_max_age` | `warn` `7` | offer a copy at the first change of a session if the newest copy is older than this many days. `false` turns the offer off |
| `backup_metadata` | `true` | have calibre write each changed book's metadata.opf (`calibredb backup_metadata`) whenever nothing else can: each time the content server is stopped, and after lulibre changes the library straight in its folder. Adding or removing a calibre column waits until these files are written |
| `index` | | the index database. By default it is under `~/.local/share/lulibre/` |
| `pages` | `6` | how many first pages of each file are indexed as text |
| `layout_pages` | `2` | how many of those pages are also kept as lines tagged with font size |
| `jobs` | `0` | worker threads. 0 means one per core |
| `ocr` | `never` | `never` · `auto` · `always` |
| `ocr_pages` `ocr_lang` | `3` `eng` | how many pages of each file OCR reads, and tesseract's language |
| `ocr_write` | `off` | `off` · `replace` · `keep`: OCR also writes the text it read into the PDF (ocrmypdf). `keep` keeps the original in `ocr_originals` |
| `ocr_originals` | | where `ocr_write = keep` puts the originals, outside the library. By default `ocr-originals/` under the data folder |
| `text_fallback` | `auto` | `off` · `auto`: read garbled pages again with pdftotext, if it is installed (`:run reread`) |
| `write_jobs` | `6` | how many `calibredb` processes run at once. Direct writes run one at a time |
| `propose_min` | `60` | proposals with a confidence under this percentage are stored, but review doesn't show them and they don't count as waiting. Every summary says how many there are. Lower the value to see them |
| `propose_held` | `replace` | `replace` · `keep`: when another value is proposed for the same book and field, remove the proposals under `propose_min`, or keep them all |
| `propose_over` | `sure` | `gaps` · `sure` · `any`: whether `:propose` proposes for a field that already has a value. See [Workflows](workflows.md) |
| `enrich_services` | `arxiv,crossref,zbmath,openlibrary,openalex` | the metadata services `:enrich` asks |
| `arxiv_snapshot` | | a file of arXiv's records: arXiv's snapshot from Kaggle, or a hypergraph of arXiv, as `.json` or the `.zip`. If empty, lulibre uses the first of `arxiv-metadata-oai-snapshot.json`, `arxiv.json` or `arxiv.zip` in the data folder (a link works). `:enrich` reads papers from the file and asks arXiv only about papers newer than the file |
| `weigh_sources` | `false` | `true`: a proposal's confidence combines its agreeing sources, each weighted by how often it has been right in this library (`:weigh`, `:weights`) |
| `contact_email` | | an e-mail address sent to the metadata services with each request. If empty, nothing is sent |
| `refs_pages` | `14` | how many closing pages of a file are read to find its bibliography |
| `one_word_titles` | `check` | `check` · `ok` · `junk`: whether a one-word title counts as a title. With `check`, a plain capitalised word does |
| `good_titles` | | titles, separated by commas, that always count as titles |
| `never_titles` | | words and phrases, separated by commas, that mark a title as not a title |
| `learned_tags` | `off` | `off` · `suggest` · `propose`: use subjects learned from the library (the phrases `:learn` finds, and the references books share). `suggest` offers them in the edit form, and `propose` also makes them proposals |
| `learned_tags_min` | `20` | the confidence, in percent, a learned subject needs for review to show it. Used instead of `propose_min` |
| `subject_terms` | `20` | how many marking phrases `:learn` keeps for each subject |
| `subject_catchall` | | subjects (or their last part), separated by commas, that file a book by its form, not its topic |
| `never_authors` | | words and phrases, separated by commas, that are never proposed as an author. They add to the built-in ranks and roles |
| `title_case` | `auto` | `auto` · `never`: propose a title found in CAPITALS, and a catalogue's title for a book in English, in title case |
| `math_notation` | `unicode` | `unicode` · `off`: write the mathematics in proposed titles in Unicode (SL₂(ℤ), GLₙ(ℚₚ)) |
| `sync_dir` | | the folder of files waiting to be added |
| `orphans_dir` | | where stray files are set aside |
| `preview` | `text` | `text` · `image`: what the preview shows first |
| `blitter` | `auto` | `auto` · `pixel` · `sextant` · `quadrant` · `half`: how page images are drawn |
| `mouse` | `1` | clicks and the wheel |
| `review_open` | `0` | `1`: review starts with every book's other fields shown |
| `review_rows` | `field` | `field` · `all`: one row per field with the most confident proposal, or one row per proposal |
| `review_context` | `1` | `1`: show a panel in place of the list. Review shows what the proposal under the cursor is based on, duplicates shows the copies side by side, orphans shows the whole row, and the edit form shows what the pages say. `i` hides the panel |
| `review_reject` | `once` | `once` · `always`: whether a later run may propose a rejected value again |
| `review_sort` | `evidence` | `evidence` · `confidence` · `disputed` · `id`: the order of books in review: best supported by their pages, most confident, most disputed, or by id |
| `leader` | `\` | the key `<Leader>` stands for in key bindings |
| `log_file` | | a file the log is also appended to (`$LULIBRE_LOG` does the same) |
| `pixi_deps` | `false` | `true`: programs that features need (pdftotext, tesseract, ocrmypdf) may come from a pixi environment lulibre keeps, and lulibre offers to add a missing one |
| `mod_tree` | | a prefix of Lua modules, searched before any other place; ignored in a pixi environment |
| `rocks_install` | `false` | `true`: lulibre offers to install a rock a script needs into `mod_tree` (`luarocks --tree`) |
| `config_dir` | | where `init.lua`, `scripts/` and `lua/` are looked for. Reading it gives the directory in use |

In Lua, the same options are read and set with `lulibre.settings.get(name)`
and `lulibre.settings.set(name, value)`. `lulibre.settings.paths()` returns
where everything is.

### Things lulibre may do on its own

These options take `"auto"` (do it), `"ask"` (ask first) or `"never"`.
Where nobody can be asked, as in `lulibre run`, `"ask"` means no.

| Option | Default | |
|---|---|---|
| `auto_index` | `auto` | index new or changed files at start. `ask` only says how many are waiting |
| `repair_links` | `ask` | after calibre renames a book's folder, fix the links in your own folders that pointed at the book |
| `carry_metadata` | `auto` | before a duplicate or orphan record is removed, keep what only that record knew as proposals |
| `sync_propose` | `ask` | propose metadata for files new to the sync folder |

### The password file

`password_file` names a file that holds the content server's password and
nothing else. lulibre never reads the file: `calibredb` gets the file's
name and reads the password itself. Make the file readable only by you
(`chmod 600`). lulibre warns in the console if other users can read it.

The password can't be stored as a salted hash. A hash is for checking a
password someone types, and can't be turned back into the password, but
`calibredb` needs the password itself to log in to the server. The file's
permissions protect the password, so keep the file out of anything that is
copied or committed.

### The config window: tab `3`

The bar along the top has a tab for the config window, `3 Configuration`.
`3`, `gC`, `:config` or a click on the tab opens the window across the
screen, in place of the list and the preview. `1` or `2`, or a click on
their tabs, goes back to the list.

The window lists every option under its heading: lulibre's own options, and
each script's options under the script's name. Each option shows its value,
its default and the line of init.lua that sets it. Below the list, a panel
says what the option under the cursor does and which values it takes.

| Key | |
|---|---|
| `Enter` `e` | set the option. The value takes effect at once and is written to the option's line in init.lua, after the old file is saved as `init.lua.bak` |
| `d` | reset the option to its default: the line is commented out and shows the default |
| `E` | open init.lua in your editor (`$VISUAL`, `$EDITOR`, or else vim or vi). lulibre waits until you leave the editor, then reads init.lua again |
| `a` | add the options that are not in init.lua, with their defaults, commented out or set (`config_add_as`) |
| `c` | choose what is written above an added option: `full` help, the `values` it takes, or `none` (`config_comments`) |
| `f` | show only the options that differ from their defaults |

Options that are not in init.lua are added only when you press `a`.
`config_add_core` and `config_add_scripts` change that: `never` (the
default), `ask` (offered the first time the window opens in a session) or
`auto` (added when lulibre starts).

`config_add_as` sets how an option is added. `commented` (the default)
adds it commented out with its default, so the default stays lulibre's and
you get later changes to it. `set` adds it set to its default, so the value
is yours from then on. An option without help gets no comment, whatever
`config_comments` says.

### Options of scripts

A script declares its options when it starts, under a name of its own:

```lua
local opt = lulibre.option("mytags", {
  depth = { default = 2, type = "number", help = "how many levels of subject to keep" },
  style = { default = "short", choices = "short|long" },
})
if opt.depth > 1 then ... end
```

init.lua sets them by that name, before or after the script has run:

```lua
lulibre.cfg.mytags.depth = 3
```

A value set in init.lua overrides the script's own value, unless the
script sets it with `force`. A value changed during the session (in the
config window or with `:lua`) overrides both until lulibre closes. Every
value is checked against the declared type and choices.

## Colours

```lua
local c = lulibre.theme
c.border = "#7982a9"      -- the line between windows
c.bar_bg = "#343a55"      -- a window's top line; the focused window's is `accent`
```

The colour names are `dim accent warn error ok cursor_bg cursor_bg_blur
visual_bg mark title border bar_bg bar_fg on_accent`. `:lua lulibre.theme()`
lists them with their values. The defaults assume a dark terminal.

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

A fourth argument sets what the help overlay (`?`) shows for the key.
`false` leaves the key out of the overlay:

```lua
lulibre.map("n", "gB", "run bib", "write the selection as BibTeX")
lulibre.map("n", "gH", function() ... end, false)
```

`<Leader>` in a key sequence stands for the key in the `leader` option. A
panel's name in place of the modes binds one of that panel's actions; see
[Keys](keys.md). `:reload-cfg` (`<Leader>R`) reads `init.lua` again.

`:run NAME` or `lulibre run NAME` runs the script
`~/.config/lulibre/scripts/NAME.lua`. Modules in `~/.config/lulibre/lua/`
can be `require`d.

lulibre looks for your scripts and modules first. A script or module of
yours with the same name as one of lulibre's (`scripts/sync.lua`,
`lua/lulibre/edit.lua`) is used instead of lulibre's. Since your copy may
lack what an update fixed, the console lists each such file at start, once,
and again whenever lulibre's own file changes (`lulibre.overrides`).

After your files, lulibre looks for its own in one place only: the source
tree a build runs from, `$LULIBRE_RUNTIME`, or where `make install` put
them. Then it looks under the prefix `mod_tree` names, if any, and in
Lua's own places, as Lua and the environment (`LUA_PATH_5_5`,
`LUA_CPATH_5_5`) set them.
Nothing is looked for in the current directory. See [the Lua API](api.md).

## Where things are kept

| | |
|---|---|
| `~/.config/lulibre/` | `init.lua`, `scripts/`, `lua/`. For another directory, use `lulibre -C DIR`, `$LULIBRE_CONFIG_DIR`, or the option `config_dir` |
| `~/.local/share/lulibre/NAME-HASH.db` | the index of one library. lulibre builds it from the library and can rebuild it, except for what only lulibre knows: the undo journal, proposals, staged files' metadata, saved capture rules and file hashes |
| `~/.local/share/lulibre/NAME-HASH.history.db` `….custom.db` | beside the index, and never removed with it: the journal of changes, the snapshots, the changes that wait for the server to stop, and the custom fields |
| `~/.local/share/lulibre/backups/NAME-HASH/` | copies of calibre's database (`:backup`) |
| `~/.local/share/lulibre/overrides.json` | which of your replacing files the console has already listed |
| `~/.local/state/lulibre/calibre-server.json` | written by calibre's server while it runs through lulibre's launcher (`opf_writer = "server"`) |
| `~/.local/share/lulibre/orphans/` | stray files set aside |

lulibre honours `XDG_CONFIG_HOME` and `XDG_DATA_HOME`.

## Terminals

- **tmux.** The mouse needs `set -g mouse on`. Copies go through
  `tmux load-buffer -w`, so they land in a tmux paste buffer and, unless
  `set-clipboard` is `off`, in the terminal's clipboard. Page images are
  drawn with block characters, since tmux does not pass graphics through.
- **A terminal with the kitty graphics protocol** (ghostty, kitty), outside
  tmux: `blitter = "auto"` asks notcurses for real pixels. This is not
  tested yet; if it misbehaves, set `blitter = "sextant"`.
- **Over ssh**, outside tmux, copies use OSC 52, which the terminal must allow.
