--- Opens dialogs for things lulibre already does. Each dialog is a form
-- (lulibre.ui.form) that says what will happen before it happens:
--
-- - `enrich`: look books up. Shows what would be asked of which services, then runs.
-- - `change`: one change to every selected book: add or remove a subject, or set a field.
-- - `datasets`: the databases kept on this machine. Choose which to fetch.
-- - `sync`: the selected waiting files. Add them, add and remove them, or drop them.
--
-- @module lulibre.ui.dialogs
-- @usage
-- require("lulibre.ui.dialogs").change()   -- one change to every selected book
-- require("lulibre.ui.dialogs").sync()     -- the selected waiting files
local form = require "lulibre.ui.form"

local M = {}

-- run one of the scripts (the user's own of that name first) and wait for it;
-- with `capture`, what it prints is gathered and returned instead of shown
local function script(name, capture, ...)
  local paths = lulibre.settings.paths()
  local src = debug.getinfo(1, "S").source:gsub("^@", "")
  local root = src:match("^(.*)/lua/lulibre/ui/dialogs%.lua$")
  local chunk
  for _, path in ipairs { (paths.scripts or "") .. "/" .. name .. ".lua", (root or ".") .. "/scripts/" .. name .. ".lua" } do
    chunk = chunk or loadfile(path)
  end
  if not chunk then error(("the script '%s' was not found"):format(name), 0) end
  if not capture then return chunk(...) end
  local lines, shown = {}, print
  print = function(...)
    local parts = table.pack(...)
    for i = 1, parts.n do parts[i] = tostring(parts[i]) end
    for line in (table.concat(parts, "\t") .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
  end
  local ok, err = pcall(chunk, ...)
  print = shown
  if not ok then error(err, 0) end
  return lines
end

local function id_filter(ids, scope)
  local numbers = {}
  for i, id in ipairs(ids) do numbers[i] = tostring(math.abs(id)) end
  return (scope == "sync" and "in:sync " or "") .. "id:" .. table.concat(numbers, ",")
end

local function plural(n, word)
  return ("%d %s%s"):format(n, word, n == 1 and "" or "s")
end

--- Looks books up by their identifiers. The dialog first shows what a run
-- would ask of which services (nothing is asked to find this out), then
-- lets you choose the services, then runs.
function M.enrich()
  local scope = lulibre.source()
  local ids = lulibre.selection()
  if #ids == 0 then
    lulibre.notify("no book selected", "error")
    return
  end
  local filter = id_filter(ids, scope)
  lulibre.progress("working out what would be asked")
  local plan = script("enrich", true, "--plan", filter)
  lulibre.progress(nil)
  -- "  arxiv   144 works not yet asked about, in 4 requests, 5 s apart"
  local asks, notes = {}, {}
  for _, line in ipairs(plan) do
    local service, works, requests = line:match("^%s+(%a+)%s+(%d+) works? not yet asked about, in (%d+) requests?")
    if service then asks[service] = { works = tonumber(works), requests = tonumber(requests), paused = line:match("%((paused until [%d:]+)%)") }
    elseif not line:match("^%s") or line:find("minute") then notes[#notes + 1] = { kind = "note", label = (line:gsub("^%s+", "")) } end
  end
  local all = {}
  for name in (lulibre.o.enrich_services or ""):gmatch("[^,%s]+") do all[#all + 1] = name:lower() end
  local boxes, total = {}, 0
  for _, name in ipairs(all) do
    local a = asks[name]
    total = total + (a and a.requests or 0)
    boxes[#boxes + 1] = { id = "s_" .. name, kind = "check", value = a ~= nil and a.requests > 0 and not a.paused,
      label = a and ("%-12s %s to ask about, in %s"):format(name, plural(a.works, "work"), plural(a.requests, "request"))
        or ("%-12s only when another service has nothing"):format(name),
      off = a and a.paused or nil, hint = a and a.requests == 0 and "nothing left to ask" or nil }
  end
  if #all == 0 then notes[#notes + 1] = { kind = "note", label = "no service is switched on: the option enrich_services is empty" } end
  local did, v = form.run {
    title = ("look up %s"):format(plural(#ids, "book")), height = 0.6, label_width = 66,
    sections = {
      { title = "What a run would ask (nothing has been asked yet)", items = notes },
      { title = "Ask", items = boxes },
      { title = "And", items = {
        { id = "titles", kind = "check", label = "search CrossRef by title for books with no identifier", value = false, off = #all == 0 and "no service" or nil },
      } },
      { title = "", items = {
        { id = "online", kind = "action", label = total > 0 and ("Ask, then review (%s)"):format(plural(total, "request")) or "Propose from what is kept, then review" },
        { id = "offline", kind = "action", label = "Ask nobody: propose from what is kept here, then review" },
      } },
    },
  }
  if not did then return end
  local was = lulibre.o.enrich_services
  local ticked = {}
  for _, name in ipairs(all) do
    if v["s_" .. name] or not asks[name] then ticked[#ticked + 1] = name end
  end
  local flags = {}
  if did == "offline" then flags[#flags + 1] = "--offline" end
  if v.titles and did ~= "offline" then flags[#flags + 1] = "--titles" end
  flags[#flags + 1] = filter
  lulibre.o.enrich_services = table.concat(ticked, ",")
  local ok, err = pcall(script, "enrich", false, table.unpack(flags))
  lulibre.o.enrich_services = was
  if not ok then error(err, 0) end
  require("lulibre.ui.review").run { ids = ids }
end

--- Makes one change to every selected book: add or remove a subject, or
-- set the authors, series, publisher, date or language. The change is
-- written like any other, and one undo reverses all of it.
function M.change()
  local edit = require "lulibre.edit"
  local ids = lulibre.selection()
  if #ids == 0 then
    lulibre.notify("no book selected", "error")
    return
  end
  local did, v = form.run {
    title = ("change %s at once"):format(plural(#ids, "book")), height = 0.5, label_width = 40,
    help = "Enter types a value   w writes   (empty lines change nothing)",
    sections = {
      { title = "Subjects", items = {
        { id = "add", kind = "text", label = "add the subject", value = "" },
        { id = "remove", kind = "text", label = "remove the subject", value = "" },
      } },
      { title = "Set, for every one of them", items = {
        { id = "authors", kind = "text", label = "authors (A. One & B. Two)", value = "" },
        { id = "series", kind = "text", label = "series", value = "" },
        { id = "publisher", kind = "text", label = "publisher", value = "" },
        { id = "pubdate", kind = "text", label = "date (YYYY or YYYY-MM-DD)", value = "" },
        { id = "languages", kind = "text", label = "language", value = "" },
        { id = "titlecase", kind = "check", label = "put each title in title case", value = false },
      } },
      { title = "", items = { { id = "write", kind = "action", label = ("Write to %s"):format(plural(#ids, "book")) } } },
    },
  }
  if not did then return end
  local changes = {}
  local function each(field, value, op)
    for _, id in ipairs(ids) do changes[#changes + 1] = { id = id, field = field, value = value, op = op } end
  end
  if v.add ~= "" then each("tags", v.add, "add") end
  if v.remove ~= "" then each("tags", v.remove, "remove") end
  for _, field in ipairs { "authors", "series", "publisher", "pubdate", "languages" } do
    if v[field] ~= "" then each(field, v[field], "set") end
  end
  if v.titlecase then
    local tc = require "lulibre.titlecase"
    for _, id in ipairs(ids) do
      local book = lulibre.book(id)
      local to = book and tc.apply(book.title or "")
      if to and to ~= book.title then changes[#changes + 1] = { id = id, field = "title", value = to, op = "set" } end
    end
  end
  if #changes == 0 then
    lulibre.notify("nothing was filled in: nothing changed")
    return
  end
  local r = edit.apply(changes, { label = "change at once" })
  lulibre.notify(edit.summary(r), #r.failed > 0 and "error" or nil)
end

--- Shows the databases lulibre can keep on this machine and which are
-- here, and lets you choose which to fetch now.
function M.datasets()
  local datasets = require "lulibre.datasets"
  local items = {}
  for _, ds in ipairs(datasets.list) do
    local st = datasets.status(ds)
    local stale = ds.renewed and st.here and st.age > ds.renewed
    -- nothing is ticked to begin with but what has gone stale: these are large, and yours to ask for
    items[#items + 1] = { id = ds.name, kind = "check", value = stale or false, label = ("%-12s %s"):format(ds.name, ds.title),
      hint = datasets.state(ds) }
    items[#items + 1] = { kind = "note", label = ds.useful }
    items[#items + 1] = { kind = "note", label = ("%s; from %s."):format(ds.size, ds.from) }
  end
  local did, v = form.run {
    title = "databases for looking books up without asking anybody", height = 0.6, label_width = 54,
    sections = {
      { title = ("Kept in %s"):format(datasets.dir()), items = items },
      { title = "", items = {
        { id = "fetch", kind = "action", label = "Fetch the ticked ones", hint = "what is here and fresh is left alone" },
        { id = "force", kind = "action", label = "Fetch them even if fresh" },
      } },
    },
  }
  if not did then return end
  local done, failed = 0, {}
  for _, ds in ipairs(datasets.list) do
    if v[ds.name] then
      local ok, why = datasets.fetch(ds, { force = did == "force", say = function(text) lulibre.progress(text) end })
      lulibre.progress(nil)
      if ok then done = done + 1 else failed[#failed + 1] = why end
    end
  end
  if #failed > 0 then error(failed[1], 0) end
  lulibre.notify(done > 0 and ("%s seen to: :enrich reads from what is here before it asks anybody"):format(plural(done, "dataset")) or "nothing was ticked")
end

--- Shows what would happen to each selected waiting file in the sync
-- folder, and lets you choose what to do.
function M.sync()
  local sync = require "lulibre.sync"
  if lulibre.source() ~= "sync" then
    lulibre.notify(("the list is showing the library; %s shows the sync folder"):format(lulibre.hint("sync")), "error")
    return
  end
  local ids = lulibre.selection()
  if #ids == 0 then
    lulibre.notify("no waiting file selected", "error")
    return
  end
  local new, held, lines = 0, 0, {}
  for i, id in ipairs(ids) do
    local row = lulibre.sql("SELECT path, title, twin FROM staged WHERE id = ?", -id)[1]
    if row then
      if row.twin then held = held + 1 else new = new + 1 end
      if i <= 10 then
        lines[#lines + 1] = { kind = "note", label = ("%-9s %s"):format(row.twin and ("= " .. row.twin) or "new", row.title or row.path:match("[^/]+$")) }
      end
    end
  end
  if #ids > 10 then lines[#lines + 1] = { kind = "note", label = ("... and %d more"):format(#ids - 10) } end
  local did, v = form.run {
    title = ("%s waiting in the sync folder"):format(plural(#ids, "file")), height = 0.55, label_width = 48,
    sections = {
      { title = ("%d new, %d the library already holds"):format(new, held), items = lines },
      { title = "Do", items = {
        { id = "what", kind = "choice", label = "with them", value = 1, choices = {
          "add to the library; the files stay in the folder",
          "add to the library, then delete the files from the folder",
          ("take out of the folder without adding (%s puts them back)"):format(lulibre.hint("undo")) } },
        { id = "propose", kind = "check", label = "propose metadata from their title pages first", value = false },
      } },
      { title = "", items = { { id = "go", kind = "action", label = "Go" } } },
    },
  }
  if not did then return end
  if v.propose and v.what ~= 3 then
    lulibre.index { filter = "in:sync" }
    script("propose", false, id_filter(ids, "sync"))
  end
  if v.what == 3 then
    local out = sync.drop(ids)
    lulibre.notify(#out.failed > 0 and out.failed[1] or ("dropped %s; kept in %s"):format(plural(out.dropped, "file"), out.holding), #out.failed > 0 and "error" or nil)
  else
    local out = sync.add(ids, { remove = v.what == 2 })
    lulibre.notify(sync.summary(out), #out.failed > 0 and "error" or nil)
  end
end

return M
