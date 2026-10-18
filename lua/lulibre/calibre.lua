-- Which calibre programs are running, from the outside: nothing is opened,
-- locked or asked. calibre keeps one program at a time on a user's
-- libraries with a lock that on Linux is an abstract unix socket, per user
-- (not per library): calibre-singleinstance-<uid>-db, held by its program,
-- calibre-server, and calibredb while it opens a library directly; its
-- program also holds ...-GUI. /proc/net/unix lists them. (Binding the name
-- to test it would be taking the lock: the program could not start.)
--
--   local calibre = require "lulibre.calibre"
--   calibre.running()   -- { db = bool, gui = bool }, or nil where it cannot be told
--   calibre.holds()     -- something has the library open (db), or nil
local M = {}

local function uid()
  local ok, uv = pcall(require, "luv")
  local p = ok and uv.os_get_passwd and uv.os_get_passwd()
  return p and p.uid
end

-- where the sockets are listed (a test points it elsewhere)
M.SOCKETS = "/proc/net/unix"

function M.running()
  local id = uid()
  local f = id and io.open(M.SOCKETS)
  if not f then return nil end -- not Linux, or no /proc
  local text = f:read("a")
  f:close()
  local base = "@calibre%-singleinstance%-" .. id .. "%-"
  return { db = text:find(base .. "db%f[%s%z]") ~= nil, gui = text:find(base .. "GUI%f[%s%z]") ~= nil }
end

function M.holds()
  local r = M.running()
  return r and r.db
end

return M
