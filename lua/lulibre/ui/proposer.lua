--- Proposes and then reviews, from one dialog. The dialog sets which books,
-- what to consult (the files, the stored records, the services, the
-- bibliographies), which fields, how existing values are treated, and what
-- review then shows. :propose, :enrich, :refs and :review with their flags
-- can do all of this by hand; the dialog puts it in one place and in order.
--
-- The dialog starts a run (lulibre.runs). The status line shows the run
-- while it goes on, the steps keep their closing lines to themselves, and
-- when the run is done its proposals open in review as a view of their own.
--
-- @screens lulibre.ui.proposer
-- @usage
-- require("lulibre.ui.proposer").run()   -- as :propose-review does
local form = require "lulibre.ui.form"
local proposals = require "lulibre.proposals"
local runs = require "lulibre.runs"

local M = {}

local FIELDS = { { "title", "title", "t" }, { "authors", "authors", "a" }, { "tags", "subject", "s" }, { "pubdate", "date", "d" },
  { "publisher", "publisher", "p" }, { "series", "series", "e" }, { "identifiers", "identifiers", "i" } }

-- Run one of the scripts (the user's own of that name first) and wait for
-- it. What it prints is kept back: its closing line ("12 proposals; gr goes
-- through them") speaks for one step, and said in the middle of a run it
-- sends you to review before the run is done.
local function script(name, ...)
  local paths = lulibre.settings.paths()
  local src = debug.getinfo(1, "S").source:gsub("^@", "")
  local root = src:match("^(.*)/lua/lulibre/ui/proposer%.lua$")
  local chunk
  for _, path in ipairs { (paths.scripts or "") .. "/" .. name .. ".lua", (root or ".") .. "/scripts/" .. name .. ".lua" } do
    chunk = chunk or loadfile(path)
  end
  if not chunk then error(("the script '%s' was not found"):format(name), 0) end
  local shown = print
  print = function(...)
    local parts = table.pack(...)
    for i = 1, parts.n do parts[i] = tostring(parts[i]) end
    lulibre.log(table.concat(parts, "\t"))
  end
  local quiet <close> = setmetatable({}, { __close = function() print = shown end })
  return chunk(...)
end

local function count(sql, ...)
  local row = lulibre.sql(sql, ...)[1]
  return row and row.n or 0
end

--- Opens the dialog.
function M.run()
  -- what is selected is asked before the dialog takes the cursor
  local scope = lulibre.source()
  local selected = lulibre.selection()
  local shown = lulibre.ids((scope == "sync" and "in:sync " or "") .. (lulibre.filter() or ""))
  local consensus, learn, datasets = require "lulibre.consensus", require "lulibre.learn", require "lulibre.datasets"
  local kept = count("SELECT count(*) AS n FROM lookups WHERE status = 200")
  local have_data = datasets.path("arxiv-metadata-oai-snapshot.json") or datasets.path("arxiv.json") or datasets.path("ol_dump_editions_latest.txt.gz")
  local services = lulibre.o.enrich_services or ""
  local has_refs = count("SELECT count(*) AS n FROM refs") > 0
  local waiting = proposals.count("pending", scope)

  local fields = {}
  for i, f in ipairs(FIELDS) do fields[i] = { id = "f_" .. f[1], kind = "check", label = f[2], value = true } end
  local did, v = form.run {
    title = "propose, then review", height = 0.78, label_width = 70,
    sections = {
      { title = "Which books", items = {
        { id = "books", kind = "choice", label = "propose for", value = 1, choices = {
          ("what is selected (%d book%s)"):format(#selected, #selected == 1 and "" or "s"),
          ("everything the list shows (%d)"):format(#shown), scope == "sync" and "every file in the sync folder" or "the whole library" } },
      } },
      { title = "What is asked", items = {
        { id = "files", kind = "check", label = "the files themselves: title pages, known layouts, embedded data", value = true },
        { id = "kept", kind = "check", label = "records kept on this machine (datasets, earlier answers)", value = have_data ~= nil or kept > 0,
          off = not have_data and kept == 0 and "none here yet: lulibre datasets" or nil },
        { id = "online", kind = "check", label = "ask online services (arXiv, CrossRef ...) about what isn't stored here", value = false,
          off = services == "" and "enrich_services is empty" or nil },
        { id = "titles", kind = "check", label = "  and CrossRef by title, for books with no identifier", value = false,
          off = services == "" and "enrich_services is empty" or nil },
        { id = "refs", kind = "check", label = "read the bibliographies first (:refs)", value = false },
        { id = "shared", kind = "check", label = "subjects from books that cite the same works", value = false,
          off = not has_refs and "no bibliography has been read: tick the line above, or :refs" or nil },
        { id = "learned", kind = "check", label = "subjects from learned phrases", value = false,
          off = not learn.ready() and "nothing learned yet: confirm records with gk, then :learn" or nil },
        { id = "weigh", kind = "check", label = "weigh each source by how often it has been right here", value = lulibre.o.weigh_sources,
          off = not consensus.ready() and "not measured yet: :weigh" or nil },
      } },
      { title = "Which fields", items = fields },
      { title = "What is there already", items = {
        { id = "over", kind = "choice", label = "a field that has a value", value = 1, choices = {
          ("as the option says (propose_over = %s)"):format(lulibre.o.propose_over), "is left alone: only empty or junk fields",
          "is proposed over wherever a source differs" } },
        { id = "fresh", kind = "check", label = "ignore current values, and propose values rejected for good (--fresh)", value = false },
        { id = "clear", kind = "check", label = ("drop the proposals waiting for these books first (%d wait in all)"):format(waiting), value = false,
          off = waiting == 0 and "none are waiting" or nil },
      } },
      { title = "Then, in review", items = {
        { id = "accept", kind = "number", label = "accept by itself what is at or above (0: nothing)", value = 0 },
        { id = "floor", kind = "number", label = "show nothing below a confidence of", value = 0 },
        { id = "sort", kind = "choice", label = "books in the order", value = 1, choices = { "the surest first", "those whose sources disagree most first", "by id" } },
      } },
      { title = "", items = {
        { id = "review", kind = "action", label = "Propose, then review" },
        { id = "propose", kind = "action", label = "Propose only" },
      } },
    },
  }
  if not did then return end

  local ids = v.books == 1 and selected or v.books == 2 and shown or lulibre.ids(scope == "sync" and "in:sync" or "")
  if #ids == 0 then
    lulibre.notify("no books to propose for", "error")
    return
  end
  local numbers = {}
  for i, id in ipairs(ids) do numbers[i] = tostring(math.abs(id)) end
  local filter = v.books == 3 and (scope == "sync" and "in:sync" or "") or ((scope == "sync" and "in:sync " or "") .. "id:" .. table.concat(numbers, ","))
  local only, letters, wanted = {}, {}, {}
  for _, f in ipairs(FIELDS) do
    if v["f_" .. f[1]] then
      only[#only + 1], letters[#letters + 1] = f[3], f[1]
      wanted[f[1]] = true
      if f[1] == "series" then wanted.series_index = true end
    end
  end
  if #only == 0 then
    lulibre.notify("no field is ticked", "error")
    return
  end

  if v.clear then
    for from = 1, #ids, 400 do
      local chunk = { table.unpack(ids, from, math.min(from + 399, #ids)) }
      lulibre.store(("DELETE FROM proposals WHERE status = 'pending' AND book IN (%s)"):format(table.concat(chunk, ",")))
    end
  end
  local steps = {}
  if v.refs then steps[#steps + 1] = "bibliographies" end
  if v.files then steps[#steps + 1] = "files" end
  if v.kept or v.online then steps[#steps + 1] = v.online and "records and services" or "records" end
  local run = runs.start { ids = ids, fields = #only < #FIELDS and wanted or nil, min = v.floor > 0 and v.floor or nil,
    sort = ({ "confidence", "disputed", "id" })[v.sort], steps = steps }
  do
    -- the options the boxes stand for, for this run only; put back however
    -- the run ends (done, failed, or stopped from outside)
    local was = { learned = lulibre.o.learned_tags, weigh = lulibre.o.weigh_sources }
    local over <close> = setmetatable({}, { __close = function()
      lulibre.o.learned_tags, lulibre.o.weigh_sources = was.learned, was.weigh
      lulibre.progress(nil)
      runs.finish(run, "cancelled") -- does nothing when the run got to its end
    end })
    if v.shared or v.learned then lulibre.o.learned_tags = "propose" end
    lulibre.o.weigh_sources = v.weigh and true or false
    local ok, err = pcall(function()
      if v.refs then
        runs.step(run, "bibliographies")
        script("refs", filter)
      end
      local flags = {}
      if #only < #FIELDS then flags[#flags + 1], flags[#flags + 2] = "--only", table.concat(only, ",") end
      if v.over == 2 then flags[#flags + 1] = "--gaps" elseif v.over == 3 then flags[#flags + 1] = "--over" end
      if v.fresh then flags[#flags + 1] = "--fresh" end
      flags[#flags + 1] = filter
      if v.files then
        runs.step(run, "files")
        script("propose", table.unpack(flags))
      end
      if v.kept or v.online then
        runs.step(run, v.online and "records and services" or "records")
        local e = {}
        if not v.online then e[#e + 1] = "--offline" end
        if v.titles and v.online then e[#e + 1] = "--titles" end
        e[#e + 1] = filter
        script("enrich", table.unpack(e))
      end
    end)
    if not ok then
      runs.finish(run, "failed")
      error(err, 0)
    end
    runs.finish(run)
  end

  local mine = {}
  for _, id in ipairs(ids) do mine[id] = true end
  local accepted, there = 0, 0
  for _, q in ipairs(proposals.list("pending", scope)) do
    if mine[q.book] and wanted[q.field] then
      there = there + 1
      -- by itself only where nothing is replaced: a value a book has is yours to give up
      if v.accept > 0 and (q.confidence or 0) >= v.accept and not proposals.replaces(q) then
        proposals.set_status(q.id, "accepted")
        accepted = accepted + 1
      end
    end
  end
  if there == 0 then
    lulibre.notify(("nothing to propose for %d book%s: the sources that were asked agree with what is there"):format(#ids, #ids == 1 and "" or "s"))
    return
  end
  lulibre.notify(("%d proposal%s for %d book%s%s"):format(there, there == 1 and "" or "s", #ids, #ids == 1 and "" or "s",
    accepted > 0 and (", %d accepted at %.2f or more"):format(accepted, v.accept) or ""))
  if did == "review" then require("lulibre.ui.review").show_run(run) end
end

return M
