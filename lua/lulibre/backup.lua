-- Copies of calibre's database (metadata.db, and the preferences calibre
-- keeps beside it), kept with lulibre's data: one folder per copy under
-- ~/.local/share/lulibre/backups/<the index's name>/, the newest
-- lulibre.o.backup_keep of them. They are made before the content server
-- starts (lulibre.service, :offline restart) as lulibre.o.backup_restart
-- says, or when asked.
--
--   local backup = require "lulibre.backup"
--   backup.take("before rebuilding")   -- { path=, ts=, reason= }; waits
--   backup.list()                      -- newest first: { {path=, ts=, reason=, books=}, ... }
--   backup.last()                      -- the newest, or nil
--   backup.age()                       -- days since the newest (nil when there is none)
--   backup.too_old([days])             -- none, or the newest older than days (backup_max_age)
--   backup.prune([keep])               -- remove all but the newest keep (backup_keep)
--   backup.policy()                    -- "always" | "next" | "never" | days
--   backup.due()                       -- would the server's next start make one?
--   backup.on_restart()                -- make one if due (lulibre.offline.run calls it)
--   backup.metadata()                  -- calibredb backup_metadata (the server stopped)
local M = {}

local uv = require "luv"
local json = require "lulibre.json"

local FILES = { "metadata.db", "metadata_db_prefs_backup.json" }
local ABOUT = "about.json"

local function exists(path)
  return uv.fs_stat(path) ~= nil
end

local function mkdirs(path)
  local at = ""
  for part in path:gmatch("[^/]+") do
    at = at .. "/" .. part
    if not exists(at) then
      local ok, err = uv.fs_mkdir(at, 448) -- 0700
      if not ok and not exists(at) then error(("cannot make %s: %s"):format(at, err), 0) end
    end
  end
end

--- Where this library's copies are kept.
function M.dir()
  local p = lulibre.settings.paths()
  local name = (p.index or "index"):match("([^/]+)$"):gsub("%.db$", "")
  return ("%s/backups/%s"):format(p.data_dir, name)
end

local function read_about(dir)
  local f = io.open(dir .. "/" .. ABOUT)
  if not f then return nil end
  local ok, v = pcall(json.decode, f:read("a"))
  f:close()
  return ok and type(v) == "table" and v or nil
end

--- The copies, newest first.
function M.list()
  local out, base = {}, M.dir()
  local h = uv.fs_scandir(base)
  if not h then return out end
  while true do
    local name, kind = uv.fs_scandir_next(h)
    if not name then break end
    if kind == "directory" and name:match("^%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d") then
      local about = read_about(base .. "/" .. name)
      if about and about.ts then
        out[#out + 1] = { path = base .. "/" .. name, ts = about.ts, reason = about.reason, books = about.books }
      end
    end
  end
  table.sort(out, function(a, b) return a.path > b.path end)
  return out
end

function M.last()
  return M.list()[1]
end

function M.age()
  local l = M.last()
  return l and (os.time() - l.ts) / 86400 or nil
end

function M.too_old(days)
  days = days or lulibre.o.backup_max_age
  local age = M.age()
  return age == nil or age > days
end

--- Copy calibre's database now. Waits (the copy is made on a worker
-- thread). The server may be running: the copy is SQLite's own backup, so
-- it is whole even if calibre writes meanwhile.
function M.take(reason)
  local lib = lulibre.o.library
  if lib == "" then error("no library (lulibre.o.library)", 0) end
  local base = M.dir()
  mkdirs(base)
  local stamp = os.date("!%Y%m%d-%H%M%S")
  local dir, n = base .. "/" .. stamp, 1
  while exists(dir) do
    n = n + 1
    dir = ("%s/%s-%d"):format(base, stamp, n)
  end
  mkdirs(dir)
  local ok, err = lulibre.copy_db(lib .. "/metadata.db", dir .. "/metadata.db")
  if not ok then error("backup: " .. err, 0) end
  local prefs = lib .. "/" .. FILES[2]
  if exists(prefs) then uv.fs_copyfile(prefs, dir .. "/" .. FILES[2]) end
  local ts = os.time()
  local books = lulibre.sql("SELECT count(*) AS n FROM books WHERE id > 0")[1].n
  local f = assert(io.open(dir .. "/" .. ABOUT, "w"))
  f:write(json.encode { ts = ts, reason = reason, library = lib, books = books })
  f:close()
  M.prune()
  return { path = dir, ts = ts, reason = reason }
