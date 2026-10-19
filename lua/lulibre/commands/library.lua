-- The commands that look at or change the library itself.
-- Loaded by the prelude at startup; each is a `:` command
-- (lulibre.command), and `:help` lists them.

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
    local opf = require("lulibre.calibre").opf()
    out[#out + 1] = ("the books' metadata.opf files: %s%s"):format(opf.why,
      opf.behind and (";  %d behind their record now"):format(opf.behind) or "")
    lulibre.show(out, "copies of calibre's database")
  end
end, "[now [why] | always | next | never | DAYS | prune [keep]]  copies of calibre's database: list, make one, when to make them")
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
