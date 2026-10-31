--- Bringing removed books back. store.remove sends them to calibre's recycle bin
-- (.caltrash in the library's folder), and the journal keeps each one's record. Here
-- they come back under new ids: the files and cover are added again, the metadata
-- restored, and proposals and fields of your own go with them. :undo does this for
-- a batch that removed books (:restore-removed), and so does store.undo.
--
-- @library lulib._remove
local json = require "dkjson"
local luv = require "luv"
local sql = require "sql"
local sqlite3 = require "lsqlite3"
local store = require "store"
local wit = require "wit"

local M = {}

local FIELDS = { "title", "authors", "tags", "series", "series_index", "publisher", "pubdate", "languages", "identifiers" }

-- Brings one removed book back out of the recycle bin; its new id, or nil and why.
local function restore(id, snap, record)
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
  local formats = snap.formats
  if #files == 0 and not opf and ((formats and #formats > 0) or not req) then
    return nil, ("calibre's recycle bin no longer holds book %d (%s)"):format(id, snap.title or "?")
  end
  local ids, why, b = store.add({ { path = files[1], title = snap.title ~= "" and snap.title or "Unknown",
                                    authors = snap.authors, cover = cover, restores = id, record = record } }, "restore")
  local new = ids[1]
  if not new then return nil, why end
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
  local ok, err = store.command(meta, { label = "restore", when = "any", batch = b })
  if not ok then return new, "the book is back, but not all of its metadata: " .. tostring(err) end
  return new
end

--- Brings back one removed book, by its journal row (`book=, old=`): its new id, and
-- why not all of it; or nil and why not.
function M.restore_one(r)
  local id, err = restore(r.book, json.decode(r.old) or {}, r.old)
  if id then
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
