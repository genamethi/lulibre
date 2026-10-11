-- The sync folder: files waiting to be added to the library.
--
-- Each ebook file under lulibre.o.sync_dir is "staged": it has a row in the
-- index's `staged` table holding the metadata it will be added to calibre
-- with, and is shown as a book with a negative id, so the list, filters,
-- preview, edit form, capture, proposals and review all work on it as they
-- do on library books (edits change the staged row; nothing reaches calibre).
-- add() then hands the files to calibre with that metadata, and can delete
-- them from the folder once calibre holds the same bytes.
local bib = require "lulibre.bib"
local dupes = require "lulibre.dupes"
local edit = require "lulibre.edit"
local uv = require "luv"

local M = {}

local EXT = { pdf = true, djvu = true, djv = true, epub = true, mobi = true, azw3 = true, fb2 = true,
  cbz = true, txt = true, ps = true }

--- The sync folder, or nil and why not.
function M.dir()
  local dir = lulibre.o.sync_dir
  if dir == "" then return nil, 'no sync folder is set (lulibre.o.sync_dir = "~/some/folder" in init.lua)' end
  dir = (uv.fs_realpath(dir) or dir):gsub("/+$", "")
  local st = uv.fs_stat(dir)
  if not st or st.type ~= "directory" then return nil, dir .. " is not a folder" end
  return dir
end

