--- Marks points in the library's history and puts the library back to them.
--
-- The journal holds every change: each field lulibre wrote with its old value;
-- each book removed, added, restored or dropped; and what changed in calibre by
-- other means, which lulibre finds each time it reads calibre's records, in batches
-- labelled "outside". A snapshot is only a position in the journal. No copy of the
-- library is kept.
--
-- A rollback puts the library back to a snapshot. For every field changed since,
-- it works out the old value and writes it like any other change, so the journal
-- records it and :undo can reverse it:
--
-- - a field lulibre changed goes back to its old value;
-- - a field changed outside lulibre stays as it is, unless `exact`;
-- - a field changed again by means the journal did not see is left alone and counted;
-- - a book added from the sync folder since goes back to how it was when added. With
--   `unsync`, it leaves the library instead, its files to the sync folder's unsynced/;
-- - a book removed since comes back from calibre's recycle bin, and a book restored
--   since is removed again; `fields` leaves all of those.
--
-- Before writing anything a rollback takes its own snapshot, so going back to that
-- one rolls forward again. `import` makes a snapshot from an older calibre database;
-- it also holds the values where that differs from what the journal says the library
-- was then, which count as changes made outside lulibre.
--
-- @library lulib._snapshots
local bookman = require "bookman"
local json = require "dkjson"
local luv = require "luv"
local sql = require "sql"
local sqlite3 = require "lsqlite3"
local store = require "store"

local M = {}

--- The fields a snapshot puts back.
M.fields = { "title", "authors", "tags", "series", "series_index", "publisher", "pubdate", "languages", "identifiers" }
M.ADDED, M.REMOVED, M.RESTORED, M.DROPPED = "(added)", "(removed)", "(restored)", "(dropped)"
--- The folder under the sync folder where books taken out of the library go.
M.UNSYNCED = "unsynced"

local db
local function run(query, ...)
  db = db or sql.open(setman.get("path.journaldb"), sqlite3.OPEN_READWRITE)
  return sql.run(db, query, ...)
end

local function last_row()
  return run("SELECT coalesce(max(id), 0) AS n FROM journal")[1].n
end

--- Takes a snapshot of the library as it is now, once calibre's records are read.
-- @tparam[opt] string name by default the time
-- @tparam[opt] table o `{ ts=, upto=, auto=, note= }`
-- @treturn table the row
function M.take(name, o)
  o = o or {}
  store.reload()
  name = name and name:match("^%s*(.-)%s*$") or ""
  if name == "" then name = os.date("%Y-%m-%d %H:%M") end
  run("INSERT INTO snapshots(name, ts, upto, auto, note) VALUES (?, ?, ?, ?, ?)", name, o.ts or os.time(), o.upto or last_row(),
      o.auto and 1 or 0, o.note)
  return run("SELECT * FROM snapshots ORDER BY id DESC LIMIT 1")[1]
end

--- The snapshots, newest first, each with how many books and fields have changed
-- since.
-- @tparam[opt] table o `{ all = true }`: the retired too
function M.list(o)
  return run("SELECT s.*, (SELECT count(DISTINCT j.book) FROM journal j WHERE j.id > s.upto AND j.state IN (2, 4) AND j.field IS NOT NULL) AS books,"
             .. " (SELECT count(*) FROM journal j WHERE j.id > s.upto AND j.state IN (2, 4) AND j.field IS NOT NULL) AS changes"
             .. " FROM snapshots s WHERE ? OR s.retired IS NULL ORDER BY s.upto DESC, s.id DESC", o and o.all and 1 or 0)
end

--- A snapshot by number or name (the newest with that name), or nil and why.
function M.find(what)
  what = tostring(what or ""):match("^%s*(.-)%s*$")
  if what == "" then return nil, "which snapshot? (:snapshots lists them)" end
  local row = tonumber(what) and run("SELECT * FROM snapshots WHERE id = ?", tonumber(what))[1]
    or run("SELECT * FROM snapshots WHERE name = ? ORDER BY id DESC LIMIT 1", what)[1]
  if not row then return nil, ("no snapshot '%s' (:snapshots lists them)"):format(what) end
  return row
end

--- Retires a snapshot, or with on false brings it back. Nothing is lost.
function M.retire(id, on)
  run("UPDATE snapshots SET retired = ? WHERE id = ?", on ~= false and os.time() or nil, id)
end

local function key(book, field) return book .. "\0" .. field end

