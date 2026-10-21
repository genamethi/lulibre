--- Finds out which calibre programs are running, without opening, locking
-- or asking anything.
--
-- calibre lets one program at a time use a user's libraries. On Linux the
-- lock is an abstract unix socket per user (not per library),
-- calibre-singleinstance-<uid>-db. The calibre program, calibre-server, and
-- calibredb while it opens a library directly all hold that socket. The
-- calibre program also holds ...-GUI. /proc/net/unix lists the sockets.
-- Binding the name to test it would take the lock, and the calibre program
-- could not start.
--
-- @module lulibre.calibre
-- @usage
-- local calibre = require "lulibre.calibre"
-- calibre.running()   -- { db = bool, gui = bool }, or nil where it cannot be told
-- calibre.holds()     -- something has the library open (db), or nil
-- calibre.server()    -- calibre's server run through calibre-server-opf.py:
--                        its status { pid=, opf_thread=, error=, calibre=, libraries= }, or nil
-- calibre.opf()       -- who keeps the books' metadata.opf files current now:
--                        { by = "program" | "server" | nil, behind = n, why = "..." }
-- calibre.wait_for_program(what)
--                        while calibre's program is open, wait (saying so); true if it
--                        waited. Called before each step of something the program
--                        could be doing too (a direct calibredb run, a file moved
--                        out of a book's folder): pause while it is open, resume after.
local M = {}

local function uid()
  local ok, uv = pcall(require, "luv")
  local p = ok and uv.os_get_passwd and uv.os_get_passwd()
  return p and p.uid
end

--- The file that lists the sockets. A test points `SOCKETS` elsewhere.
M.SOCKETS = "/proc/net/unix"

--- Returns which of calibre's locks are held: `db` by any calibre program
-- on the library, `gui` by the calibre program.
-- @treturn table|nil `{ db=, gui= }`, or nil if the sockets can't be read
function M.running()
  local id = uid()
  local f = id and io.open(M.SOCKETS)
  if not f then return nil end -- not Linux, or no /proc
  local text = f:read("a")
  f:close()
  local base = "@calibre%-singleinstance%-" .. id .. "%-"
  return { db = text:find(base .. "db%f[%s%z]") ~= nil, gui = text:find(base .. "GUI%f[%s%z]") ~= nil }
end

--- Returns true if something has the library open.
-- @treturn boolean|nil
function M.holds()
  local r = M.running()
  return r and r.db
end

--- Returns the path of the status file contrib/calibre-server-opf.py writes.
-- @treturn string
function M.status_file()
  local dir = os.getenv("XDG_STATE_HOME")
  if not dir or dir == "" then dir = (os.getenv("HOME") or "") .. "/.local/state" end
  return dir .. "/lulibre/calibre-server.json"
end

--- Returns the status of calibre's server started through
-- calibre-server-opf.py, if one is running: the process the status file
-- names is alive and is calibre-server-opf.py.
-- @treturn table|nil `{ pid=, opf_thread=, error=, calibre=, libraries= }`
function M.server()
  local f = io.open(M.status_file())
  if not f then return nil end
  local ok, st = pcall(require("lulibre.json").decode, f:read("a"))
  f:close()
  if not ok or type(st) ~= "table" or not st.pid then return nil end
  local cmd = io.open(("/proc/%d/cmdline"):format(st.pid))
  if not cmd then return nil end -- not running (an unclean stop leaves the file)
  local line = cmd:read("a")
  cmd:close()
  if not line:find("calibre-server-opf.py", 1, true) then return nil end -- the pid was reused
  return st
end

--- Returns which calibre program keeps the opf files current, and how many
-- books' opf files are older than their record, as of the mirror's last
-- read of calibre's database.
-- @treturn table `{ by = "program" | "server" | nil, behind = n, why= }`
function M.opf()
  local behind = tonumber((lulibre.sql("SELECT value FROM meta WHERE key = 'calibre_opf_behind'")[1] or {}).value)
  local r = M.running()
  if r and r.gui then return { by = "program", behind = behind, why = "calibre's program writes them" } end
  local st = M.server()
  if st and st.opf_thread then
    return { by = "server", behind = behind, why = "calibre's server writes them (calibre-server-opf.py)" }
  end
  if st then
    return { behind = behind, why = ("calibre's server runs through calibre-server-opf.py, but without the thread: %s")
      :format(st.error or "?") }
  end
  return { behind = behind, why = "nothing writes them while the server runs (opf_writer = server does); "
    .. "until then, at each stop (backup_metadata)" }
end

--- Waits while the calibre program is open, and returns once the program
-- has closed. Only a task can wait. Outside a task, `wait_for_program`
-- only reports whether the program is open.
-- @tparam string what what is waiting, for the message
-- @treturn boolean true if it waited
function M.wait_for_program(what)
  local r = M.running()
  if not (r and r.gui) then return false end
  if not lulibre.task_id() then return false end
  local msg = ("%s: paused while calibre's program is open"):format(what or "lulibre")
  lulibre.log(msg)
  if lulibre.headless then io.stderr:write("lulibre: ", msg, "\n") end
  while true do
    if not lulibre.headless then
      lulibre.progress(("%s: paused while calibre's program is open"):format(what or "lulibre"))
    end
    lulibre.sleep(1000)
    r = M.running()
    if not (r and r.gui) then break end
  end
  if not lulibre.headless then lulibre.progress(nil) end
  lulibre.log(("%s: calibre's program is closed; going on"):format(what or "lulibre"))
  return true
end

return M
