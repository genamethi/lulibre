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

-- Screens and commands written in Lua. Each is loaded the first time it runs.
local function screen(module)
  return function(args) require(module).run(args) end
end
lulibre.command("edit", screen("lulibre.ui.edit"), "edit the selected books' fields, with suggestions")
lulibre.command("review", screen("lulibre.ui.review"), "go through proposed changes and write the accepted ones")
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
lulibre.command("ocr", script("ocr"), "[filter | all]  read text from page images with tesseract")
lulibre.command("enrich", script("enrich"), "[filter]  look the selection up on arXiv and CrossRef; proposes")
lulibre.command("onboard", script("onboard"), "DIR  add the ebook files under a directory to calibre, with metadata")
lulibre.command("propose", script("propose"), "[filter]  propose metadata from the files, for :review")
lulibre.command("dupes", screen("lulibre.ui.dupes"), "find books whose files are identical (MD5); keep one, remove the rest")
lulibre.command("sync", script("sync"),
  "[add | move | drop] [filter]  the sync folder: show it; add the selection; add and delete; drop without adding")
lulibre.command("orphans", screen("lulibre.ui.orphans"),
  "records with no file and files with no record: check, then clean up")
lulibre.command("browse", function(args) require("lulibre.ui.browse").run(args) end,
  "[author | subject | series | publisher | year | format | added]  the library as a tree")

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
end, "remove the selected books from calibre (to its recycle bin; u puts them back)")

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
