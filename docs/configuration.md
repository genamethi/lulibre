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
| `server_stop` `server_start` | | shell commands that stop and start the content server, for the changes that wait for it to be stopped (`:offline`); empty: they wait for its next restart |
| `backup_restart` | `always` | copy calibre's database before the server starts: `always`, `next` (once), `never`, or a number of days (`:backup`) |
| `backup_keep` | `5` | copies kept |
| `backup_too_old` `backup_max_age` | `warn` `7` | offer a copy at the first change of a session when the newest is older than that many days; `false`: do not |
| `backup_metadata` | `on` | write each changed book's metadata.opf before a calibre column is added or removed |
| `index` | | index database (default under `~/.local/share/lulibre/`) |
| `pages` | `6` | first pages of each file indexed as text |
| `layout_pages` | `2` | of those, pages kept as lines tagged with font size |
| `jobs` | `0` | worker threads; 0 is one per core |
| `ocr` | `never` | `never` · `auto` · `always` |
| `ocr_pages` `ocr_lang` | `3` `eng` | pages per file the OCR pass reads; tesseract language |
| `ocr_write` | `off` | `off` · `replace` · `keep`: OCR also writes the text it read into the PDF (ocrmypdf); `keep` keeps the original in `ocr_originals` |
| `ocr_originals` | | where `ocr_write = keep` puts the originals, outside the library (default `ocr-originals/` under the data folder) |
| `text_fallback` | `auto` | `off` · `auto`: garbled pages are read again with pdftotext, when it is installed (`:run reread`) |
| `write_jobs` | `6` | `calibredb` processes at once (direct writes run one at a time) |
| `propose_over` | `sure` | `gaps` · `sure` · `any`: whether `:propose` proposes for a field that already has a value; see [Workflows](workflows.md) |
| `enrich_services` | `arxiv,crossref,zbmath,openlibrary,openalex` | the metadata services `:enrich` asks |
| `arxiv_snapshot` | | a file of arXiv's records (its snapshot from Kaggle, or a hypergraph of arXiv; `.json` or the `.zip`). Empty: `arxiv-metadata-oai-snapshot.json`, `arxiv.json` or `arxiv.zip` in the data folder is used if there (the first of them; a link will do). `:enrich` reads papers from it and asks arXiv only about those newer than the file |
| `weigh_sources` | `off` | `on`: a proposal's confidence is what its agreeing sources come to, each taken for how often it has been right in this library (`:weigh`, `:weights`) |
| `contact_email` | | an address sent to those services with each request; nothing is sent while it is empty |
| `refs_pages` | `14` | closing pages of a file read when looking for its bibliography |
| `one_word_titles` | `check` | `check` · `ok` · `junk`: whether a title of one word is a title (`check`: a plain capitalised word is) |
| `good_titles` | | titles, separated by commas, that are titles whatever they look like |
| `never_titles` | | words and phrases, separated by commas, that mark a title as not one |
| `subject_learned` | `suggest` | `off` · `suggest` · `propose`: what a subject worked out from the learned phrases is used for |
| `subject_terms` | `20` | marking phrases `:learn` keeps for each subject |
| `subject_catchall` | | subjects (or their last part), separated by commas, that file a book by form rather than topic |
| `never_authors` | | words and phrases, separated by commas, never proposed as an author (added to the built-in ranks and roles) |
| `title_case` | `auto` | `auto` · `never`: propose a title found in CAPITALS in title case |
| `math_notation` | `unicode` | `unicode` · `off`: write the mathematics in proposed titles in Unicode (SL₂(ℤ), GLₙ(ℚₚ)) |
| `sync_dir` | | folder of files waiting to be added |
| `orphans_dir` | | where stray files are set aside |
| `preview` | `text` | `text` · `image`: what the preview shows first |
| `blitter` | `auto` | `auto` · `pixel` · `sextant` · `quadrant` · `half`: how page images are drawn |
| `mouse` | `1` | clicks and the wheel |
| `review_open` | `0` | `1`: review starts with every book's other fields shown |
| `review_rows` | `field` | `field` · `all`: one row per field with the surest proposal, or one per proposal |
| `review_context` | `1` | `1`: review shows what the proposal under the cursor rests on (`i` hides it) |
| `review_reject` | `once` | `once` · `always`: whether a rejected value may be proposed again by a later run |
| `review_sort` | `evidence` | `evidence` · `confidence` · `disputed` · `id`: the order of books in review (best borne out by their pages first, surest, most disputed, by id) |
| `leader` | `\` | the key `<Leader>` stands for in key bindings |
| `log_file` | | also append the log to this file (`$LULIBRE_LOG` does the same) |
| `pixi_deps` | `off` | `on`: programs features need (pdftotext, tesseract, ocrmypdf) may come from a pixi environment lulibre keeps, and it offers to add a missing one |
| `rocks_tree` | | a luarocks tree whose modules scripts may require |
| `rocks_install` | `off` | `on`: lulibre offers to install a rock a script needs into `rocks_tree` |
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

### The password file

`password_file` names a file that holds the content server's password and
nothing else. lulibre never reads it: `calibredb` is given the file's name
and reads it itself. Keep it readable by you alone (`chmod 600`); lulibre
warns in the console when others on the machine could read it.

The password cannot be stored as a salted hash. A hash is for checking a
password someone types, and cannot be turned back into it; `calibredb` needs
the password itself to log in to the server. What protects it is the file's
permissions, and keeping the file out of anything that is copied or
committed.

### The configuration window: tab `3`

The bar along the top has a tab for it, `3 Configuration`: `3` (or `gC`,
`:config`, or a click on the tab) opens it across the screen, in place of
the list and the preview, until `1` or `2` (or a click on their tabs) goes
back to the list. It lists every option under its heading, lulibre's own
and each script's under the script's name, with its value, its default and
the line of init.lua that sets it; under it, it shows what the option
under the cursor does and what it takes.

| Key | |
|---|---|
| `Enter` `e` | give it a value: it takes effect now and is written to its line in init.lua (the file is kept as `init.lua.bak` first) |
| `d` | back to its default: the line is commented out, with the default |
| `E` | open init.lua in your editor (`$VISUAL`, `$EDITOR`, else vim or vi). lulibre steps aside until you leave it, then reads init.lua again |
| `a` | put the options init.lua does not mention in it, commented out with their defaults |
| `c` | what is written above such an option: `full` help, the `values` it takes, or `none` (`config_comments`) |
| `f` | only the options that differ from their defaults |

The first time it opens in a session it offers to put in the options init.lua
does not mention yet. `config_add_core` and `config_add_scripts` say what
happens to such options: `ask` (the offer), `auto` (put in when lulibre
starts), `never`. An option with no help gets no comment, whatever the style.

### Options of scripts

A script declares its options when it starts, under a name of its own:

```lua
local opt = lulibre.option("mytags", {
  depth = { default = 2, type = "number", help = "how many levels of subject to keep" },
  style = { default = "short", choices = "short|long" },
})
if opt.depth > 1 then ... end
```

and init.lua sets them by that name, before or after the script has run:

```lua
lulibre.cfg.mytags.depth = 3
```

What init.lua says wins over what the script itself sets (unless it sets it
with `force`), and what is changed in the session (the configuration
window, `:lua`) wins over both until lulibre closes. A value is checked
against the declared type and choices.

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

A fourth argument says what the help overlay (`?`) is to show for the key;
`false` keeps the key out of it:

```lua
lulibre.map("n", "gB", "run bib", "write the selection as BibTeX")
lulibre.map("n", "gH", function() ... end, false)
```

`<Leader>` in a key sequence is the `leader` option's key, and a panel's
name in place of the modes binds one of that panel's actions; see
[Keys](keys.md). `:reload-cfg` (`<Leader>R`) reads `init.lua` again.

Scripts in `~/.config/lulibre/scripts/NAME.lua` run with `:run NAME` or
`lulibre run NAME`; modules in `~/.config/lulibre/lua/` can be `require`d.
See [the Lua API](api.md).

## Where things are kept

| | |
|---|---|
| `~/.config/lulibre/` | `init.lua`, `scripts/`, `lua/`. Another directory: `lulibre -C DIR`, `$LULIBRE_CONFIG_DIR`, or the option `config_dir` |
| `~/.local/share/lulibre/NAME-HASH.db` | the index of one library. Derived from the library and rebuilt at will, except for what lulibre alone knows: the undo journal, proposals, staged files' metadata, saved capture rules, file hashes |
| `~/.local/share/lulibre/NAME-HASH.history.db` `….custom.db` | beside the index, and never dropped with it: the journal of changes, snapshots and the changes that wait for the server to be stopped; the custom fields |
| `~/.local/share/lulibre/backups/NAME-HASH/` | copies of calibre's database (`:backup`) |
| `~/.local/state/lulibre/calibre-server.json` | written by calibre's server while it runs through lulibre's launcher (`lulibre server-unit`) |
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
