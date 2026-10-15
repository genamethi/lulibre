-- Snapshots: points in the history of the library that it can be put back to.
--
-- The history (a file of its own beside the index, attached as `history`)
-- is the journal of every change: each field lulibre wrote, with what it
-- was before; each book removed, added from the sync folder, put back or
-- dropped; and the changes made to calibre by other means (its own window,
-- the content server, another program), which are found by comparing the
-- books with what they were the last time anyone looked, and logged as one
-- batch labelled "outside" when the next change is logged. A snapshot is no
-- more than a place in that journal: no copy of the library is kept.
--
-- Putting the library back to a snapshot (rollback) works out, for every
-- field changed since, what it was then, and writes it through calibre like
-- any other change (so it is journaled, and undone like one):
--   * a field lulibre changed goes back to what it was;
--   * a field changed outside lulibre is left as it is, unless `exact`;
--   * a field changed again since by means the journal did not see (it
--     is not what lulibre last wrote) is left alone and counted;
--   * a book added from the sync folder since goes back to how it was when
--     it was added (what was done to it in the library is what is undone),
--     or, with `unsync`, out of the library, its files moved to the sync
--     folder's unsynced/ folder;
--   * a book removed since comes back out of calibre's recycle bin, and a
--     book put back since goes again.
-- Before it writes anything a rollback takes a snapshot of its own, so going
-- back to that one is rolling forward again. Books nothing has touched since
-- are not looked at, and a second rollback to the same snapshot changes
-- nothing.
--
-- A snapshot made from a calibre database kept from before (`import`) also
-- carries the few values where that database differs from what the journal
-- says the library was at that time: changes nobody logged. Those count as
-- changes made outside lulibre.
--
--   local snapshots = require "lulibre.snapshots"
--   snapshots.observe()                    -- log changes made outside lulibre; how many fields
--   snapshots.added(id, from, label)       -- log a book lulibre has just added to calibre
--   snapshots.take(name)                   -- the new snapshot's row
--   snapshots.list{ all = }                -- { {id=, name=, ts=, upto=, auto=, retired=, books=, changes=}, ... }
--   snapshots.find("3" or "a name")        -- one row, or nil and why
--   snapshots.retire(id, on)               -- take one out of the list (on = false puts it back)
--   snapshots.plan(id, { exact=, unsync= }) -- what a rollback would do, writing nothing
--   snapshots.rollback(id, opts)           -- do it; a summary
--   snapshots.import(path, name)           -- a snapshot from another copy of calibre's metadata.db
local edit = require "lulibre.edit"
local json = require "lulibre.json"

local M = {}

-- fields a snapshot puts back
M.fields = edit.fields
-- the journal's names for what happened to a whole book
M.ADDED, M.REMOVED, M.RESTORED, M.DROPPED = "(added)", "(removed)", "(restored)", "(dropped)"
-- the folder under the sync folder that books taken back out of the library go to
M.UNSYNCED = "unsynced"

local function kv(key)
  local r = lulibre.sql("SELECT value FROM kv WHERE key = ?", key)[1]
  return r and r.value
end

local function set_kv(key, value)
  if value == nil then lulibre.store("DELETE FROM kv WHERE key = ?", key)
  else lulibre.store("INSERT OR REPLACE INTO kv(key, value) VALUES(?, ?)", key, tostring(value)) end
end

local function next_batch()
  return lulibre.store("SELECT coalesce(max(batch), 0) + 1 AS n FROM journal")[1].n
end

local function last_row()
  return lulibre.sql("SELECT coalesce(max(id), 0) AS n FROM journal")[1].n
end

--- A row of the books table (or of mirror_prev, or of another calibre
-- database) as the values the journal keeps, field by field: the same
-- spelling edit.current gives.
function M.values(row)
  local series = row.series or ""
  return {
    title = row.title or "",
    authors = edit.is_unknown(row.authors) and "" or (row.authors or ""),
    tags = row.tags or "",
    series = series,
    series_index = (series ~= "" and row.series_index) and ("%.10g"):format(row.series_index) or "",
    publisher = row.publisher or "",
    pubdate = row.pubdate or "",
    languages = row.languages or "",
    identifiers = row.idents or "",
  }
end

