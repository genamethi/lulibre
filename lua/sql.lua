--- SQLite files, through lsqlite3: a connection, and a statement run with
-- its values.
--
--     local sql = require "sql"
--     local db = sql.open(setman.get("path.witdb"))
--     for _, r in ipairs(sql.run(db, "SELECT field, value FROM wits WHERE book = ?", 12)) do ... end
--
-- The connection is lsqlite3's: everything else it does (`db:exec`,
-- `db:nrows`, `db:close`) is there as lsqlite3 has it.
--
-- @library sql
local sqlite3 = require "lsqlite3"
local luv = require "luv"

local M = {}

--- Opens a file; raises an error when it cannot. A write another
-- connection holds is waited for, up to 5 seconds.
-- @tparam string path
-- @tparam[opt] integer flags lsqlite3's (`sqlite3.OPEN_READONLY`, ...);
-- by default read and write, the file and its folders made when they are
-- not there
-- @return the connection
function M.open(path, flags)
  -- each folder on the way, from the root; one there already stays
  local at = flags == nil and path:find("/", 2, true)
  while at do
    luv.fs_mkdir(path:sub(1, at - 1), 448)
    at = path:find("/", at + 1, true)
  end
  local db, code, msg = sqlite3.open(path, flags)
  if not db then error(("cannot open %s: %s"):format(path, msg or code), 2) end
  db:busy_timeout(5000)
  return db
end

--- Runs a statement with its values bound to its `?`s, in order; raises
-- the error when it fails.
-- @return the rows, each a table by column name
function M.run(db, query, ...)
  local st = db:prepare(query)
  if not st then error(db:errmsg(), 2) end
  if select("#", ...) > 0 then st:bind_values(...) end
  local rows = {}
  for r in st:nrows() do rows[#rows + 1] = r end
  if st:finalize() ~= sqlite3.OK then error(db:errmsg(), 2) end
  return rows
end

return M