local function files_under(dir)
  local out = {}
  local function visit(d)
    local req = uv.fs_scandir(d)
    if not req then return end
    while true do
      local name, kind = uv.fs_scandir_next(req)
      if not name then break end
      local path = d .. "/" .. name
      if kind == "directory" then
        if name:sub(1, 1) ~= "." then visit(path) end
      elseif kind == "file" and EXT[(name:match("%.(%w+)$") or ""):lower()] then
        out[#out + 1] = path
      end
    end
  end
  visit(dir)
  table.sort(out)
  return out
end

local function stem(path)
  return (path:gsub("^.*/", ""):gsub("%.%w+$", ""):gsub("_+", " "))
end

--- Bring the staged table in line with the folder: new files are staged
-- (with the metadata of a .bib beside them, if one names them; else titled
-- by file name), vanished ones dropped, and each is checked against the
-- library by content. Waits. Returns { total=, new=, gone=, held= } where
-- held counts files the library already has, and the ids of the new ones.
function M.scan()
  local dir, why = M.dir()
  if not dir then error(why, 0) end
  local on_disk = files_under(dir)
  local staged = {}
  for _, row in ipairs(lulibre.store("SELECT id, path, size, mtime FROM staged")) do staged[row.path] = row end

  -- metadata that came with the files
  local sidecar, seen = {}, {}
  for _, path in ipairs(on_disk) do
    local d = path:match("^(.*)/[^/]*$")
    if not seen[d] then
      seen[d] = true
      for file, known in pairs(bib.sidecar(d)) do sidecar[file] = known end
    end
  end

  local new, present, now = {}, {}, os.time()
  for _, path in ipairs(on_disk) do
    present[path] = true
    local st = uv.fs_stat(path)
    local row = staged[path]
    if st and not row then
      local m = (sidecar[path] or {}).meta or {}
      local _, _, id = lulibre.store([[INSERT INTO staged(path, size, mtime, title, authors, tags, series,
          series_index, publisher, pubdate, idents, added, note)
        VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)]], path, st.size, st.mtime.sec, m.title or stem(path),
        m.authors, m.tags, m.series, m.series_index and tonumber(m.series_index),
        m.publisher, m.pubdate and #m.pubdate == 4 and (m.pubdate .. "-01-01") or m.pubdate,
        m.identifiers and #m.identifiers > 0 and table.concat(m.identifiers, ", ") or nil, now,
        sidecar[path] and ("metadata from " .. sidecar[path].bib:gsub("^.*/", "")) or nil)
      new[#new + 1] = -id
    elseif st and (row.size ~= st.size or row.mtime ~= st.mtime.sec) then
      lulibre.store("UPDATE staged SET size = ?, mtime = ? WHERE id = ?", st.size, st.mtime.sec, row.id)
    end
  end
  local gone = 0
  for path, row in pairs(staged) do
    -- only files of this folder: a row from a previous sync folder goes too
    if not present[path] then
      lulibre.store("DELETE FROM staged WHERE id = ?", row.id)
      gone = gone + 1
    end
  end

  -- which of them the library already holds, byte for byte
  local rows = lulibre.store("SELECT id, path, twin FROM staged")
  lulibre.each(rows, function(row)
    local twin = dupes.twin(row.path)
    if twin ~= row.twin then
      lulibre.store("UPDATE staged SET twin = ? WHERE id = ?", twin, row.id)
      row.twin = twin
    end
  end, { progress = "comparing with the library" })
  local held = 0
  for _, row in ipairs(rows) do
    if row.twin then held = held + 1 end
  end

  lulibre.stage_refresh()
  lulibre.reload()
  return { dir = dir, total = #rows, new = #new, gone = gone, held = held, new_ids = new }
end

-- which staged column holds a field
local COLUMN = { title = "title", authors = "authors", tags = "tags", series = "series",
  series_index = "series_index", publisher = "publisher", pubdate = "pubdate", identifiers = "idents",
  languages = "languages" }

--- Store edited fields of a staged file: fields is { {field=, new=}, ... }.
-- The caller refreshes (lulibre.stage_refresh) once it has written them all.
function M.write(id, fields)
  for _, f in ipairs(fields) do
    local col = COLUMN[f.field] or error("staged files have no field " .. tostring(f.field))
    local value = f.new
    if value == "" then value = nil end
    if col == "series_index" then value = tonumber(value) end
    lulibre.store(("UPDATE staged SET %s = ? WHERE id = ?"):format(col), value, -id)
  end
end

local function staged_row(id)
  return lulibre.store("SELECT * FROM staged WHERE id = ?", -id)[1]
end

--- Add staged files to the library: ids are staged (negative) ids.
-- opts.remove deletes each file from the sync folder once calibre holds the
-- same bytes. A file the library already has is not added again. Waits.
-- Returns { added=, held=, removed=, kept = { "why", ... }, failed = { "why", ... } }.
function M.add(ids, opts)
  opts = opts or {}
  local out = { added = 0, held = 0, removed = 0, kept = {}, failed = {} }
  local jobs = {}
  for _, id in ipairs(ids) do
    local row = id < 0 and staged_row(id)
    local book = row and lulibre.book(id)
    if book then jobs[#jobs + 1] = { id = id, row = row, book = book } end
  end

  -- calibredb add has no option for these; they follow as ordinary changes
  local follow = {}
  lulibre.each(jobs, function(job)
    local book, row = job.book, job.row
    job.twin = dupes.twin(row.path)
    if job.twin then
      job.library_id = job.twin
      return
    end
    local args = edit.calibredb()
    local function opt(flag, value)
      if value and value ~= "" then
        args[#args + 1] = flag
        args[#args + 1] = tostring(value)
      end
    end
    args[#args + 1] = "add"
    args[#args + 1] = "--duplicates" -- lulibre has compared the bytes itself
    opt("--title", book.title)
    opt("--authors", edit.current(book, "authors"))
    opt("--tags", edit.current(book, "tags"))
    opt("--series", book.series)
    if book.series then opt("--series-index", edit.current(book, "series_index")) end
    opt("--languages", book.lang)
    for kind, value in pairs(book.idents) do opt("--identifier", kind .. ":" .. value) end
    args[#args + 1] = row.path
    local r, err = lulibre.system(args, { timeout = 300000 })
    local text = r and (r.stdout .. r.stderr) or ""
    local new_id = r and r.code == 0 and tonumber(text:match("Added book ids:%s*(%d+)"))
    if new_id then
      job.library_id, job.added = new_id, true
      for _, field in ipairs { "pubdate", "publisher" } do
        local value = edit.current(book, field)
        if value ~= "" then table.insert(follow, { id = new_id, field = field, value = value }) end
      end
    else
      job.error = err or text:match("[^\n]*%s*$") or "calibredb add failed"
    end
  end, { jobs = edit.write_jobs(), progress = "adding" })

  lulibre.reload()
  if #follow > 0 then edit.apply(follow, { label = "sync" }) end

  for _, job in ipairs(jobs) do
    if job.error then
      table.insert(out.failed, job.row.path:gsub("^.*/", "") .. ": " .. job.error)
    else
      if job.added then
        out.added = out.added + 1
      else
        out.held = out.held + 1
        -- the library had the file already; what was worked out for it here
        -- is offered to the book that holds it
        local theirs = lulibre.book(job.library_id)
        if theirs then
          out.carried = (out.carried or 0) + dupes.propose(
            dupes.gather { { keep = theirs.id, books = { theirs, job.book } } }, "staged file")
        end
      end
      -- proposals not yet reviewed follow the file into the library
      lulibre.store("UPDATE proposals SET book = ? WHERE book = ? AND status IN ('pending', 'accepted')",
        job.library_id, job.id)
      pcall(lulibre.mark, job.id, false)
      local gone = false
      if opts.remove then
        -- delete only what calibre demonstrably has
        local theirs = lulibre.files(job.library_id)[1]
        local same = theirs and lulibre.md5(theirs.path) == lulibre.md5(job.row.path)
        if same and uv.fs_unlink(job.row.path) then
          out.removed = out.removed + 1
          gone = true
        else
          table.insert(out.kept, job.row.path:gsub("^.*/", "") .. ": calibre's copy could not be confirmed, so the file stays")
        end
      end
      if gone then lulibre.store("DELETE FROM staged WHERE id = ?", -job.id)
      else lulibre.store("UPDATE staged SET twin = ? WHERE id = ?", job.library_id, -job.id) end
    end
  end
  lulibre.stage_refresh()
  lulibre.reload()
  return out
end

-- ---- dropping: take a staged file out of the folder without adding it ----

local function mkdir_p(dir)
  local at = ""
  for part in dir:gmatch("[^/]+") do
    at = at .. "/" .. part
    uv.fs_mkdir(at, 493)
  end
end

local function move(from, to)
  mkdir_p(to:match("^(.*)/[^/]*$"))
  local ok, err = uv.fs_rename(from, to)
  if not ok then -- another filesystem: copy, then delete
    ok, err = uv.fs_copyfile(from, to)
    if ok then ok, err = uv.fs_unlink(from) end
  end
  return ok, err
end

--- Drop staged files: each is moved out of the sync folder into a holding
-- folder (dropped/ under lulibre's data directory) and forgotten, with what
-- had been worked out for it. Journaled, so `u` puts the file and its staged
-- metadata back. Returns { dropped=, failed = { "why", ... }, holding= }.
function M.drop(ids)
  local json = require "lulibre.json"
  local dir = M.dir() or ""
  local data = os.getenv("XDG_DATA_HOME") or ((os.getenv("HOME") or "") .. "/.local/share")
  local holding = ("%s/lulibre/dropped/%s"):format(data, os.date("%Y%m%d-%H%M%S"))
  local batch = lulibre.store("SELECT coalesce(max(batch), 0) + 1 AS n FROM journal")[1].n
  local out = { dropped = 0, failed = {}, holding = holding }
  for _, id in ipairs(ids) do
    local row = id < 0 and staged_row(id)
    if row then
      local rel = row.path:sub(1, #dir + 1) == dir .. "/" and row.path:sub(#dir + 2) or row.path:gsub("^.*/", "")
      local held = holding .. "/" .. rel
      local ok, err = move(row.path, held)
      if ok then
        row.held = held
        lulibre.store([[INSERT INTO journal(batch, book, field, old, new, status, ts, label)
          VALUES(?, ?, '(dropped)', ?, '', 'applied', ?, 'sync drop')]], batch, id, json.encode(row), os.time())
        lulibre.store("DELETE FROM staged WHERE id = ?", -id)
        pcall(lulibre.mark, id, false)
        out.dropped = out.dropped + 1
      else
        table.insert(out.failed, rel .. ": " .. tostring(err))
      end
    end
  end
  lulibre.stage_refresh()
  lulibre.reload()
  return out
end

--- Put a dropped file back (what undo does with a "(dropped)" journal row):
-- row is the staged record as drop() saved it. Returns true, or nil and why.
function M.undrop(row)
  if uv.fs_stat(row.path) then return nil, row.path .. " exists again; the dropped copy stays in " .. row.held end
  local ok, err = move(row.held, row.path)
  if not ok then return nil, tostring(err) end
  lulibre.store([[INSERT OR REPLACE INTO staged(id, path, size, mtime, title, authors, tags, series, series_index,
      publisher, pubdate, idents, languages, added, twin, note) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)]],
    row.id, row.path, row.size, row.mtime, row.title, row.authors, row.tags, row.series, row.series_index,
    row.publisher, row.pubdate, row.idents, row.languages, row.added, row.twin, row.note)
  return true
end

--- One line about what add() did.
function M.summary(out)
  local parts = {}
  if out.added > 0 then parts[#parts + 1] = ("added %d to the library"):format(out.added) end
  if out.held > 0 then parts[#parts + 1] = ("%d already there"):format(out.held) end
  if (out.carried or 0) > 0 then parts[#parts + 1] = ("%d proposals for the books that were"):format(out.carried) end
  if out.removed > 0 then parts[#parts + 1] = ("%d files removed from the sync folder"):format(out.removed) end
  if #out.kept > 0 then parts[#parts + 1] = ("%d kept: %s"):format(#out.kept, out.kept[1]) end
  if #out.failed > 0 then parts[#parts + 1] = ("%d failed: %s"):format(#out.failed, out.failed[1]) end
  return #parts > 0 and table.concat(parts, ", ") or "nothing to do"
end

return M