-- two values of a field the same? calibre keeps one spelling of an author or tag
local function same(field, a, b)
  if field == "authors" or field == "tags" then return (a or ""):lower() == (b or ""):lower() end
  return a == b
end

--- What putting the library back to a snapshot would do. Writes nothing.
-- @param id a number, name or row
-- @tparam[opt] table o `{ exact=, unsync=, fields= }`
-- @treturn table `{ snap=, changes = { {book=, field=, value=, op="set"} }, restore = { journal rows },
-- remove = { ids }, unsync = { ids }, undrop = { batches }, after_restore=,
-- kept = { outside=, since=, unknown_added = { ids }, gone = { ids } }, books= }`
function M.plan(id, o)
  o = o or {}
  local snap = type(id) == "table" and id or assert(M.find(id))
  local rows = run("SELECT id, batch, book, field, old, new, label, state FROM journal WHERE id > ? AND state IN (2, 4)"
                   .. " AND field IS NOT NULL ORDER BY id", snap.upto)
  local fixed = {}
  for _, r in ipairs(run("SELECT book, field, value FROM snapshot_values WHERE snap = ?", snap.id)) do
    fixed[key(r.book, r.field)] = r.value
  end
  local fields, order = {}, {} -- key -> { book=, field=, first=, last=, outside= }
  local added, removed, restored, dropped = {}, {}, {}, {}
  local batch_fields = {}
  for _, r in ipairs(rows) do
    if r.field == M.ADDED then
      added[r.book] = added[r.book] or r
    elseif r.field == M.REMOVED then
      removed[r.book] = r
    elseif r.field == M.RESTORED then
      restored[r.book] = r
    elseif r.field == M.DROPPED then
      if r.state == 2 then dropped[r.batch] = true end
    elseif r.field:sub(1, 1) ~= "(" then
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
      batch_fields[r.batch] = true
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
  local plan = { snap = snap, changes = {}, restore = {}, remove = {}, unsync = {}, undrop = {}, after_restore = {},
                 kept = { outside = 0, since = 0, unknown_added = {}, gone = {} } }
  if not o.fields then
    for batch in pairs(dropped) do
      -- a file moved in with its book comes back by the book's own batch
      local moved = false
      for _, r in ipairs(rows) do
        if r.batch == batch and r.field == M.ADDED then moved = true end
      end
      if not moved then plan.undrop[#plan.undrop + 1] = batch end
    end
  end
  local touched = {}
  for book in pairs(added) do
    if book > 0 and bookman.get(book) then
      if o.unsync and not o.fields then plan.unsync[#plan.unsync + 1] = book end
      touched[book] = true
    end
  end
  for _, k in ipairs(order) do
    local f = fields[k]
    if removed[f.book] and not added[f.book] and not (f.outside and not o.exact) then
      -- a book removed since comes back as calibre kept it then; this puts its fields back too
      plan.after_restore[f.book] = plan.after_restore[f.book] or {}
      plan.after_restore[f.book][f.field] = f.first
    end
    local here = not removed[f.book] and bookman.get(f.book)
    if here and not (o.unsync and added[f.book]) and not restored[f.book] then
      local target = f.first
      if added[f.book] and not f.after_add then target = nil end -- changed before it was added: cannot be
      if added[f.book] and f.after_add then
        -- the value it came with: the (added) row has it, unless a change came first
        local came = json.decode(added[f.book].new ~= "" and added[f.book].new or "{}") or {}
        target = came[f.field] or f.first
      end
      local now = bookman.get(f.book, f.field) or ""
      if target == nil or same(f.field, now, target) then
        -- nothing to do
      elseif f.outside and not o.exact then
        plan.kept.outside = plan.kept.outside + 1
      elseif not f.unlogged and f.last and not same(f.field, now, f.last) and not o.exact then
        plan.kept.since = plan.kept.since + 1
      else
        plan.changes[#plan.changes + 1] = { book = f.book, field = f.field, value = target, op = "set" }
        touched[f.book] = true
      end
    end
  end
  for book, r in pairs(removed) do
    if o.fields then
      -- only fields
    elseif added[book] then
      -- added and removed since: it was never in the library at the snapshot
    elseif r.state == 4 then
      -- put back already (by undo): the copy it came back as is the book now
    elseif r.label == "outside" and not o.exact then
      plan.kept.gone[#plan.kept.gone + 1] = book
    else
      plan.restore[#plan.restore + 1] = r
      touched[book] = true
    end
  end
  for book in pairs(restored) do
    if bookman.get(book) and not o.fields then
      plan.remove[#plan.remove + 1] = book
      touched[book] = true
    end
  end
  for book, r in pairs(added) do
    if r.label == "outside" and bookman.get(book) and not o.unsync then
      plan.kept.unknown_added[#plan.kept.unknown_added + 1] = book
    end
  end
  table.sort(plan.restore, function(a, b) return a.id < b.id end)
  table.sort(plan.remove)
  table.sort(plan.unsync)
  table.sort(plan.kept.unknown_added)
  local n = 0
  for _ in pairs(touched) do n = n + 1 end
  plan.books = n + #plan.undrop
  return plan
end

--- A few lines about what a plan would do.
function M.describe(plan)
  local out = {}
  local function line(...) out[#out + 1] = string.format(...) end
  local function s_(n) return n == 1 and "" or "s" end
  local s = plan.snap
  line("back to snapshot %d, \"%s\" (%s)", s.id, s.name, os.date("%Y-%m-%d %H:%M", s.ts))
  local books, nb = {}, 0
  for _, c in ipairs(plan.changes) do
    if not books[c.book] then
      books[c.book] = true
      nb = nb + 1
    end
  end
  line("  %d field%s of %d book%s put back", #plan.changes, s_(#plan.changes), nb, s_(nb))
  if #plan.restore > 0 then line("  %d removed book%s brought back from calibre's recycle bin", #plan.restore, s_(#plan.restore)) end
  if #plan.remove > 0 then line("  %d book%s put back since removed again", #plan.remove, s_(#plan.remove)) end
  if #plan.unsync > 0 then
    line("  %d book%s added from the sync folder since taken out of the library, the files to %s/", #plan.unsync, s_(#plan.unsync), M.UNSYNCED)
  end
  if #plan.undrop > 0 then line("  %d batch%s of dropped files back in the sync folder", #plan.undrop, #plan.undrop == 1 and "" or "es") end
  if plan.kept.outside > 0 then
    line("  %d field%s changed outside lulibre left as %s (exact puts them back too)", plan.kept.outside, s_(plan.kept.outside),
         plan.kept.outside == 1 and "it is" or "they are")
  end
  if plan.kept.since > 0 then
    line("  %d field%s changed again since by means the journal did not see, left alone", plan.kept.since, s_(plan.kept.since))
  end
  if #plan.kept.unknown_added > 0 then
    line("  %d book%s that turned up in calibre since (not added by lulibre) left in the library", #plan.kept.unknown_added, s_(#plan.kept.unknown_added))
  end
  if #plan.kept.gone > 0 then
    line("  %d book%s removed outside lulibre not brought back (exact tries)", #plan.kept.gone, s_(#plan.kept.gone))
  end
  if plan.books == 0 then line("  the library is as it was then: nothing to do") end
  return out
end

-- copies a book's files into the sync folder's unsynced/; true, or nil and why
local function unsync_files(book, from)
  local dir = setman.get("path.sync") or ""
  if dir == "" then return nil, "no sync folder is set" end
  local to = dir:gsub("/+$", "") .. "/" .. M.UNSYNCED
  luv.fs_mkdir(to, 493)
  local files = bookman.files(book) or {}
  for _, f in ipairs(files) do
    -- the name it had in the sync folder, when the book came from there with one file
    local name = (#files == 1 and from and from:match("[^/]+$")) or f.path:gsub("^.*/", "")
    local dest, n = to .. "/" .. name, 1
    while luv.fs_stat(dest) do
      n = n + 1
      dest = ("%s/%s (%d)%s"):format(to, name:gsub("%.%w+$", ""), n, name:match("%.%w+$") or "")
    end
    local ok, err = luv.fs_copyfile(f.path, dest)
    if not ok then return nil, ("%s: %s"):format(name, tostring(err)) end
    if utils.md5(dest) ~= utils.md5(f.path) then return nil, name .. ": the copy differs from the library's" end
  end
  return true
end

--- Puts the library back to a snapshot. First takes a new snapshot, so going back
-- to that one rolls forward.
-- @param id a number, name or row
-- @tparam[opt] table o as for `plan`
-- @treturn table `{ before=, plan=, applied=, failed = { {book=, error=} }, restored=, removed=, unsynced= }`,
-- or nil and why
function M.rollback(id, o)
  o = o or {}
  local snap, why = type(id) == "table" and id or M.find(id)
  if not snap then return nil, why end
  store.reload()
  local plan = M.plan(snap, o)
  local out = { plan = plan, applied = 0, failed = {}, restored = {}, removed = 0, unsynced = 0 }
  if plan.books == 0 then return out end
  out.before = M.take(("before going back to %d \"%s\""):format(snap.id, snap.name), { auto = true })
  local label = ("rollback to %d"):format(snap.id)
  if #plan.changes > 0 then
    local batch, err = store.apply(plan.changes, label)
    if err then out.failed[#out.failed + 1] = { book = plan.changes[1].book, error = err }
    elseif batch then out.applied = #plan.changes end
  end
  for _, row in ipairs(plan.restore) do
    local new, err = require("lulib._remove").restore_one(row)
    if new then
      out.restored[#out.restored + 1] = new
      local fix = plan.after_restore[row.book]
      if fix then
        local changes = {}
        for field, value in pairs(fix) do changes[#changes + 1] = { book = new, field = field, value = value, op = "set" } end
        store.reload()
        local _, e = store.apply(changes, label)
        if e then out.failed[#out.failed + 1] = { book = new, error = e } end
      end
    end
    if err then out.failed[#out.failed + 1] = { book = row.book, error = err } end
  end
  if #plan.remove > 0 then
    local b, err = store.remove(plan.remove, label)
    if b then out.removed = #plan.remove else out.failed[#out.failed + 1] = { book = plan.remove[1], error = err } end
  end
  local leaving = {}
  for _, book in ipairs(plan.unsync) do
    local came = run("SELECT old FROM journal WHERE book = ? AND field = '(added)' ORDER BY id LIMIT 1", book)[1]
    local ok, err = unsync_files(book, came and came.old ~= "" and came.old or nil)
    if ok then leaving[#leaving + 1] = book else out.failed[#out.failed + 1] = { book = book, error = err } end
  end
  if #leaving > 0 then
    local b, err = store.remove(leaving, "unsync (" .. label .. ")")
    if b then out.unsynced = #leaving else out.failed[#out.failed + 1] = { book = leaving[1], error = err } end
  end
  for _, batch in ipairs(plan.undrop) do
    local ok, err = store.undo(batch)
    if not ok then out.failed[#out.failed + 1] = { book = 0, error = err } end
  end
  store.reload()
  return out
end

--- One line about what `rollback` did.
function M.summary(out)
  local parts = {}
  if out.applied > 0 then parts[#parts + 1] = ("%d field%s put back"):format(out.applied, out.applied == 1 and "" or "s") end
  if #out.restored > 0 then parts[#parts + 1] = ("%d brought back from the recycle bin"):format(#out.restored) end
  if out.removed > 0 then parts[#parts + 1] = ("%d removed again"):format(out.removed) end
  if out.unsynced > 0 then parts[#parts + 1] = ("%d taken out to %s/"):format(out.unsynced, M.UNSYNCED) end
  if #out.failed > 0 then parts[#parts + 1] = ("%d failed: %s"):format(#out.failed, tostring(out.failed[1].error)) end
  local s = #parts > 0 and table.concat(parts, ", ") or "nothing to do: the library is as it was then"
  if out.before then s = s .. (" (snapshot %d is how it was before: going back to it rolls forward)"):format(out.before.id) end
  return s
end

-- a list in the journal's form, sorted
local function sorted(text, sep)
  local items = {}
  for item in ((text or "") .. sep):gmatch("(.-)" .. sep) do
    if item ~= "" then items[#items + 1] = item end
  end
  table.sort(items)
  return table.concat(items, ", ")
end

--- The books of a copy of calibre's metadata.db, as the journal keeps values:
-- `{ {id=, modified=, values = { [field] = value }}, ... }`.
function M.books_of(path)
  local cal = sql.open(path, sqlite3.OPEN_READONLY)
  local rows = sql.run(cal, [[SELECT b.id, b.title, b.series_index, b.last_modified AS modified,
      CASE WHEN b.pubdate IS NULL OR substr(b.pubdate, 1, 4) < '0102' THEN '' ELSE substr(b.pubdate, 1, 10) END AS pubdate,
      (SELECT group_concat(a.name, ' & ') FROM books_authors_link l JOIN authors a ON a.id = l.author WHERE l.book = b.id) AS authors,
      (SELECT group_concat(t.name, '|') FROM books_tags_link l JOIN tags t ON t.id = l.tag WHERE l.book = b.id) AS tags,
      (SELECT s.name FROM books_series_link l JOIN series s ON s.id = l.series WHERE l.book = b.id) AS series,
      (SELECT p.name FROM books_publishers_link l JOIN publishers p ON p.id = l.publisher WHERE l.book = b.id) AS publisher,
      (SELECT group_concat(g.lang_code, '|') FROM books_languages_link l JOIN languages g ON g.id = l.lang_code WHERE l.book = b.id) AS languages,
      (SELECT group_concat(i.type || ':' || i.val, '|') FROM identifiers i WHERE i.book = b.id) AS idents
    FROM books b]])
  cal:close()
  local out = {}
  for i, r in ipairs(rows) do
    local series = r.series or ""
    out[i] = { id = r.id, modified = r.modified, values = {
      title = r.title or "", authors = (r.authors == "Unknown" and "" or r.authors) or "", tags = sorted(r.tags, "|"), series = series,
      series_index = series ~= "" and r.series_index and ("%.10g"):format(r.series_index) or "",
      publisher = r.publisher or "", pubdate = r.pubdate or "", languages = sorted(r.languages, "|"), identifiers = sorted(r.idents, "|"),
    } }
  end
  return out
end

--- A snapshot from another copy of calibre's metadata.db, such as one kept from
-- before lulibre, placed in the journal at the copy's time. Where the copy differs
-- from what the journal says the library was then, its values go with the snapshot.
-- @tparam string path
-- @tparam[opt] string name
-- @treturn table the row, and `{ values=, gone=, books= }`; or nil and why
function M.import(path, name)
  local ok, theirs = pcall(M.books_of, path)
  if not ok then return nil, tostring(theirs) end
  if #theirs == 0 then return nil, path .. " holds no books" end
  local newest = ""
  for _, r in ipairs(theirs) do
    if (r.modified or "") > newest then newest = r.modified end
  end
  local at = run("SELECT CAST(strftime('%s', ?) AS INTEGER) AS t", newest)[1].t or 0
  store.reload()
  local upto = run("SELECT coalesce(max(id), 0) AS n FROM journal WHERE ts <= ?", at)[1].n
  -- the library at that point, by the journal: now, less every change since
  local was, gone_since = {}, {}
  for _, r in ipairs(run("SELECT book, field, old FROM journal WHERE id > ? AND state IN (2, 4) AND field IS NOT NULL ORDER BY id", upto)) do
    if r.field == M.REMOVED then gone_since[r.book] = r.old
    elseif not r.field:find("^%(") then
      local k = key(r.book, r.field)
      if was[k] == nil then was[k] = r.old or "" end
    end
  end
  local diffs, missing = {}, 0
  for _, r in ipairs(theirs) do
    local then_
    if bookman.get(r.id) then
      then_ = {}
      for _, f in ipairs(M.fields) do then_[f] = bookman.get(r.id, f) or "" end
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
      if r.values.series == "" or logged.series == "" then logged.series_index = r.values.series_index end
      for _, f in ipairs(M.fields) do
        if r.values[f] ~= logged[f] then diffs[#diffs + 1] = { r.id, f, r.values[f] } end
      end
    else
      missing = missing + 1
    end
  end
  local snap = M.take(name or ("from " .. path:gsub("^.*/", "")), {
    upto = upto, ts = at,
    note = ("imported from %s (%d books); %d values the journal did not see; %d books it has no trace of"):format(path, #theirs, #diffs, missing) })
  for _, d in ipairs(diffs) do
    run("INSERT INTO snapshot_values(snap, book, field, value) VALUES (?, ?, ?, ?)", snap.id, d[1], d[2], d[3])
  end
  return snap, { values = #diffs, gone = missing, books = #theirs }
end

local function when(ts) return os.date("%Y-%m-%d %H:%M", ts) end

scrnman.create("snapshots", {
  actions = {
    { "back", "<CR>", "go back to this snapshot (asks first)" },
    { "take", "n", "take a snapshot now" },
    { "retire", "d", "take it out of the list, or bring it back" },
    { "exact", "x", "going back: changes made outside lulibre too" },
    { "unsync", "U", "going back: books added from the sync folder leave the library" },
    { "fields", "F", "going back: fields only" },
    { "all", "a", "the retired too" },
  },
  hint = { "back", "take", "retire", "exact", "unsync" },
})

--- What the panel in the list's place shows for a snapshot: rows of `{ label, text, style= }`.
function M.context(snap, plan)
  local rows = { { ("snapshot %d"):format(snap.id), snap.name, style = "head" },
                 { "taken", when(snap.ts) .. (snap.auto == 1 and "   (by a rollback: going back to it rolls forward)" or "") } }
  if snap.note and snap.note ~= "" then rows[#rows + 1] = { "note", snap.note, style = "dim" } end
  if snap.retired then rows[#rows + 1] = { "retired", when(snap.retired), style = "dim" } end
  rows[#rows + 1] = { "since", ("%d changes on %d books"):format(snap.changes or 0, snap.books or 0) }
  rows[#rows + 1] = { "" }
  for i, line in ipairs(M.describe(plan)) do
    rows[#rows + 1] = { i == 1 and "going back" or "", (line:gsub("^%s+", "")), style = i == 1 and "head" or nil }
  end
  local seen, n = {}, 0
  for _, c in ipairs(plan.changes) do
    if not seen[c.book] and n < 12 then
      seen[c.book] = true
      n = n + 1
      rows[#rows + 1] = { n == 1 and "for example" or "", ("%d  %s: %s → %s"):format(c.book, bookman.get(c.book, "title") or "?",
        c.field, c.value == "" and "(blank)" or c.value:sub(1, 50)), style = "dim" }
    end
  end
  return rows
end

--- Opens the browser.
function M.open()
  local flags, all, list = { exact = false, unsync = false, fields = false }, false, {}
  local function load()
    store.reload()
    list = M.list { all = all }
  end
  local function rows()
    local out = {}
    for _, s in ipairs(list) do
      out[#out + 1] = { tostring(s.id), when(s.ts), s.name, ("%d on %d books"):format(s.changes, s.books),
                        (s.auto == 1 and "rollback " or "") .. (s.retired and "retired" or ""), style = s.retired and "dim" or nil }
    end
    if #out == 0 then out[1] = { "", "", "no snapshots yet: n takes one", "", "" } end
    return out
  end
  local function title()
    local on = {}
    for _, f in ipairs { "exact", "unsync", "fields" } do
      if flags[f] then on[#on + 1] = f end
    end
    return ("snapshots   %d%s   going back: %s"):format(#list, all and " (with the retired)" or "",
                                                         #on > 0 and table.concat(on, " ") or "lulibre's changes only")
  end
  load()
  local p <close> = uiman.panel {
    title = title(), screen = "snapshots", height = 0.35, moves = true, rows = rows(),
    columns = { { "#", 5 }, { "taken", 17 }, { "name", -2 }, { "changed since", 22 }, { "", 16 } },
  }
  local ctx <close> = uiman.panel { side = "main", title = "going back to this snapshot", focus = false,
                                    columns = { { "", 14 }, { "", -1 } }, rows = {} }
  local function about(row)
    local snap = list[row]
    if not snap then return ctx:rows {} end
    local ok, plan = pcall(M.plan, snap, flags)
    local r
    if ok then ok, r = pcall(M.context, snap, plan) else r = plan end
    ctx:rows(ok and r or { { "", tostring(r), style = "error" } })
  end
  about(1)
  local cur = 1
  while true do
    local act, row = p:wait()
    if not act then return end
    cur = row or cur
    local snap = list[cur]
    if act == "<Move>" then
      about(cur)
    else
      if act == "take" then
        local name = uiman.input { prompt = "name for the snapshot (empty: the time): " }
        if name then
          local s = M.take(name)
          uiman.notify(("took snapshot %d, \"%s\""):format(s.id, s.name))
          load()
          cur = 1
        end
      elseif act == "exact" or act == "unsync" or act == "fields" then
        flags[act] = not flags[act]
      elseif act == "all" then
        all = not all
        load()
      elseif snap and act == "retire" then
        M.retire(snap.id, not snap.retired)
        uiman.notify(("snapshot %d %s"):format(snap.id, snap.retired and "back in the list" or "retired"))
        load()
      elseif snap and act == "back" then
        local plan = M.plan(snap, flags)
        if plan.books == 0 then
          uiman.notify("the library is as it was then: nothing to do")
        else
          local answer = uiman.input { prompt = ("go back to snapshot %d, \"%s\"? as shown (y/N) "):format(snap.id, snap.name) }
          if answer and answer:lower():sub(1, 1) == "y" then
            uiman.progress("going back")
            local out = M.rollback(snap, flags)
            uiman.progress(nil)
            uiman.notify(M.summary(out), #out.failed > 0 and "error" or nil)
            load()
            cur = 1
          end
        end
      end
      p:rows(rows())
      p:title(title())
      if cur > #list then cur = math.max(1, #list) end
      p:cursor(cur)
      about(cur)
    end
  end
end

return M
