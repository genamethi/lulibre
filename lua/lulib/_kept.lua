--- What was worked out from a file, kept so that it is not worked out again
-- while the file is as it was read: what a grammar found, the file's
-- identifiers, how much of a value is on its pages. Keyed by the file, the
-- step and what the step was asked; good for one stamp, the time the index
-- read the file. They are in the file path.witdb, table `kept`, and
-- can go at any time: they are worked out again.
--
--     local k <close> = kept.open(file.id, file.indexed)
--     local v = k:get("ids", "")
--     if v == nil then v = work(); k:put("ids", "", v) end
--
-- @library lulib._kept
local bookman = require "bookman"
local json = require "dkjson"
local sql = require "sql"
local sqlite3 = require "lsqlite3"
local txt = require "txt"

local M = {}

local db

local function run(query, ...)
  db = db or sql.open(setman.get("path.witdb"), sqlite3.OPEN_READWRITE)
  return sql.run(db, query, ...)
end

local kept = {}
kept.__index = kept

--- A file's kept results. With no file, nothing is kept.
-- @tparam[opt] integer file
-- @tparam[opt] integer stamp
function M.open(file, stamp)
  local k = setmetatable({ file = file, stamp = stamp, have = {}, new = {} }, kept)
  if file then
    for _, r in ipairs(run("SELECT step, key, data FROM kept WHERE file = ? AND stamp = ?", file, stamp or 0)) do
      k.have[r.step .. "\0" .. r.key] = r.data
    end
  end
  return k
end

--- A kept result, or nil.
function kept:get(step, key)
  local data = self.have[step .. "\0" .. key]
  if data == nil then return nil end
  if type(data) == "string" then return (json.decode(data)) end
  return data
end

--- Keeps a result: a table, a number, a string or a boolean. It reaches the
-- file as the object closes.
function kept:put(step, key, value)
  self.have[step .. "\0" .. key] = json.encode(value)
  self.new[#self.new + 1] = { step, key, self.have[step .. "\0" .. key] }
end

function kept:__close()
  if not self.file or #self.new == 0 then return end
  run("BEGIN IMMEDIATE")
  local ok, err = pcall(function()
    run("DELETE FROM kept WHERE file = ? AND stamp IS NOT ?", self.file, self.stamp or 0)
    for _, r in ipairs(self.new) do
      run("INSERT OR REPLACE INTO kept(file, step, key, stamp, data) VALUES (?, ?, ?, ?, ?)",
          self.file, r[1], r[2], self.stamp or 0, r[3])
    end
  end)
  run(ok and "COMMIT" or "ROLLBACK")
  self.new = {}
  if not ok then error(err, 2) end
end

--- The file a book is read from: its best with text, else its best; nil if
-- it has none. A row of bookman.files.
function M.file_of(book)
  local files = bookman.files(book) or {}
  for _, f in ipairs(files) do
    if f.text then return f end
  end
  return files[1]
end

--- A file's text, read when first asked for, by `get()` (nil when it has
-- none), and released as the object closes.
-- @tparam[opt] table file a row of bookman.files
function M.reader(file)
  local t, tried
  return setmetatable({
    get = function()
      if not tried then
        tried = true
        if file and file.text then t = txt.load(file.id) end
      end
      return t
    end,
  }, { __close = function()
    local _ <close> = t
    t = nil
  end })
end

--- Forgets what was kept: of a file, or of every file.
-- @tparam[opt] integer file
function M.forget(file)
  if file then run("DELETE FROM kept WHERE file = ?", file) else run("DELETE FROM kept") end
end

return M
