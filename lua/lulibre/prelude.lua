-- The part of the lulibre API that is written in Lua. Loaded once at startup.

--- A readable rendering of any value, for :lua and for debugging.
function lulibre.inspect(v, indent, seen)
  indent, seen = indent or "", seen or {}
  if type(v) == "string" then return string.format("%q", v) end
  if type(v) ~= "table" then return tostring(v) end
  if seen[v] then return "<cycle>" end
  seen[v] = true
  local keys = {}
  for k in pairs(v) do keys[#keys + 1] = k end
  if #keys == 0 then return "{}" end
  table.sort(keys, function(a, b)
    if type(a) == type(b) and (type(a) == "number" or type(a) == "string") then return a < b end
    return type(a) == "number" or (type(b) ~= "number" and tostring(a) < tostring(b))
  end)
  local inner, parts = indent .. "  ", {}
  local list = #keys == #v -- a plain sequence prints without its indexes
  for _, k in ipairs(keys) do
    local key = list and "" or (type(k) == "string" and k:match("^[%a_][%w_]*$") and k
      or "[" .. lulibre.inspect(k, inner, seen) .. "]") .. " = "
    parts[#parts + 1] = inner .. key .. lulibre.inspect(v[k], inner, seen)
  end
  seen[v] = nil
  local flat = table.concat(parts, ","):gsub("%s+", " ")
  if #flat < 72 and not flat:find("\n") then return "{" .. flat .. " }" end
  return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
end

--- :lua runs this: evaluate as an expression if possible, else as statements.
function lulibre._eval(code)
  local f, err = load("return " .. code, "=:lua")
  if not f then f, err = load(code, "=:lua") end
  if not f then error(err, 0) end
  local r = table.pack(f())
  if r.n == 0 then return end
  local out = {}
  for i = 1, r.n do out[i] = lulibre.inspect(r[i]) end
  local text = table.concat(out, "\n")
  if text:find("\n") and not lulibre.headless then lulibre.show(text, ":lua " .. code)
  else print(text) end
end

--- Ask a yes/no question on the bottom line. Waits; true only for y or yes.
function lulibre.confirm(question)
  local a = lulibre.input({ prompt = question .. " [y/N] " })
  return a ~= nil and (a:lower() == "y" or a:lower() == "yes")
end

--- Whether to do something lulibre may do on its own, as the option of that
-- name says: "auto" yes, "never" no, "ask" puts the question (and means no
-- where there is nobody to ask).
function lulibre.policy(name, question)
  local v = lulibre.o[name]
  if v == "auto" then return true end
  if v == "ask" and not lulibre.headless and lulibre.task_id() then return lulibre.confirm(question) end
  return false
end

--- Set several options at once: lulibre.setup{ pages = 8, ocr = "auto" }.
function lulibre.setup(opts)
  for k, v in pairs(opts) do lulibre.o[k] = v end
end

--- Run fn(item, index) over a list with several tasks at once, and wait for
-- all of it. opts.jobs: how many at a time (default: one per CPU);
-- opts.progress: a word for the status line ("hashing" shows "hashing 12/300").
-- An error in fn stops the rest and is raised here.
--
-- Tasks take turns, and a turn can end between any two Lua operations, so
-- fn must not count in a shared variable (`n = n + 1` can lose a count).
-- Put results on the item, or use table.insert, which cannot be interrupted.
function lulibre.each(items, fn, opts)
  opts = opts or {}
  local total = #items
  if total == 0 then return end
  local jobs = opts.jobs
  if not jobs then
    local ok, uv = pcall(require, "luv")
    jobs = ok and uv.available_parallelism and uv.available_parallelism() or 4
  end
  jobs = math.max(1, math.min(jobs, total))
  local queue, done, finished, errors = {}, {}, {}, {}
  for i = total, 1, -1 do queue[#queue + 1] = i end
  local function worker()
    local ok, err = pcall(function()
      while #errors == 0 do
        local i = table.remove(queue)
        if not i then break end
        fn(items[i], i)
        table.insert(done, true)
        if opts.progress then lulibre.progress(("%s %d/%d"):format(opts.progress, #done, total)) end
      end
    end)
    if not ok then table.insert(errors, err) end
    table.insert(finished, true)
  end
  if opts.progress then lulibre.progress(("%s 0/%d"):format(opts.progress, total)) end
  for _ = 1, jobs do lulibre.spawn(worker) end
  while #finished < jobs do lulibre.sleep(10) end
  if opts.progress then lulibre.progress(nil) end
  if errors[1] then error(errors[1], 0) end
end

--- For a message that names a key: the key a command line is bound to now,
-- or ":command" when it has none.
function lulibre.hint(command)
  return lulibre.key(command) or (":" .. command)
end

-- Keys. lulibre.map binds a global key; given the name of a screen written
-- in Lua instead of modes, it puts a key on one of that screen's actions:
--   lulibre.map("nv", "gx", "run mine")       a command line or a function
--   lulibre.map("review", "y", "accept")      see lulibre.ui.keys
do
  local map = lulibre.map
  function lulibre.map(modes, key, target, help)
    local screens = require "lulibre.ui.keys"
    if type(modes) == "string" and screens.has(modes) then return screens.set(modes, key, target) end
    -- or of a place with keys of its own: "panel", "line", "picker", "pager", "console"
    if type(modes) == "string" and #modes > 2 and lulibre._place_map(modes, key, target or "") then return end
    return map(modes, key, target, help)
  end
end

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

lulibre.command("undo", function(args)
  local edit = require "lulibre.edit"
  local r, err = edit.undo(tonumber(args))
  if not r then
    lulibre.notify(err, "error")
    return
  end
  local note = r.skipped > 0 and ("; %d left alone because they changed again since"):format(r.skipped) or ""
  if #r.failed > 0 then note = note .. "; " .. tostring(r.failed[1].error) end
  if r.restored and #r.restored > 0 then
    local staged = r.restored[1] < 0
    note = note .. (staged and "; %d dropped file%s back in the sync folder"
      or "; %d removed book%s restored from calibre's recycle bin"):format(#r.restored, #r.restored == 1 and "" or "s")
    if not staged then
      for _, id in ipairs(r.restored) do pcall(lulibre.mark, id, true) end
    end
  end
  lulibre.notify(("undid batch %d: %d book%s put back%s"):format(r.undid, r.applied, r.applied == 1 and "" or "s", note),
    #r.failed > 0 and "error" or nil)
end, "[batch]  put back what the last change (or a given batch) did")

lulibre.command("history", function()
  local edit = require "lulibre.edit"
  local out = {}
  for _, h in ipairs(edit.history(200)) do
    out[#out + 1] = ("%5d  %s  %4d book%s  %-28s %s%s"):format(h.batch, os.date("%Y-%m-%d %H:%M", h.ts), h.books,
      h.books == 1 and " " or "s", h.label or "", h.undone == 1 and "undone" or "",
      (h.failed or 0) > 0 and ("  %d failed"):format(h.failed) or "")
  end
  if #out == 0 then out[1] = "no changes have been made through lulibre yet" end
  lulibre.show(out, "history   (:undo N puts a batch back)")
end, "changes made through lulibre, newest first")

--- Propose a change for later review; see lulibre.proposals.
function lulibre.propose(id, field, value, opts)
  return require("lulibre.proposals").add(id, field, value, opts)
end

--- Apply changes now: lulibre.apply{ {id=, field=, value=, op=}, ... }. Waits.
function lulibre.apply(changes, opts)
  return require("lulibre.edit").apply(changes, opts)
end

local function script(name)
  return function(args) lulibre.exec("run " .. name .. (args ~= "" and " " .. args or "")) end
end
lulibre.command("bib", script("bib"), "[file]  write the selected books as BibTeX")
lulibre.command("verify", script("verify"),
  "[--list title|authors|ids|unread] [filter]  the library held against its files: titles, authors and identifiers the pages bear out")
lulibre.command("backup", function(args)
  local backup = require "lulibre.backup"
  local verb, rest = (args or ""):match("^%s*(%S*)%s*(.-)%s*$")
  if verb == "now" then
    local ok, b = pcall(backup.take, rest ~= "" and rest or "asked for")
    lulibre.notify(ok and ("calibre's database copied to %s"):format(b.path) or tostring(b), not ok and "error" or nil)
  elseif verb == "prune" then
    lulibre.notify(("%d copies removed"):format(backup.prune(tonumber(rest))))
  elseif verb ~= "" then
    local ok, err = pcall(backup.set, tonumber(verb) or verb)
    lulibre.notify(ok and ("backup_restart = %s"):format(verb) or tostring(err), not ok and "error" or nil)
  else
    local out = {}
    for _, b in ipairs(backup.list()) do
      out[#out + 1] = ("%s  %5s books  %s"):format(os.date("%Y-%m-%d %H:%M", b.ts), tostring(b.books or "?"), b.reason or "")
    end
    if #out == 0 then out[1] = "no copies of calibre's database yet (:backup now makes one)" end
    out[#out + 1] = ""
    out[#out + 1] = ("before the server starts: %s%s;  kept: %d;  too old after %d days (%s)"):format(
      tostring(lulibre.o.backup_restart), backup.policy() == "next" and (backup.due() and ", not yet spent" or ", spent") or "",
      lulibre.o.backup_keep, lulibre.o.backup_max_age, tostring(lulibre.o.backup_too_old))
    out[#out + 1] = ("in %s"):format(backup.dir())
    lulibre.show(out, "copies of calibre's database")
  end
end, "[now [why] | always | next | never | DAYS | prune [keep]]  copies of calibre's database: list, make one, when to make them")
lulibre.command("offline", script("offline"),
  "[restart | cancel ID]  the changes calibre makes only while the content server is stopped: what waits; restart the server for them now")
lulibre.command("snapshot", script("snapshot"),
  "[NAME] | list | plan SNAP | rollback SNAP [--exact --unsync --fields] | retire SNAP | import FILE  points the library can be put back to")
lulibre.command("snapshots", function() require("lulibre.ui.snapshots").run() end,
  "the snapshot browser: what going back to each would do, where the list is; go back, take, retire")
lulibre.command("rollback", function(args) lulibre.exec("run snapshot rollback " .. (args or "")) end,
  "SNAP [--exact --unsync --fields]  put the library back to a snapshot (shows what it will do, then asks)")
lulibre.command("ocr", script("ocr"), "[filter | all]  read text from page images with tesseract")
lulibre.command("enrich", script("enrich"),
  "[--offline] [--titles] [filter]  look books up by their identifiers (arXiv, CrossRef, zbMATH, Open Library); proposes")
lulibre.command("onboard", script("onboard"), "DIR  add the ebook files under a directory to calibre, with metadata")
lulibre.command("addpages", function(args)
  -- read a file as far as a page: "addpages BOOK PAGE" (the preview's key for it gives both)
  local id, page = args:match("^(%-?%d+)%s+(%d+)$")
  if not id then error("addpages BOOK PAGE", 0) end
  lulibre.progress(("reading book %s as far as page %s"):format(id, page))
  local r, err = lulibre.index { filter = (tonumber(id) < 0 and "in:sync " or "") .. "id:" .. math.abs(tonumber(id)), pages = tonumber(page), force = true }
  lulibre.progress(nil)
  if not r then error(err, 0) end
  lulibre.exec("reload")
  print(r.failed > 0 and "the file could not be read" or ("read as far as page %s"):format(page))
end, "BOOK PAGE  read a file as far as that page (the preview's `a` does it for the page being shown)")
lulibre.command("datasets", script("datasets"),
  "[list | fetch NAME... | add FILE...]  databases for looking books up offline (arXiv, Open Library, zbMATH): pick one to fetch")
lulibre.command("arxiv-fetch", script("arxiv-fetch"),
  "[--force]  fetch arXiv's snapshot of its records from Kaggle (through pixi), for :enrich to read instead of asking arXiv")
lulibre.command("refs", script("refs"), "[--force] [filter | all]  read what the books cite, from the bibliography at the end of each file")
lulibre.command("propose", script("propose"), "[filter]  propose metadata from the files, for :review")
lulibre.command("notation", script("notation"),
  "[filter]  propose titles with their mathematics in Unicode (SL₂(ℤ), GLₙ(ℚₚ)), read from the title page where it has them")
lulibre.command("dupes", screen("lulibre.ui.dupes"), "find books whose files are identical (MD5); keep one, remove the rest")
lulibre.command("sync", script("sync"),
  "[add | move | drop] [filter]  the sync folder: show it; add the selection; add and delete; drop without adding")
lulibre.command("good", function(args)
  local quality = require "lulibre.quality"
  if args == "add" or args == "remove" then
    local ids = lulibre.selection()
    quality.set_good(ids, args == "add")
    lulibre.notify(("%s %d record%s %s known good"):format(args == "add" and "confirmed" or "took", #ids,
      #ids == 1 and "" or "s", args == "add" and "as" or "out of the"))
  else
    require("lulibre.ui.good").run()
  end
end, "[add | remove]  the records by how complete they look, to confirm the right ones; add and remove act on the selection")
lulibre.command("noncatalog", function(args)
  local noncatalog = require "lulibre.noncatalog"
  if args == "add" or args == "remove" then
    local ids = lulibre.selection()
    local did = noncatalog.set(ids, args == "add")
    local more = {}
    if did.withdrawn > 0 then more[#more + 1] = ("%d waiting proposal%s withdrawn"):format(did.withdrawn, did.withdrawn == 1 and "" or "s") end
    if did.removals > 0 then
      more[#more + 1] = ("taking off %d identifier%s proposed (%s)"):format(did.removals, did.removals == 1 and "" or "s", lulibre.hint("review"))
    end
    lulibre.notify(("%s %d book%s %s non-catalog%s"):format(args == "add" and "marked" or "took", #ids, #ids == 1 and "" or "s",
      args == "add" and "as" or "out of the", #more > 0 and ": " .. table.concat(more, ", ") or ""))
  elseif args == "" or args == nil then
    lulibre.filter("is:noncatalog")
  else
    lulibre.notify("noncatalog takes add, remove, or nothing (to list them)", "error")
  end
end, "[add | remove]  works no catalogue has a record of (handouts, course notes): no DOI or ISBN is looked for; add and remove act on the selection")
lulibre.command("learn", function()
  local st, why = require("lulibre.learn").run()
  if not st then
    lulibre.notify(why, "error")
  else
    lulibre.notify(("learned %d phrases for %d subjects from %d confirmed books (%d read) in %ds; :terms shows them"):format(
      st.terms, st.subjects, st.books, st.read, st.seconds))
  end
end, "learn the phrases that mark each subject, from the records confirmed as good (:good)")
lulibre.command("terms", function(args) require("lulibre.ui.terms").run(args) end,
  "[subject]  the phrases that mark each subject, as learned: review them, drop some, add your own")
lulibre.command("orphans", screen("lulibre.ui.orphans"),
  "records with no file and files with no record: check, then clean up")
lulibre.command("browse", function(args) require("lulibre.ui.browse").run(args) end,
  "[author | subject | series | publisher | year | format | added]  the library as a tree")

--- A title in title case (APA style); see lulibre.titlecase.
function lulibre.titlecase(s)
  return require("lulibre.titlecase").apply(s)
end

lulibre.command("titlecase", function(args)
  local tc, edit = require "lulibre.titlecase", require "lulibre.edit"
  local every = args == "all"
  local changes, skipped = {}, 0
  for _, id in ipairs(lulibre.selection()) do
    local book = lulibre.book(id)
    local title = book and book.title or ""
    if every or tc.is_caps(title) then
      local to = tc.apply(title)
      if to ~= title then changes[#changes + 1] = { id = id, field = "title", value = to } end
    elseif title ~= "" then
      skipped = skipped + 1
    end
  end
  if #changes == 0 then
    lulibre.notify(skipped > 0
      and ("%s not in capitals; :titlecase all applies the style to any title"):format(
        skipped == 1 and "the title is" or skipped .. " titles are")
      or "nothing to change: the titles are in title case already")
    return
  end
  local r = edit.apply(changes, { label = "title case" })
  lulibre.notify(edit.summary(r), #r.failed > 0 and "error" or nil)
end, "[all]  put the selected books' titles in title case: those in CAPITALS, or with all, every one")

lulibre.command("clear", function(args)
  local propose, edit = require "lulibre.propose", require "lulibre.edit"
  local words = {}
  for w in args:gmatch("%S+") do words[#words + 1] = w end
  local set, bad = propose.fields(words[1] or "")
  if not set or not next(set) then
    lulibre.notify(("clear which field? title authors subject ids date publisher (or t a s i d p)%s"):format(
      bad and ", not '" .. bad .. "'" or ""), "error")
    return
  end
  local filter = table.concat(words, " ", 2)
  local ids = filter ~= "" and lulibre.ids(filter) or lulibre.selection()
  local changes, names = {}, {}
  for field in pairs(set) do names[#names + 1] = field end
  table.sort(names)
  for _, id in ipairs(ids) do
    local book = lulibre.book(id)
    for _, field in ipairs(names) do
      if book and edit.current(book, field) ~= "" then changes[#changes + 1] = { id = id, field = field, value = "" } end
    end
  end
  if #changes == 0 then
    lulibre.notify("those fields are empty already")
    return
  end
  if not lulibre.confirm(("blank %s in %d book%s? (%s puts it back)"):format(table.concat(names, " and "), #ids,
      #ids == 1 and "" or "s", lulibre.hint("undo"))) then
    return
  end
  local r = edit.apply(changes, { label = "clear " .. table.concat(names, ",") })
  lulibre.notify(edit.summary(r), #r.failed > 0 and "error" or nil)
end, "FIELDS [filter]  blank fields (title authors subject ids date publisher, or t a s i d p) in the selection or the books a filter matches")

lulibre.command("junk", function(args)
  local propose, edit = require "lulibre.propose", require "lulibre.edit"
  local ids = args ~= "" and lulibre.ids(args) or lulibre.ids("in:library")
  lulibre.exec("mark none")
  local n = 0
  for _, id in ipairs(ids) do
    local book = lulibre.book(id)
    if book and (propose.is_gap("title", edit.current(book, "title"), id)
        or (edit.current(book, "authors") ~= "" and propose.is_gap("authors", edit.current(book, "authors"), id))) then
      lulibre.mark(id, true)
      n = n + 1
    end
  end
  if n == 0 then
    lulibre.notify("no title or author here looks like junk")
  else
    lulibre.filter("is:marked")
    lulibre.notify(("marked %d books whose title or author is not one (a file name, a number, a program's name); :propose proposes for them"):format(n))
  end
end, "[filter]  mark and list the books whose title or author is plainly not one")

lulibre.command("remove", function()
  local ids = lulibre.selection()
  if #ids == 0 then return end
  local what = #ids == 1 and ("book %d, %s,"):format(ids[1], (lulibre.book(ids[1]) or {}).title or "?")
    or ("%d books"):format(#ids)
  if not lulibre.confirm(("remove %s from calibre? (to its recycle bin)"):format(what)) then return end
  local n, err = require("lulibre.edit").remove(ids)
  for _, id in ipairs(ids) do lulibre.mark(id, false) end
  lulibre.notify(err and ("removed %d, then: %s"):format(n, err) or ("removed %d book%s"):format(n, n == 1 and "" or "s"),
    err and "error" or nil)
end, "remove the selected books from calibre (to its recycle bin; :undo puts them back)")

lulibre.command("yank", function(what)
  local ids = lulibre.selection()
  local text
  if what == "bib" then
    text = require("lulibre.bib").export(ids)
  elseif what == "key" then
    local _, keys = require("lulibre.bib").export(ids)
    text = table.concat(keys, ",")
  elseif what == "path" then
    local paths = {}
    for _, id in ipairs(ids) do
      local f = lulibre.files(id)[1]
      if f then paths[#paths + 1] = f.path end
    end
    text = table.concat(paths, "\n")
  else
    local titles = {}
    for i, id in ipairs(ids) do titles[i] = lulibre.book(id).title or "" end
    text = table.concat(titles, "\n")
  end
  if lulibre.clipboard(text) then
    lulibre.notify(("copied %s for %d book%s"):format(what == "" and "title" or what, #ids, #ids == 1 and "" or "s"))
  else
    lulibre.notify("could not reach the terminal to copy", "error")
  end
end, "bib | key | path | title  copy for the selection to the clipboard")

lulibre.command("embed", function()
  local ids = lulibre.selection()
  if #ids == 0 then return end
  if not lulibre.confirm(("write calibre's metadata into the files of %d book%s? this rewrites the files"):format(
      #ids, #ids == 1 and "" or "s")) then
    return
  end
  local args = require("lulibre.edit").calibredb()
  args[#args + 1] = "embed_metadata"
  for _, id in ipairs(ids) do args[#args + 1] = tostring(id) end
  lulibre.progress("embedding…")
  local r, err = lulibre.system(args, { timeout = 600000 })
  lulibre.progress(nil)
  if r and r.code == 0 then lulibre.notify(("metadata embedded in %d book%s"):format(#ids, #ids == 1 and "" or "s"))
  else lulibre.notify(r and (r.stderr ~= "" and r.stderr or r.stdout) or err, "error") end
end, "write calibre's metadata into the selected books' own files (PDF, EPUB)")

-- ---- options of scripts, and the configuration file ----

--- lulibre.option(namespace, { name = { default=, type=, choices=, help= }, ... }):
-- declare a script's options; returns the namespace to read them from. See
-- lulibre.options.
function lulibre.option(ns, defs)
  return require("lulibre.options").option(ns, defs)
end

--- lulibre.cfg.<namespace>.<name>: a script's option, read or set (in
-- init.lua: lulibre.cfg.mytags.depth = 3).
lulibre.cfg = require("lulibre.options").cfg

-- C modules. One built for another Lua (compiled against another version's
-- lua.h, which a stray header earlier on the include path makes easy) can
-- crash the program the moment it is loaded, with nothing to say why. So
-- each is loaded first in a child process (this program, `run` on a probe),
-- once for each file and its date, and one that does not survive that is
-- refused with the reason. The answers are kept in cmodules.cache in the data
-- folder.
local probe_cache
local function cache_file() return lulibre.settings.paths().data_dir .. "/cmodules.cache" end
local function load_cache()
  if probe_cache then return probe_cache end
  local cache = {} -- built whole, then put in place (a task may be interrupted)
  local f = io.open(cache_file(), "r")
  if f then
    for line in f:lines() do
      local verdict, stamp, path = line:match("^(%a+) (%d+) (.+)$")
      if path then cache[path] = { verdict = verdict, stamp = stamp } end
    end
    f:close()
  end
  probe_cache = cache
  return cache
end
local function shq(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
local function c_module_ok(name, file)
  if name == "luv" then return true end -- lulibre's own, checked when it is built
  local ok, uv = pcall(require, "luv")
  if not ok then return true end -- cannot tell; load it as Lua would
  local st = uv.fs_stat(file)
  local stamp = tostring(st and st.mtime and st.mtime.sec or 0)
  local cache = load_cache()
  local known = cache[file]
  if known and known.stamp == stamp then return known.verdict == "ok" end
  local dir = lulibre.settings.paths().data_dir
  local probe = dir .. "/cprobe.lua"
  if not uv.fs_stat(probe) then
    os.execute("mkdir -p " .. shq(dir))
    local f = io.open(probe, "w")
    if f then
      f:write('local name, path = ...\nlocal open = assert(package.loadlib(path, "luaopen_" .. name:gsub("%.", "_")))\nopen(name, path)\n')
      f:close()
    end
  end
  local exe = uv.exepath()
  local good = exe and os.execute(("%s --clean run %s %s %s >/dev/null 2>&1"):format(shq(exe), shq(probe), shq(name), shq(file))) == true
  cache[file] = { verdict = good and "ok" or "bad", stamp = stamp }
  local f = io.open(cache_file(), "a")
  if f then
    f:write(("%s %s %s\n"):format(good and "ok" or "bad", stamp, file))
    f:close()
  end
  return good
end
local function refused(name, file)
  return ("\n\tthe C module %s at %s crashes when it is loaded: it was built for another Lua than this %s"
    .. " (rebuild it against this version's headers; `luarocks install` takes LUA_INCDIR=...)"):format(name, file, _VERSION)
end
-- the C searchers (a module's own file, and the one its root is in) go through the probe
local std_c, std_croot = package.searchers[3], package.searchers[4]
package.searchers[3] = function(name)
  local file = package.searchpath(name, package.cpath)
  if file and not c_module_ok(name, file) then return refused(name, file) end
  return std_c(name)
end
package.searchers[4] = function(name)
  local root = name:match("^([^%.]+)%.")
  local file = root and package.searchpath(root, package.cpath)
  if file and not c_module_ok(name, file) then return refused(name, file) end
  return std_croot(name)
end

-- Modules of a luarocks tree (the option rocks_tree): looked for before the
-- usual places, since it is the tree you named.
local function rocks_paths(tree)
  local v = _VERSION:match("%d+%.%d+")
  return ("%s/share/lua/%s/?.lua;%s/share/lua/%s/?/init.lua"):format(tree, v, tree, v), ("%s/lib/lua/%s/?.so"):format(tree, v)
end
table.insert(package.searchers, 2, function(name)
  local tree = lulibre.o.rocks_tree or ""
  if tree == "" then return nil end
  local lpath, cpath = rocks_paths(tree)
  local file = package.searchpath(name, lpath)
  if file then return loadfile(file), file end
  file = package.searchpath(name, cpath)
  if file then
    if not c_module_ok(name, file) then return refused(name, file) end
    local sym = "luaopen_" .. name:gsub("%.", "_")
    local f, err = package.loadlib(file, sym)
    if not f then return err end
    return f, file
  end
  return ("\n\tno module '%s' in the luarocks tree %s"):format(name, tree)
end)

--- require a module, offering (when the option rocks_install is on, and
-- someone can be asked) to install the rock that has it into rocks_tree.
-- rock: the rock's name when it is not the module's.
function lulibre.require_rock(module, rock)
  local ok, m = pcall(require, module)
  if ok then return m end
  local tree = lulibre.o.rocks_tree or ""
  if lulibre.o.rocks_install ~= "on" or tree == "" then
    error(("the Lua module %s is not installed (luarocks install %s%s)"):format(module, rock or module,
      tree ~= "" and (" --tree " .. tree) or ""), 2)
  end
  if lulibre.headless or not lulibre.task_id() or
      not lulibre.confirm(("install the rock %s into %s? luarocks fetches it from luarocks.org"):format(rock or module, tree)) then
    error(("the Lua module %s is not installed"):format(module), 2)
  end
  lulibre.progress("luarocks: " .. (rock or module))
  local r, err = lulibre.system({ "luarocks", "--lua-version", _VERSION:match("%d+%.%d+"), "--tree", tree, "install", rock or module },
    { timeout = 900000 })
  lulibre.progress(nil)
  if not r or r.code ~= 0 then error("luarocks could not install " .. (rock or module) .. ": " .. tostring(err or (r and r.stderr)), 2) end
  return require(module)
end

-- around init.lua (read at start, and again by :reload-cfg)
function lulibre._before_init()
  require("lulibre.options").forget_file()
end
function lulibre._after_init()
  -- options nobody has put in init.lua yet go in on their own when the options say "auto"
  local add_core, add_scripts = lulibre.o.config_add_core == "auto", lulibre.o.config_add_scripts == "auto"
  if (add_core or add_scripts) and lulibre.settings.paths().init then
    local cf = require "lulibre.config_file"
    local ok, missing = pcall(cf.missing)
    if ok then
      local items = {}
      if add_core then for _, n in ipairs(missing.core) do items[#items + 1] = { name = n } end end
      if add_scripts then for _, it in ipairs(missing.scripts) do items[#items + 1] = it end end
      if #items > 0 then pcall(cf.add, items) end
    end
  end
end

lulibre.command("config", function() require("lulibre.ui.config").run() end,
  "the configuration window: every option, its value and what it does; E edits init.lua itself")
lulibre.command("features", function()
  local features = require "lulibre.features"
  local out = {}
  for _, f in ipairs(features.list) do
    local st = features.status(f)
    out[#out + 1] = ("%-10s %-9s %-4s %s"):format(f.name, st.here and "installed" or "missing", st.enabled and "on" or "off",
      f.used_for)
    if not st.here then out[#out + 1] = "             " .. features.how(f) end
  end
  lulibre.show(out, "features and the programs they need")
end, "the features that need programs of their own (poppler, tesseract, ocrmypdf): installed or not, on or off")

lulibre.command("parts", function()
  local parts = require "lulibre.parts"
  local out = {}
  for _, w in ipairs(parts.wholes()) do
    out[#out + 1] = ("%s   %d here%s%s"):format(w.whole, #w.books, w.parts and (" of " .. w.parts) or "",
      #w.missing > 0 and ("; missing " .. table.concat(w.missing, " ", 1, math.min(#w.missing, 30)) .. (#w.missing > 30 and " ..." or "")) or "")
    for _, b in ipairs(w.books) do
      local book = lulibre.book(b.id)
      out[#out + 1] = ("   %4s  %6d  %s"):format(b.part and tostring(b.part) or "?", b.id, book and book.title or "")
    end
  end
  if #out == 0 then out[1] = "no book is known to be part of a whole yet (:run grammars --apply finds them)" end
  lulibre.show(out, "wholes and their parts, in order")
end, "the books that are parts of a whole (handbook chapters, the Stacks project), in order, with what is missing")

lulibre.command("custom", function(args)
  local custom = require "lulibre.custom"
  local verb, rest = (args or ""):match("^%s*(%S*)%s*(.-)%s*$")
  if verb == "add" then
    local name, kind, help = rest:match("^(%S+)%s*(%S*)%s*(.-)$")
    if not name then return lulibre.notify(":custom add NAME [text|number|date|list] [what it is]", "error") end
    if kind ~= "" and not custom.TYPES[kind] then help, kind = (kind .. " " .. help):gsub("%s+$", ""), "text" end
    local ok, err = pcall(custom.declare, name, { type = kind ~= "" and kind or "text", help = help ~= "" and help or nil })
    lulibre.notify(ok and ("custom field %s (%s)"):format(err, kind ~= "" and kind or "text") or tostring(err), not ok and "error" or nil)
  elseif verb == "set" then
    local name, value = rest:match("^(%S+)%s*(.-)$")
    if not name then return lulibre.notify(":custom set NAME VALUE (for the selection; an empty value removes it)", "error") end
    local changes = {}
    for _, id in ipairs(lulibre.selection()) do changes[#changes + 1] = { id = id, field = custom.norm(name), value = value } end
    local r = require("lulibre.edit").apply(changes, { label = "custom" })
    lulibre.notify(require("lulibre.edit").summary(r), #r.failed > 0 and "error" or nil)
  elseif verb == "column" then
    local how, name, heading = rest:match("^(%S*)%s*(%S*)%s*(.-)$")
    if (how ~= "add" and how ~= "remove") or name == "" then
      return lulibre.notify(":custom column add NAME [heading]  |  :custom column remove NAME", "error")
    end
    local id, err
    if how == "add" then
      id, err = custom.add_column(name, { heading = heading ~= "" and heading or nil })
    else
      local n = custom.column(name) and custom.calibre_books(name) or 0
      local mine = custom.field(name) and "lulibre keeps its own values" or "they are calibre's only"
      if n > 0 and not lulibre.confirm(("remove calibre's column %s? %d book%s lose their value in calibre (%s)"):format(
          custom.norm(name), n, n == 1 and "" or "s", mine)) then
        return
      end
      id, err = custom.remove_column(name)
      if err == "cancelled" then return lulibre.notify(("the column %s will not be added after all"):format(custom.norm(name))) end
    end
    if not id then return lulibre.notify(err, "error") end
    require("lulibre.offline").ask()
  elseif verb == "push" then
    if rest == "" then return lulibre.notify(":custom push NAME  (copy lulibre's values into calibre's column)", "error") end
    local ok, r = pcall(custom.push, rest)
    if not ok then return lulibre.notify(tostring(r), "error") end
    lulibre.notify(("%d book%s copied into calibre's %s%s"):format(r.copied, r.copied == 1 and "" or "s", custom.norm(rest),
      #r.failed > 0 and ("; %d failed: %s"):format(#r.failed, r.failed[1].error) or ""), #r.failed > 0 and "error" or nil)
  else
    local out = {}
    for _, f in ipairs(custom.fields()) do
      local st = custom.state(f.name)
      local where = st.state == "lulibre" and "lulibre only" or st.state == "waiting" and "waits for a restart"
        or st.removing and "removal waits" or st.differ > 0 and ("calibre: %d differ"):format(st.differ) or "calibre too"
      out[#out + 1] = ("%-14s %-7s %5d book%s  %-19s %s%s"):format(f.name, f.type, f.books, f.books == 1 and " " or "s", where,
        f.help or "", f.undeclared and "(not declared)" or "")
    end
    out[#out + 1] = ""
    out[#out + 1] = "filter by them: #partof:handbook  #part:none  has:#partof; :custom add NAME TYPE HELP; :custom set NAME VALUE"
    out[#out + 1] = "in calibre too: :custom column add NAME [heading]; :custom column remove NAME (made while the server is stopped); :custom push NAME"
    lulibre.show(out, "custom fields (kept beside calibre's, in lulibre's own database)")
  end
end, "[add NAME [type] [help] | set NAME VALUE | column add|remove NAME [heading] | push NAME]  fields of your own beside calibre's (#partof ...): list, declare, set for the selection, put in calibre")

-- backup_restart's "next" is spent until it is set to next again: note the
-- value lulibre starts with (lulibre.backup), once the library is open
-- (only with a library to open: looking would otherwise end lulibre. Asked
-- in the task, once -L and init.lua have had their say)
lulibre.spawn(function()
  local here = io.open("metadata.db")
  if here then here:close() end
  if lulibre.o.library ~= "" or os.getenv("LULIBRE_LIBRARY") or here then pcall(require("lulibre.backup").observe) end
end)
