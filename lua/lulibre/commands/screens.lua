-- The commands that open a screen or a dialog (lulibre/ui/*.lua).
-- Loaded by the prelude at startup; each is a `:` command
-- (lulibre.command), and `:help` lists them.

-- Screens and commands written in Lua. Each is loaded the first time it runs.
local function screen(module)
  return function(args) require(module).run(args) end
end
lulibre.command("edit", screen("lulibre.ui.edit"), "edit the selected books' fields, with suggestions")
lulibre.command("review", function(args)
  -- "selection": what is selected in the list (the books under a heading, the marked ones, the one under the cursor)
  if args == "selection" then args = { ids = lulibre.selection() } end
  require("lulibre.ui.review").run(args)
end, "[filter | selection]  go through proposed changes and write the accepted ones; with a filter, only those books'")
local function dialog(name)
  return function() require("lulibre.ui.dialogs")[name]() end
end
lulibre.command("enrich-dialog", dialog("enrich"),
  "a dialog for looking the selected books up: what would be asked of whom, which services to ask, then review")
lulibre.command("change", dialog("change"),
  "a dialog: one change to every selected book (add or remove a subject, set authors, series, publisher, date, language)")
lulibre.command("datasets-dialog", dialog("datasets"), "a dialog: the databases kept on this machine, with boxes for which to fetch")
lulibre.command("sync-dialog", dialog("sync"), "a dialog for the selected waiting files: add, add and remove, or drop them")
lulibre.command("propose-review", screen("lulibre.ui.proposer"),
  "a dialog: which books, what is asked (files, kept records, services), which fields, what review then shows; then propose, and review")
lulibre.command("weights", screen("lulibre.ui.weights"),
  "how much each kind of source is believed about each field: as measured against the library, or as you set it")
lulibre.command("weigh", function(args)
  -- "good": against the records confirmed as right (gk) only, which is the better measure once there are enough of them
  local ids
  if args == "good" then
    ids = require("lulibre.quality").good_ids()
    if #ids < 30 then error(("only %d records are confirmed as good: too few to measure against (gk confirms them)"):format(#ids), 0) end
  end
  local used = require("lulibre.consensus").learn(ids)
  print(("each source measured against %d books; :weights shows what came of it, the option weigh_sources uses it"):format(used))
end, "[good]  measure how often each kind of source (title page, cataloguing block, arXiv record ...) agrees with the library's own records; `good`: with the confirmed ones only")
lulibre.command("help", screen("lulibre.ui.help"),
  "[topic]  the keys under headings that open and close, with a search; with a topic, what the guides say about it (:help enrich)")
lulibre.command("beside", screen("lulibre.ui.beside"),
  "the sync folder in a column beside the library: each waiting file next to the book that is the same, or that looks like it")
lulibre.command("capture", screen("lulibre.ui.capture"),
  "[pattern]  pull fields out of file names or titles: %author% - %title%")
lulibre.command("snapshots", function() require("lulibre.ui.snapshots").run() end,
  "the snapshot browser: what going back to each would do, where the list is; go back, take, retire")
lulibre.command("dupes", screen("lulibre.ui.dupes"), "find books whose files are identical (MD5); keep one, remove the rest")
lulibre.command("terms", function(args) require("lulibre.ui.terms").run(args) end,
  "[subject]  the phrases that mark each subject, as learned: review them, drop some, add your own")
lulibre.command("orphans", screen("lulibre.ui.orphans"),
  "records with no file and files with no record: check, then clean up")
lulibre.command("browse", function(args) require("lulibre.ui.browse").run(args) end,
  "[author | subject | series | publisher | year | format | added]  the library as a tree")
lulibre.command("config", function() require("lulibre.ui.config").run() end,
  "the configuration window: every option, its value and what it does; E edits init.lua itself")
