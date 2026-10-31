--- Removing books from calibre, and bringing them back. Removed books go to
-- calibre's recycle bin (.caltrash in the library's folder), and the journal
-- keeps each one's record, as a batch :undo puts back: its files and cover are
-- added again and its metadata restored. A book comes back with a new id, and
-- its proposals and fields of your own go with it.
--
--     local remove = require "lulib._remove"
--     local n, err = remove.remove(ids, { label = "duplicates" })
--
-- @library lulib._remove
local bookman = require "bookman"
local json = require "dkjson"
local luv = require "luv"
local sql = require "sql"
local sqlite3 = require "lsqlite3"
local store = require "store"
local wit = require "wit"

local M = {}

local FIELDS = { "title", "authors", "tags", "series", "series_index", "publisher", "pubdate", "languages", "identifiers" }

-- what's kept of a book
local function snapshot(id)
  local b = bookman.get(id)
  if not b then return nil end
  local out = { formats = {} }
  for _, field in ipairs(FIELDS) do out[field] = bookman.get(id, field) end
  for _, f in ipairs(bookman.files(id) or {}) do out.formats[#out.formats + 1] = f.format end
  return out
end

--- Removes books from calibre, as one batch. Returns how many, and why not all
-- if calibredb failed. A sync folder's file is not in calibre: :sync drop.
-- @tparam {integer,...} ids
-- @tparam[opt] table o `{ label= }`
function M.remove(ids, o)
  local label = o and o.label or "remove"
  local n, batch = 0, nil
  for _, id in ipairs(ids) do
    if id < 0 then return 0, "files staged from the sync folder are not in calibre; :sync drop takes them out of the folder" end
  end
  for from = 1, #ids, 200 do
    local chunk, rows = {}, {}
    for i = from, math.min(from + 199, #ids) do
      local snap = snapshot(ids[i])
      if snap then
        chunk[#chunk + 1] = tostring(ids[i])
        rows[#rows + 1] = { ids[i], json.encode(snap) }
      end
    end
    if #chunk > 0 then
      -- noted first: a reading of calibre's records meanwhile takes them for lulibre's
      local noted = batch
      for _, r in ipairs(rows) do noted = store.note(noted, r[1], "(removed)", r[2], "", label) end
      local b, printed = store.command({ "remove", table.concat(chunk, ",") }, { label = label, when = "any", batch = noted })
      if not b then
        if not batch then store.mark_undone(noted) end
        return n, printed, batch
      end
      batch = noted
      n = n + #chunk
    end
  end
  if n > 0 then store.reload() end
  return n, nil, batch
end

-- Brings one removed book back out of the recycle bin; its new id, or nil and why.
local function restore(id, snap)
  local dir = ("%s/.caltrash/b/%d"):format(setman.get("path.library"), id)
  local files, opf, cover = {}, nil, nil
  local req = luv.fs_scandir(dir)
  while req do
    local name, kind = luv.fs_scandir_next(req)
    if not name then break end
    if name == "metadata.opf" then opf = dir .. "/" .. name
    elseif name == "cover.jpg" then cover = dir .. "/" .. name
    elseif kind == "file" then files[#files + 1] = dir .. "/" .. name end
  end
  table.sort(files)
  if #files == 0 and not opf and (#(snap.formats or {}) > 0 or not req) then
    return nil, ("calibre's recycle bin no longer holds book %d (%s)"):format(id, snap.title or "?")
  end
  local args = { "add", "--duplicates", "--title", snap.title ~= "" and snap.title or "Unknown" }
  if snap.authors and snap.authors ~= "" then
    args[#args + 1] = "--authors"
    args[#args + 1] = snap.authors
  end
  if cover then
    args[#args + 1] = "--cover"
    args[#args + 1] = cover
  end
  if #files > 0 then args[#args + 1] = files[1] else args[#args + 1] = "--empty" end
  local b, printed = store.command(args, { label = "restore", when = "any" })
  local new = b and tonumber((printed or ""):match("Added book ids:%s*(%d+)"))
  if not new then return nil, b and printed or printed end
  for i = 2, #files do store.command({ "add_format", tostring(new), files[i] }, { label = "restore", when = "any", batch = b }) end
  local meta = { "set_metadata", tostring(new) }
  if opf then
    meta[#meta + 1] = opf
  else
    for _, field in ipairs(FIELDS) do
      local value = snap[field]
      if value and value ~= "" and not (field == "series_index" and (snap.series or "") == "") then
        meta[#meta + 1] = "--field"
        meta[#meta + 1] = field .. ":" .. value
      end
    end
  end
  local ok, why = store.command(meta, { label = "restore", when = "any", batch = b })
  store.command_undo(b, { "remove", tostring(new) })
  if not ok then return new, "the book is back, but not all of its metadata: " .. tostring(why) end
  return new
end

--- Brings back one removed book, by its journal row (`book=, old=`): its new id,
-- and why not all of it; or nil and why not.
function M.restore_one(r)
  local id, err = restore(r.book, json.decode(r.old) or {})
  if id then
    store.note(nil, id, "(restored)", tostring(r.book), r.old, "restore")
    wit.move(r.book, id)
    local custom = sql.open(setman.get("path.customdb"), sqlite3.OPEN_READWRITE)
    sql.run(custom, "UPDATE data SET book = ? WHERE book = ?", id, r.book)
    custom:close()
  end
  return id, err
end

--- Brings back the books a batch removed. Returns the new ids, and why not all.
-- @tparam integer batch
function M.restore(batch)
  local db = sql.open(setman.get("path.journaldb"), sqlite3.OPEN_READONLY)
  local rows = sql.run(db, "SELECT book, old FROM journal WHERE batch = ? AND field = '(removed)' AND state = 2", batch)
  db:close()
  local new, why = {}, nil
  for _, r in ipairs(rows) do
    local id, err = M.restore_one(r)
    if id then new[#new + 1] = id end
    why = why or err
  end
  if #new == #rows then store.mark_undone(batch) end
  store.reload()
  return new, why
end

--- Whether a batch removed books.
function M.has_removed(batch)
  local db = sql.open(setman.get("path.journaldb"), sqlite3.OPEN_READONLY)
  local rows = sql.run(db, "SELECT 1 AS x FROM journal WHERE batch = ? AND field = '(removed)' AND state = 2 LIMIT 1", batch)
  db:close()
  return #rows > 0
end

-- store.undo for every batch: what removed books brings them back
local undo = store.undo
store.undo = function(batch)
  if M.has_removed(batch) then
    local new, why = M.restore(batch)
    if #new == 0 then return nil, why end
    return batch
  end
  return undo(batch)
end

return M
