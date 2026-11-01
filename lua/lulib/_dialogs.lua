--- Dialogs for things lulibre already does, each a uiman.form that says what
-- will happen before it happens:
--
-- - `enrich`: look books up. Shows what would be asked of which services, then runs.
-- - `change`: one change to every selected book: add or remove a subject, or set a field.
-- - `sync`: the selected waiting files. Add them, add and remove them, or drop them.
-- - `propose_review`: which books, what to consult, which fields, how existing
--   values are treated, and then review.
--
-- @library lulib._dialogs
local bookman = require "bookman"
local propose = require "lulib._propose"
local store = require "store"

local M = {}

local function plural(n, word)
  return ("%d %s%s"):format(n, word, n == 1 and "" or "s")
end

--- Looks books up by their identifiers. The dialog first shows what a run
-- would ask of which services (nothing is asked to find this out), then
-- lets you choose the services, then runs.
function M.enrich(ids)
  if #ids == 0 then return uiman.notify("no book selected", "error") end
  local net = require "net"
  local service = require "net.service"
  local asks, names = {}, {}
  uiman.progress("working out what would be asked")
  for _, book in ipairs(ids) do
    for _, k in ipairs(net.keys(book)) do
      if not service.kept(k.service, k.key) then
        asks[k.service] = (asks[k.service] or 0) + 1
      end
    end
  end
  uiman.progress(nil)
  for name in pairs(net.services) do names[#names + 1] = name end
  table.sort(names)
  local boxes, total = {}, 0
  for _, name in ipairs(names) do
    local n = asks[name] or 0
    total = total + n
    boxes[#boxes + 1] = { id = "s_" .. name, kind = "check", value = n > 0,
                          label = ("%-12s %s to ask about"):format(name, plural(n, "work")),
                          hint = n == 0 and "nothing left to ask" or nil }
  end
  local did, v = uiman.form {
    title = ("look up %s"):format(plural(#ids, "book")), height = 0.6, label_width = 66,
    sections = {
      { title = "Ask", items = boxes },
      { title = "And", items = {
        { id = "titles", kind = "check", label = "search by title, for books with no identifier", value = false },
      } },
      { title = "", items = {
        { id = "online", kind = "action", label = total > 0 and ("Ask, then review (%s)"):format(plural(total, "request"))
          or "Nothing to ask: review what is kept" },
        { id = "offline", kind = "action", label = "Ask no service: propose from what is kept, then review" },
      } },
    },
  }
  if not did then return end
  if did == "online" then
    local chosen = {}
    for _, name in ipairs(names) do chosen[name] = v["s_" .. name] end
    for _, name in ipairs(names) do
      if net.services[name].how.ident == "title" then chosen[name] = v.titles end
    end
    net.enrich_many(ids, { titles = v.titles, services = chosen })
  end
  local w <const> = propose.settings()
  for _, book in ipairs(ids) do propose.propose(book, w) end
  require("lulib._review").open(ids)
end

--- Makes one change to every selected book: add or remove a subject, or
-- set the authors, series, publisher, date or language. The change is
-- written like any other, and one undo reverses all of it.
function M.change(ids)
  if #ids == 0 then return uiman.notify("no book selected", "error") end
  local did, v = uiman.form {
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
    for _, id in ipairs(ids) do changes[#changes + 1] = { book = id, field = field, value = value, op = op } end
  end
  if v.add ~= "" then each("tags", v.add, "add") end
  if v.remove ~= "" then each("tags", v.remove, "remove") end
  for _, field in ipairs { "authors", "series", "publisher", "pubdate", "languages" } do
    if v[field] ~= "" then each(field, v[field], "set") end
  end
  if v.titlecase then
    local tc = require "lulib._titlecase"
    for _, id in ipairs(ids) do
      local title = bookman.get(id, "title") or ""
      local to = tc.apply(title)
      if to ~= title then changes[#changes + 1] = { book = id, field = "title", value = to, op = "set" } end
    end
  end
  if #changes == 0 then return uiman.notify("nothing was filled in: nothing changed") end
  local batch, err = store.apply(changes, "change at once")
  if err then return uiman.notify(err, "error") end
  uiman.notify(batch and ("changed %s: :undo puts it back"):format(plural(#ids, "book")) or "nothing was to change")
end

--- Shows what would happen to each selected waiting file in the sync
-- folder, and lets you choose what to do.
function M.sync(ids)
  local sync = require "lulib._sync"
  local waiting = {}
  for _, id in ipairs(ids) do
    if id < 0 then waiting[#waiting + 1] = id end
  end
  if #waiting == 0 then return uiman.notify("no waiting file selected", "error") end
  local new, held, lines = 0, 0, {}
  for i, id in ipairs(waiting) do
    local row = sync.staged(id)
    if row then
      if row.twin then held = held + 1 else new = new + 1 end
      if i <= 10 then
        lines[#lines + 1] = { kind = "note", label = ("%-9s %s"):format(row.twin and ("= " .. row.twin) or "new", row.title or "") }
      end
    end
  end
  if #waiting > 10 then lines[#lines + 1] = { kind = "note", label = ("... and %d more"):format(#waiting - 10) } end
  local did, v = uiman.form {
    title = ("%s waiting in the sync folder"):format(plural(#waiting, "file")), height = 0.55, label_width = 48,
    sections = {
      { title = ("%d new, %d the library already holds"):format(new, held), items = lines },
      { title = "Do", items = {
        { id = "what", kind = "choice", label = "with them", value = 1, choices = {
          "add to the library; the files stay in the folder",
          "add to the library, then take the files out of the folder",
          "take out of the folder without adding (:undo puts them back)" } },
        { id = "propose", kind = "check", label = "propose metadata from their title pages first", value = false },
      } },
      { title = "", items = { { id = "go", kind = "action", label = "Go" } } },
    },
  }
  if not did then return end
  if v.propose and v.what ~= 3 then
    local w <const> = propose.settings()
    for _, id in ipairs(waiting) do propose.propose(id, w) end
    return require("lulib._review").open(waiting)
  end
  if v.what == 3 then
    local out = sync.drop(waiting)
    uiman.notify(#out.failed > 0 and out.failed[1] or ("dropped %s"):format(plural(out.dropped, "file")),
                 #out.failed > 0 and "error" or nil)
  else
    local out = sync.add(waiting, { remove = v.what == 2 })
    uiman.notify(sync.summary(out), #out.failed > 0 and "error" or nil)
  end
end

--- Shows the databases lulibre can keep on this machine and which are here, and
-- lets you choose which to fetch now.
function M.datasets()
  local datasets = require "lulib._datasets"
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
  local did, v = uiman.form {
    title = "databases for looking books up without asking anybody", height = 0.6, label_width = 54,
    sections = {
      { title = ("Kept in %s"):format(datasets.dir()), items = items },
      { title = "", items = {
        { id = "fetch", kind = "action", label = "Fetch the ticked ones", hint = "a dataset on this machine and up to date is left alone" },
        { id = "force", kind = "action", label = "Fetch them even if fresh" },
      } },
    },
  }
  if not did then return end
  local done, failed = 0, {}
  for _, ds in ipairs(datasets.list) do
    if v[ds.name] then
      local ok, why = datasets.fetch(ds, { force = did == "force", say = function(text) uiman.progress(text) end })
      uiman.progress(nil)
      if ok then done = done + 1 else failed[#failed + 1] = why end
    end
  end
  if #failed > 0 then return uiman.notify(failed[1], "error") end
  uiman.notify(done > 0 and ("%d fetched or already up to date: :enrich reads them before it asks anybody"):format(done) or "nothing was ticked")
end

local FIELDS = { { "title", "title" }, { "authors", "authors" }, { "tags", "subject" }, { "pubdate", "date" },
                 { "publisher", "publisher" }, { "series", "series" }, { "identifiers", "identifiers" } }

--- Proposes and then reviews, from one dialog: which books, what to consult,
-- which fields, how existing values are treated, and what review then shows.
function M.propose_review(selected)
  local wit = require "wit"
  local shown = bookman.ids(uiman.filter() or "")
  local fields = {}
  for i, f in ipairs(FIELDS) do fields[i] = { id = "f_" .. f[1], kind = "check", label = f[2], value = true } end
  local did, v = uiman.form {
    title = "propose, then review", height = 0.78, label_width = 70,
    sections = {
      { title = "Which books", items = {
        { id = "books", kind = "choice", label = "propose for", value = 1, choices = {
          ("what is selected (%s)"):format(plural(#selected, "book")),
          ("everything the list shows (%d)"):format(#shown), "the whole library" } },
      } },
      { title = "What is asked", items = {
        { id = "online", kind = "check", label = "ask online services (arXiv, Crossref ...) for what is not yet kept", value = false },
        { id = "titles", kind = "check", label = "  and Crossref by title, for books with no identifier", value = false },
      } },
      { title = "Which fields", items = fields },
      { title = "What is there already", items = {
        { id = "over", kind = "choice", label = "a field that has a value", value = 1, choices = {
          ("as the setting says (propose_over = %s)"):format(tostring(setman.get("propose_over"))),
          "is left alone: only empty or junk fields", "is proposed over wherever a source differs" } },
        { id = "fresh", kind = "check", label = "propose values already decided against too", value = false },
      } },
      { title = "Then, in review", items = {
        { id = "accept", kind = "number", label = "mark accepted what is at or above (0: nothing), on empty fields", value = 0 },
        { id = "floor", kind = "number", label = ("show nothing below (propose_min = %s)"):format(tostring(setman.get("propose_min"))), value = setman.get("propose_min") },
      } },
      { title = "", items = {
        { id = "review", kind = "action", label = "Propose, then review" },
        { id = "propose", kind = "action", label = "Propose only" },
      } },
    },
  }
  if not did then return end
  local ids = v.books == 1 and selected or v.books == 2 and shown or bookman.ids("")
  if #ids == 0 then return uiman.notify("no books to propose for", "error") end
  local only, any = {}, false
  for _, f in ipairs(FIELDS) do
    if v["f_" .. f[1]] then
      only[f[1]] = true
      any = true
      if f[1] == "series" then only.series_index = true end
    end
  end
  if not any then return uiman.notify("no field is ticked", "error") end
  local w = propose.settings()
  w.only = only
  w.min = v.floor
  if v.over == 2 then w.over = 2 elseif v.over == 3 then w.over = w.min end
  if v.fresh then w.decided = {} end
  if v.online then
    local net = require "net"
    uiman.progress(("asking about %d books"):format(#ids))
    net.enrich_many(ids, { titles = v.titles })
    uiman.progress(nil)
  end
  local fields_n = 0
  for i, book in ipairs(ids) do
    if i % 20 == 0 then uiman.progress(("proposing %d/%d"):format(i, #ids)) end
    fields_n = fields_n + (propose.propose(book, w) or 0)
  end
  uiman.progress(nil)
  local marked = 0
  if v.accept > 0 then
    for _, book in ipairs(ids) do
      for _, f in ipairs(wit.get(book)) do
        local a = f.alts[1]
        if (a.score or 0) >= v.accept and (wit.now(book, f.field) or "") == "" then
          wit.accept(a.id)
          marked = marked + 1
        end
      end
    end
  end
  if fields_n == 0 then
    return uiman.notify(("nothing to propose for %s: the sources agree with what is there"):format(plural(#ids, "book")))
  end
  uiman.notify(("%s for %s%s"):format(plural(fields_n, "proposal"), plural(#ids, "book"),
                                      marked > 0 and (", %d marked accepted"):format(marked) or ""))
  if did == "review" then require("lulib._review").open(ids) end
end

return M