-- what the journal keeps of a whole book: its values, title and formats
local function state(row)
  local s = M.values(row)
  s.formats = {}
  for f in (row.formats or ""):gmatch("[^,]+") do s.formats[#s.formats + 1] = f end
  return s
end
M.state = state

local BOOK_COLS = "id, title, authors, tags, series, series_index, publisher, pubdate, languages, idents, formats, path"

--- Log the changes made to calibre by other means since the last look, as
-- one batch labelled "outside". Changes lulibre made itself in the meantime
-- are in the journal already and are told apart by it. Returns how many
-- fields (and books) were logged.
function M.observe()
  pcall(lulibre.reload) -- picks up a changed metadata.db; nothing when it has not changed
  if not kv("history:pending") then return 0 end
  local seen = tonumber(kv("history:seen")) or 0
  -- what lulibre did since it last looked, whatever came of it
  local ours, whole = {}, {}
  for _, r in ipairs(lulibre.sql("SELECT book, field FROM journal WHERE id > ?", seen)) do
    ours[r.book .. "\0" .. r.field] = true
    whole[r.book] = true
  end
  local before, now = {}, {}
  for _, r in ipairs(lulibre.sql("SELECT " .. BOOK_COLS .. " FROM mirror_prev")) do before[r.id] = r end
  for _, r in ipairs(lulibre.sql("SELECT " .. BOOK_COLS .. " FROM books WHERE id > 0")) do now[r.id] = r end

  local rows = {}
  for id, r in pairs(now) do
    local was = before[id]
    if not was then
      if not whole[id] then rows[#rows + 1] = { id, M.ADDED, "", json.encode(state(r)) }
      else
        -- added by lulibre before the index had it: what it came with is noted now
        local came = state(r)
        lulibre.store([[UPDATE journal SET new = ? WHERE book = ? AND field = '(added)' AND coalesce(new, '') = '']],
          json.encode(came), id)
      end
    else
      local a, b = M.values(was), M.values(r)
      for _, f in ipairs(M.fields) do
        -- a series index means nothing without its series: it changes with it
        local mine = ours[id .. "\0" .. f] or (f == "series_index" and ours[id .. "\0series"])
        if a[f] ~= b[f] and not mine then rows[#rows + 1] = { id, f, a[f], b[f] } end
      end
    end
  end
  for id, was in pairs(before) do
    if not now[id] and not whole[id] then rows[#rows + 1] = { id, M.REMOVED, json.encode(state(was)), "" } end
  end
  table.sort(rows, function(x, y)
    if x[1] ~= y[1] then return x[1] < y[1] end
    return x[2] < y[2]
  end)
  if #rows > 0 then
    local batch, ts = next_batch(), os.time()
    for _, r in ipairs(rows) do
      lulibre.store([[INSERT INTO journal(batch, book, field, old, new, status, ts, label)
        VALUES(?, ?, ?, ?, ?, 'applied', ?, 'outside')]], batch, r[1], r[2], r[3], r[4], ts)
    end
  end
  lulibre.store("DELETE FROM mirror_prev")
  set_kv("history:pending", nil)
  -- rows still being written belong to a change in progress: look past them only once they are done
  local open = lulibre.sql("SELECT min(id) AS n FROM journal WHERE status = 'pending' AND ts > ?", os.time() - 3600)[1].n
  set_kv("history:seen", open and open - 1 or last_row())
  return #rows
end

--- Log that a book was added to the library by lulibre (from the sync
-- folder, the orphans, onboard): call it as soon as calibre has added it,
-- before anything else looks. from: where its file came from; label names
-- the batch. What it came with is noted now if the index has it already,
-- else the next look (observe) notes it.
function M.added(id, from, label, batch)
  local row = lulibre.sql("SELECT * FROM books WHERE id = ?", id)[1]
  local came = row and state(row) or nil
  if came then came.from = from end
  batch = batch or next_batch()
  lulibre.store([[INSERT INTO journal(batch, book, field, old, new, status, ts, label)
    VALUES(?, ?, '(added)', ?, ?, 'applied', ?, ?)]], batch, id, from or "", came and json.encode(came) or "", os.time(),
    label or "add")
  return batch
end

--- Take a snapshot: the library as it is now. Returns its row.
function M.take(name, opts)
  opts = opts or {}
  M.observe()
  name = name and name:match("^%s*(.-)%s*$") or ""
  if name == "" then name = os.date("%Y-%m-%d %H:%M") end
  local _, _, id = lulibre.store("INSERT INTO snapshots(name, ts, upto, auto, note) VALUES(?, ?, ?, ?, ?)",
    name, opts.ts or os.time(), opts.upto or last_row(), opts.auto and 1 or 0, opts.note)
  return lulibre.sql("SELECT * FROM snapshots WHERE id = ?", id)[1]
end

--- The snapshots, newest first, each with how many books and fields have
-- changed since. opts.all: the retired ones too.
function M.list(opts)
  opts = opts or {}
  return lulibre.sql([[SELECT s.*,
      (SELECT count(DISTINCT j.book) FROM journal j WHERE j.id > s.upto AND j.status = 'applied') AS books,
      (SELECT count(*) FROM journal j WHERE j.id > s.upto AND j.status = 'applied') AS changes
    FROM snapshots s WHERE ? OR s.retired IS NULL ORDER BY s.upto DESC, s.id DESC]], opts.all and 1 or 0)
end

--- A snapshot by number or name (the newest of that name). Returns the row,
-- or nil and why not.
function M.find(what)
  what = tostring(what or ""):match("^%s*(.-)%s*$")
  if what == "" then return nil, "which snapshot? (:snapshots lists them)" end
  local row = tonumber(what) and lulibre.sql("SELECT * FROM snapshots WHERE id = ?", tonumber(what))[1]
    or lulibre.sql("SELECT * FROM snapshots WHERE name = ? ORDER BY id DESC LIMIT 1", what)[1]
  if not row then return nil, ("no snapshot '%s' (:snapshots lists them)"):format(what) end
  return row
end

--- Retire a snapshot (on = false brings it back). Nothing is lost: the
-- journal stays, and a retired snapshot is still listed with all = true.
function M.retire(id, on)
  local _, n = lulibre.store("UPDATE snapshots SET retired = ? WHERE id = ?", on ~= false and os.time() or nil, id)
  return n > 0
end

-- ---- working out a rollback ----

local function key(book, field) return book .. "\0" .. field end

-- calibre keeps one spelling of an author or tag whatever its case ("math/topology"
-- written where "math/Topology" exists is stored as the latter), so those compare without it
local function same(field, a, b)
  if field == "authors" or field == "tags" then return (a or ""):lower() == (b or ""):lower() end
  return a == b
end
M.same = same

--- What putting the library back to snapshot `id` would do. Writes nothing.
-- opts.exact: put back changes made outside lulibre too. opts.unsync: take
-- books added since out of the library instead of back to how they came.
-- opts.fields: fields only; no book is brought back, removed or taken out.
-- Returns { snap=, changes = { {id=, field=, value=, op="set"} }, restore = { journal rows },
--   remove = { ids }, unsync = { ids }, undrop = { journal rows },
--   kept = { outside=, since=, unknown_added = { ids }, gone = { ids } }, books= }
function M.plan(id, opts)
  opts = opts or {}
  local snap = type(id) == "table" and id or assert(M.find(id))
  local rows = lulibre.sql([[SELECT id, book, field, old, new, label, undone FROM journal
    WHERE id > ? AND status = 'applied' ORDER BY id]], snap.upto)
  local fixed = {}
  for _, r in ipairs(lulibre.sql("SELECT book, field, value FROM snapshot_values WHERE snap = ?", snap.id)) do
    fixed[key(r.book, r.field)] = r.value
  end

  local fields, order = {}, {}         -- key -> { book=, field=, first=, last=, outside= }
  local added, removed, restored, dropped = {}, {}, {}, {}
  for _, r in ipairs(rows) do
    if r.field == M.ADDED then
      if not added[r.book] then added[r.book] = r end
    elseif r.field == M.REMOVED then
      removed[r.book] = r
    elseif r.field == M.RESTORED then
      restored[r.book] = r
    elseif r.field == M.DROPPED then
      dropped[#dropped + 1] = r
    elseif r.field:sub(1, 1) == "(" then
      -- a file replaced ("(format)"): not a field; :undo takes it back
    else
      local k = key(r.book, r.field)
      local f = fields[k]
      if not f then
        f = { book = r.book, field = r.field, first = r.old or "" }
        fields[k] = f
        order[#order + 1] = k
      end
      f.last = r.new or ""
      if r.label == "outside" then f.outside = true end
      -- a field of a book added since goes back to how it came, not to before it was there
      if added[r.book] then f.after_add = true end
    end
  end
  -- values the journal did not see, from an imported snapshot
  for k, value in pairs(fixed) do
    local book, field = k:match("^(-?%d+)%z(.*)$")
    book = tonumber(book)
    if not fields[k] then
      fields[k] = { book = book, field = field, first = value, outside = true, unlogged = true }
      order[#order + 1] = k
    else
      fields[k].first, fields[k].outside = value, true
    end
  end
  table.sort(order)

  if opts.fields then dropped = {} end
  local plan = { snap = snap, changes = {}, restore = {}, remove = {}, unsync = {}, undrop = dropped, after_restore = {},
    kept = { outside = 0, since = 0, unknown_added = {}, gone = {} } }
  local touched = {}
  for book, r in pairs(added) do
    if book > 0 and lulibre.book(book) then
      if opts.unsync and not opts.fields then plan.unsync[#plan.unsync + 1] = book end
      touched[book] = true
    end
  end
  for _, k in ipairs(order) do
    local f = fields[k]
    if removed[f.book] and not added[f.book] and not (f.outside and not opts.exact) then
      -- a book removed since comes back as calibre kept it then; this puts its fields back too
      plan.after_restore[f.book] = plan.after_restore[f.book] or {}
      plan.after_restore[f.book][f.field] = f.first
    end
    local book = f.book > 0 and not removed[f.book] and lulibre.book(f.book) or (f.book < 0 and lulibre.book(f.book))
    if book and not (opts.unsync and added[f.book]) and not restored[f.book] then
      local target = f.first
      if added[f.book] and not f.after_add then target = nil end -- changed before it was added: cannot be
      if added[f.book] and f.after_add then
        -- the value it came with: the (added) row has it, unless a change came first
        local ok, came = pcall(json.decode, added[f.book].new ~= "" and added[f.book].new or "{}")
        if not ok or type(came) ~= "table" then came = {} end
        target = came[f.field] or f.first
      end
      local now = edit.current(book, f.field)
      if target == nil or same(f.field, now, target) then
        -- nothing to do
      elseif f.outside and not opts.exact then
        plan.kept.outside = plan.kept.outside + 1
      elseif not f.unlogged and f.last and not same(f.field, now, f.last) and not opts.exact then
        plan.kept.since = plan.kept.since + 1
      else
        plan.changes[#plan.changes + 1] = { id = f.book, field = f.field, value = target, op = "set" }
        touched[f.book] = true
      end
    end
  end
  for book, r in pairs(removed) do
    if opts.fields then
      -- only fields
    elseif added[book] then
      -- added and removed since: it was never in the library at the snapshot
    elseif r.undone == 1 then
      -- put back already (by undo): the copy it came back as is the book now
    elseif r.label == "outside" and not opts.exact then
      plan.kept.gone[#plan.kept.gone + 1] = book
    else
      plan.restore[#plan.restore + 1] = r
      touched[book] = true
    end
  end
  for book in pairs(restored) do
    if lulibre.book(book) and not opts.fields then
      plan.remove[#plan.remove + 1] = book
      touched[book] = true
    end
  end
  for book, r in pairs(added) do
    if r.label == "outside" and lulibre.book(book) and not opts.unsync then
      plan.kept.unknown_added[#plan.kept.unknown_added + 1] = book
    end
  end
  table.sort(plan.restore, function(a, b) return a.id < b.id end)
  table.sort(plan.remove)
  table.sort(plan.unsync)
  table.sort(plan.kept.unknown_added)
  local n = 0
  for _ in pairs(touched) do n = n + 1 end
  plan.books = n + #dropped
  return plan
end

--- A few lines on what a plan would do.
function M.describe(plan)
  local out = {}
  local function line(...) out[#out + 1] = string.format(...) end
  local s = plan.snap
  line("back to snapshot %d, \"%s\" (%s)", s.id, s.name, os.date("%Y-%m-%d %H:%M", s.ts))
  local books = {}
  for _, c in ipairs(plan.changes) do books[c.id] = true end
  local nb = 0
  for _ in pairs(books) do nb = nb + 1 end
  line("  %d field%s of %d book%s put back", #plan.changes, #plan.changes == 1 and "" or "s", nb, nb == 1 and "" or "s")
  if #plan.restore > 0 then line("  %d removed book%s brought back from calibre's recycle bin", #plan.restore, #plan.restore == 1 and "" or "s") end
  if #plan.remove > 0 then line("  %d book%s put back since removed again", #plan.remove, #plan.remove == 1 and "" or "s") end
  if #plan.unsync > 0 then
    line("  %d book%s added from the sync folder since taken out of the library, the files to %s/", #plan.unsync,
      #plan.unsync == 1 and "" or "s", M.UNSYNCED)
  end
  if #plan.undrop > 0 then line("  %d dropped file%s back in the sync folder", #plan.undrop, #plan.undrop == 1 and "" or "s") end
  if plan.kept.outside > 0 then
    line("  %d field%s changed outside lulibre left as %s (--exact puts them back too)", plan.kept.outside,
      plan.kept.outside == 1 and "" or "s", plan.kept.outside == 1 and "it is" or "they are")
  end
  if plan.kept.since > 0 then
    line("  %d field%s changed again since by means the journal did not see, left alone", plan.kept.since,
      plan.kept.since == 1 and "" or "s")
  end
  if #plan.kept.unknown_added > 0 then
    line("  %d book%s that turned up in calibre since (not added by lulibre) left in the library", #plan.kept.unknown_added,
      #plan.kept.unknown_added == 1 and "" or "s")
  end
  if #plan.kept.gone > 0 then
    line("  %d book%s removed outside lulibre not brought back (--exact tries)", #plan.kept.gone, #plan.kept.gone == 1 and "" or "s")
  end
  if plan.books == 0 then line("  the library is as it was then: nothing to do") end
  return out
end

-- Move a book's files into the sync folder's unsynced/ folder. Returns true,
-- or nil and why.
local function unsync_files(book, from)
  local uv = require "luv"
  local sync = require "lulibre.sync"
  local dir, why = sync.dir()
  if not dir then return nil, why end
  local to = dir .. "/" .. M.UNSYNCED
  uv.fs_mkdir(to, 493)
  local files = lulibre.files(book)
  for _, f in ipairs(files) do
    -- the name it had in the sync folder, when the book came from there with one file
    local name = (#files == 1 and from and from:match("[^/]+$")) or f.path:gsub("^.*/", "")
    local dest, n = to .. "/" .. name, 1
    while uv.fs_stat(dest) do
      n = n + 1
      dest = ("%s/%s (%d)%s"):format(to, name:gsub("%.%w+$", ""), n, name:match("%.%w+$") or "")
    end
    local ok, err = uv.fs_copyfile(f.path, dest)
    if not ok then return nil, ("%s: %s"):format(name, tostring(err)) end
    if lulibre.md5(dest) ~= lulibre.md5(f.path) then return nil, name .. ": the copy differs from the library's" end
  end
  return true
end

--- Put the library back to snapshot `id` (number, name or row). Takes a
-- snapshot first, so that going back to it rolls forward. opts as for plan,
-- and opts.dry: only say what would be done. Returns { before=, plan=,
-- applied=, failed = { {id=, error=} }, restored=, removed=, unsynced= }.
function M.rollback(id, opts)
  opts = opts or {}
  local snap, why = type(id) == "table" and id or M.find(id)
  if not snap then return nil, why end
  M.observe()
  local plan = M.plan(snap, opts)
  local out = { plan = plan, applied = 0, failed = {}, restored = {}, removed = 0, unsynced = 0 }
  if opts.dry or plan.books == 0 then return out end
  out.before = M.take(("before going back to %d \"%s\""):format(snap.id, snap.name), { auto = true })
  local label = ("rollback to %d"):format(snap.id)
  if #plan.changes > 0 then
    local r = edit.apply(plan.changes, { label = label })
    out.applied = r.applied
    for _, f in ipairs(r.failed) do out.failed[#out.failed + 1] = f end
  end
  for _, row in ipairs(plan.restore) do
    local new, err = edit.restore_removed(row, label)
    if new then out.restored[#out.restored + 1] = new end
    if err then out.failed[#out.failed + 1] = { id = row.book, error = err } end
    local fix = new and plan.after_restore[row.book]
    if fix then
      local changes = {}
      for field, value in pairs(fix) do changes[#changes + 1] = { id = new, field = field, value = value, op = "set" } end
      local r = edit.apply(changes, { label = label })
      for _, f in ipairs(r.failed) do out.failed[#out.failed + 1] = f end
    end
  end
  if #plan.remove > 0 then
    local n, err = edit.remove(plan.remove, { label = label })
    out.removed = n
    if err then out.failed[#out.failed + 1] = { id = plan.remove[1], error = err } end
  end
  local leaving = {}
  for _, book in ipairs(plan.unsync) do
    local came = lulibre.sql("SELECT old FROM journal WHERE book = ? AND field = '(added)' ORDER BY id LIMIT 1", book)[1]
    local ok, err = unsync_files(book, came and came.old ~= "" and came.old or nil)
    if ok then leaving[#leaving + 1] = book else out.failed[#out.failed + 1] = { id = book, error = err } end
  end
  if #leaving > 0 then
    local n, err = edit.remove(leaving, { label = "unsync (" .. label .. ")" })
    out.unsynced = n
    if err then out.failed[#out.failed + 1] = { id = leaving[1], error = err } end
  end
  if #plan.undrop > 0 then
    local sync = require "lulibre.sync"
    for _, row in ipairs(plan.undrop) do
      local back, err = sync.undrop(json.decode(row.old))
      if back then lulibre.store("UPDATE journal SET undone = 1, new = 'put back' WHERE id = ?", row.id)
      else out.failed[#out.failed + 1] = { id = row.book, error = err } end
    end
    lulibre.stage_refresh()
  end
  M.observe()
  return out
end

--- One line about what rollback() did.
function M.summary(out)
  local parts = {}
  if out.applied > 0 then parts[#parts + 1] = ("%d book%s put back"):format(out.applied, out.applied == 1 and "" or "s") end
  if #out.restored > 0 then parts[#parts + 1] = ("%d brought back from the recycle bin"):format(#out.restored) end
  if out.removed > 0 then parts[#parts + 1] = ("%d removed again"):format(out.removed) end
  if out.unsynced > 0 then parts[#parts + 1] = ("%d taken out to %s/"):format(out.unsynced, M.UNSYNCED) end
  if #out.failed > 0 then parts[#parts + 1] = ("%d failed: %s"):format(#out.failed, tostring(out.failed[1].error)) end
  local s = #parts > 0 and table.concat(parts, ", ") or "nothing to do: the library is as it was then"
  if out.before then s = s .. (" (snapshot %d is how it was before: going back to it rolls forward)"):format(out.before.id) end
  return s
end

-- ---- a snapshot from a copy of calibre's database ----

--- A snapshot from another copy of calibre's metadata.db (one kept from
-- before lulibre, say). It is placed in the journal where that copy's
-- time falls (its newest change); where the copy differs from what the
-- journal says the library was then, those values go with the snapshot.
-- Returns the snapshot's row and { values=, gone=, since= } counts.
function M.import(path, name)
  local theirs = lulibre.calibre_books(path)
  if #theirs == 0 then return nil, path .. " holds no books" end
  local newest = ""
  for _, r in ipairs(theirs) do
    if (r.modified or "") > newest then newest = r.modified end
  end
  local at = lulibre.sql("SELECT CAST(strftime('%s', ?) AS INTEGER) AS t", newest)[1].t or 0
  M.observe()
  local upto = lulibre.sql("SELECT coalesce(max(id), 0) AS n FROM journal WHERE ts <= ?", at)[1].n
  -- the library at that point, by the journal: now, less every change since
  local rows = lulibre.sql([[SELECT book, field, old FROM journal WHERE id > ? AND status = 'applied'
    ORDER BY id]], upto)
  local was, gone_since = {}, {}
  for _, r in ipairs(rows) do
    if r.field == M.REMOVED then gone_since[r.book] = r.old
    elseif not r.field:find("^%(") then
      local k = key(r.book, r.field)
      if was[k] == nil then was[k] = r.old or "" end
    end
  end
  local diffs, missing = {}, 0
  for _, r in ipairs(theirs) do
    local v = M.values(r)
    local book = lulibre.book(r.id)
    local then_
    if book then
      then_ = {}
      for _, f in ipairs(M.fields) do then_[f] = edit.current(book, f) end
    elseif gone_since[r.id] then
      then_ = json.decode(gone_since[r.id])
    end
    if then_ then
      local logged = {}
      for _, f in ipairs(M.fields) do
        logged[f] = was[key(r.id, f)]
        if logged[f] == nil then logged[f] = then_[f] or "" end
      end
      -- a series index means nothing without a series (either side)
      if v.series == "" or logged.series == "" then logged.series_index = v.series_index end
      for _, f in ipairs(M.fields) do
        if v[f] ~= logged[f] then diffs[#diffs + 1] = { r.id, f, v[f] } end
      end
    else
      missing = missing + 1
    end
  end
  local snap = M.take(name or ("from " .. path:gsub("^.*/", "")), {
    upto = upto, ts = at, note = ("imported from %s (%d books); %d values the journal did not see; %d books it has that are gone without a trace in the journal")
      :format(path, #theirs, #diffs, missing) })
  for _, d in ipairs(diffs) do
    lulibre.store("INSERT INTO snapshot_values(snap, book, field, value) VALUES(?, ?, ?, ?)", snap.id, d[1], d[2], d[3])
  end
  return snap, { values = #diffs, gone = missing, books = #theirs }
end

return M