end

--- Remove all but the newest `keep` copies. Only the files a copy is made
-- of are removed; a folder holding anything else is left. Returns how many went.
function M.prune(keep)
  keep = keep or lulibre.o.backup_keep
  local gone = 0
  for i, b in ipairs(M.list()) do
    if i > keep then
      for _, name in ipairs(FILES) do uv.fs_unlink(b.path .. "/" .. name) end
      uv.fs_unlink(b.path .. "/" .. ABOUT)
      if uv.fs_rmdir(b.path) then gone = gone + 1 end
    end
  end
  return gone
end

--- backup_restart, read: "always", "next", "never", or a number of days.
function M.policy()
  local v = tostring(lulibre.o.backup_restart or "always")
  if v == "always" or v == "next" or v == "never" then return v end
  local days = tonumber(v)
  if days and days >= 0 then return days end
  error(("backup_restart is always, next, never or a number of days, not %q"):format(v), 0)
end

-- "next" is spent once a copy is made for it, until backup_restart is set
-- to next again: lulibre notes the value it last saw (in kv), so a change
-- to something else and back re-arms it, whether made here or in init.lua.
local function kv(key, value)
  if value == nil then
    local r = lulibre.store("SELECT value FROM kv WHERE key = ?", key)[1]
    return r and r.value
  end
  if value == false then return lulibre.store("DELETE FROM kv WHERE key = ?", key) end
  lulibre.store("INSERT OR REPLACE INTO kv(key, value) VALUES(?, ?)", key, value)
end

--- Note the value of backup_restart (lulibre does at each start).
function M.observe()
  local v = tostring(lulibre.o.backup_restart)
  if v == "next" and kv("backup:seen") ~= "next" then kv("backup:next_spent", false) end
  kv("backup:seen", v)
end

function M.due()
  M.observe()
  local p = M.policy()
  if p == "never" then return false end
  if p == "always" then return true end
  if p == "next" then return kv("backup:next_spent") == nil end
  return M.too_old(p)
end

--- Set backup_restart, for now and in init.lua. "next" arms it again.
function M.set(value)
  lulibre.o.backup_restart = value
  M.policy() -- says so if it will not do
  if tostring(value) == "next" then kv("backup:next_spent", false) end
  kv("backup:seen", tostring(value))
  pcall(require("lulibre.config_file").write_value, { name = "backup_restart" }, value)
end

--- Before the server starts: a copy if one is due. Returns it, or nil.
function M.on_restart()
  if not M.due() then return nil end
  local b = M.take("before the content server started")
  if M.policy() == "next" then kv("backup:next_spent", tostring(b.ts)) end
  return b
end

--- calibre writes a book's metadata.opf (in its folder) only from its own
-- program; changes made through calibredb or the content server just mark
-- the book. This writes those books' files. The server must be stopped.
-- Returns how many books' files were written.
function M.metadata()
  require("lulibre.calibre").wait_for_program("writing the books' opf files")
  local r, err = lulibre.system({ "calibredb", "--with-library", lulibre.o.library, "backup_metadata" },
    { timeout = 3600000 })
  if not r or r.code ~= 0 then error("backup_metadata: " .. require("lulibre.offline").why(r, err), 0) end
  local n = 0
  for _ in r.stdout:gmatch("[^\n]*%%[^\n]*\n") do n = n + 1 end -- one progress line per book
  return n
end

-- The first change to the library in a session, with the newest copy too
-- old: said once, in a popup that offers one. A replaceable function.
-- (The interface only: a script's output stays its own.)
local said = {} -- said.warned: the session's one popup (lulibre.claim)
function M.warn()
  if said.warned or lulibre.headless or not lulibre.task_id() then return end
  if tostring(lulibre.o.backup_too_old) ~= "warn" or lulibre.o.library == "" or not M.too_old() then return end
  if not lulibre.claim(said, "warned") then return end -- another task has said it
  local age = M.age()
  local what = age and ("the newest copy of calibre's database is %d days old"):format(math.floor(age))
    or "there is no copy of calibre's database yet"
  local pick = lulibre.pick({ "back up now", "not now" }, { title = what .. " (backup_too_old)" })
  if pick == "back up now" then
    local ok, b = pcall(M.take, "asked for, before a change")
    lulibre.notify(ok and ("calibre's database copied to %s"):format(b.path) or tostring(b), not ok and "error" or nil)
  end
end

return M
