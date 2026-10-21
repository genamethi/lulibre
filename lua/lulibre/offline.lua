--- Changes calibre makes only while no calibre program has the library open.
-- calibredb won't run catalog, add_custom_column, remove_custom_column,
-- restore_database, check_library or backup_metadata through the content
-- server. These commands are queued here, in the history file beside the
-- index, until the server is stopped. Then `run` applies them straight to
-- the library folder. Before that, it makes a copy of calibre's database if
-- `backup_restart` says so (see `lulibre.backup`). lulibre's own changes
-- of this kind wait in the same queue (see `handlers`; putting a copy of
-- calibre's database back is one).
--
-- `run` applies the queue, whatever stops the server. lulibre.service
-- calls it before each start of the server (`lulibre offline`), `restart`
-- calls it when you choose "restart now", and you can run `lulibre offline`
-- yourself while the server is down.
--
-- @module lulibre.offline
-- @usage
-- local offline = require "lulibre.offline"
-- offline.queue({ "add_custom_column", "partof", "Part of", "text" }, "the column #partof")
-- offline.jobs()     --> those still to do
-- offline.run()      --> { done=, skipped=, failed={...} }; the server must be stopped
-- offline.ask()      -- "restart now" or "not now", in the interface
local M = {}

local json = require "lulibre.json"

--- Queues a calibredb command, or a job of lulibre's own (see `handlers`).
-- @tparam {string,...} argv calibredb's arguments after `--with-library`
-- @tparam[opt] string label what it is, as the list shows it
-- @treturn integer the job's id
function M.queue(argv, label)
  assert(type(argv) == "table" and type(argv[1]) == "string", "offline.queue takes calibredb's arguments: { command, ... }")
  for _, a in ipairs(argv) do assert(type(a) == "string", "calibredb's arguments are strings") end
  local _, _, id = lulibre.store("INSERT INTO offline(argv, label, ts) VALUES(?, ?, ?)", json.encode(argv), label,
    os.time())
  return id
end

local function rows(sql, ...)
  local out = {}
  for _, r in ipairs(lulibre.store(sql, ...)) do
    r.argv = json.decode(r.argv)
    out[#out + 1] = r
  end
  return out
end

--- Returns the jobs, oldest first.
-- @tparam[opt] string status "pending" (the default: waiting, or failed and
-- to be tried again), "waiting", "failed", "done" or "all"
-- @treturn {table,...} each `{ id=, argv=, label=, ts=, status=, error= }`
function M.jobs(status)
  status = status or "pending"
  if status == "all" then return rows("SELECT * FROM offline ORDER BY id") end
  if status == "pending" then return rows("SELECT * FROM offline WHERE status IN ('waiting', 'failed') ORDER BY id") end
  return rows("SELECT * FROM offline WHERE status = ? ORDER BY id", status)
end

--- Drops a job that is waiting or failed.
-- @tparam integer id
-- @treturn boolean true if there was such a job
function M.cancel(id)
  local _, n = lulibre.store("UPDATE offline SET status = 'cancelled', done = ? WHERE id = ? AND status IN ('waiting', 'failed')",
    os.time(), id)
  return n > 0
end

--- Returns true if the content server answers.
-- @treturn boolean|nil nil if `server` is not set
function M.server_up()
  if lulibre.o.server == "" then return nil end
  return require("lulibre.edit").server_up(lulibre.o.server)
end

--- Tests for jobs that have nothing left to do, by calibredb command. Each
-- test gets the job's argv and calibre's current columns (`{ label = true }`).
-- It returns why there is nothing to do, or nil. The test runs before the
-- job, so a job already done (by hand, or by a run that stopped half way)
-- is not tried again. You can replace these tests or add your own.
M.already = {
  add_custom_column = function(argv, columns) return columns[argv[2]] and "calibre has that column already" end,
  remove_custom_column = function(argv, columns) return not columns[argv[2]] and "calibre has no such column" end,
}

--- The calibredb commands that change the structure of calibre's database.
-- They are held back if the books' metadata.opf files could not be written first.
M.STRUCTURAL = { add_custom_column = true, remove_custom_column = true, restore_database = true }

--- Jobs lulibre does itself instead of calibredb. `argv[1]` names the
-- handler. The handler gets argv and returns its result as one line, which
-- `summary` shows.
M.handlers = {
  restore_copy = function(argv)
    local backup = require "lulibre.backup"
    local r = backup.put_back(argv[2])
    -- the copy's books whose opf files are behind it are marked: written now, if they can be
    if lulibre.o.backup_metadata then pcall(backup.metadata) end
    return backup.put_back_summary(r)
  end,
}

--- Returns a job as one line: its label and what it runs.
-- @tparam table j a job (`jobs`)
-- @treturn string
function M.describe(j)
  local how = M.handlers[j.argv[1]] and "lulibre: " or "calibredb "
  return ("%s  (%s%s)"):format(j.label or "", how, table.concat(j.argv, " "))
end

local function direct(argv)
  local a = { "calibredb", "--with-library", lulibre.o.library }
  for _, x in ipairs(argv) do a[#a + 1] = x end
  return a
end

--- Returns what went wrong with a calibredb run, as one line.
-- @tparam table|nil r what `lulibre.system` returned
-- @tparam[opt] string err its error, if there is no `r`
-- @treturn string
function M.why(r, err)
  if not r then return err or "could not run calibredb" end
  if r.timed_out then return "calibredb timed out" end
  local msg = (r.stderr ~= "" and r.stderr or r.stdout):gsub("%s+$", "")
  if msg:find("Another calibre program") then return "a calibre program has the library open" end
  return msg:match("[^\n]*$") or ("calibredb exited with status " .. r.code)
end

-- calibre's columns as they are now ({ label = true }). Waits while another
-- calibre program has the library: a server that has stopped answering
-- can take a moment longer to let go of it.
local function columns()
  for _ = 1, 60 do -- 30 s
    local r, err = lulibre.system(direct { "custom_columns" }, { timeout = 60000 })
    if r and r.code == 0 then
      local out = {}
      for label in r.stdout:gmatch("([%w_]+) %(%d+%)") do out[label] = true end
      return out
    end
    local msg = r and (r.stderr .. r.stdout) or ""
    if not msg:find("Another calibre program") then error("calibredb custom_columns: " .. M.why(r, err), 0) end
    lulibre.sleep(500)
  end
  error("a calibre program has the library open (the content server, or calibre itself)", 0)
end

-- "restart now" (M.restart) makes the copy of calibre's database and writes
-- the opf files itself, then starts the server; lulibre.service, which that
-- start sets off when it is installed, would do both again (two copies for
-- one restart, pushing a real one out of the backup_keep kept). M.restart
-- says in kv that it is starting the server; a run meanwhile leaves the two
-- alone. Ten minutes at most: a mark left by a run that never ended does not
-- keep a later start from its copy.
local RESTARTING = "offline:restarting"

local function restarting()
  local r = lulibre.store("SELECT value FROM kv WHERE key = ?", RESTARTING)[1]
  return r ~= nil and os.time() - (tonumber(r.value) or 0) < 600
end

--- Runs the waiting jobs in the order they were queued, straight to the
-- library folder. The content server must be stopped, or calibre refuses.
-- The calibre program must be closed; the jobs wait until it is. A job
-- whose work is already done is skipped (see `already`).
-- @treturn table `{ done=, skipped=, failed = { {id=, label=, error=}, ... },
-- backup=, opf= }`
function M.run()
  local out = { done = 0, skipped = 0, failed = {} }
  -- those that failed are tried again (M.already keeps one that did its work from doing it twice)
  local jobs = M.jobs("pending")
  local up = M.server_up()
  -- a copy of calibre's database first, as backup_restart says (it is made
  -- whether or not anything waits: this is the server's start); not when
  -- a copy is to be put back, which makes its own. A copy that cannot be
  -- made holds back what changes the database's shape, not the rest.
  local restoring = false
  for _, j in ipairs(jobs) do restoring = restoring or j.argv[1] == "restore_copy" end
  out.restarted = not up and restarting() -- (M.restart made the copy and wrote the files just before)
  if not up and not restoring and not out.restarted then
    local ok, b = pcall(require("lulibre.backup").on_restart)
    if ok then out.backup = b else out.backup_error = tostring(b) end
  end
  if up then
    if #jobs == 0 then return out end
    error("the content server is running: these wait until it is stopped", 0)
  end
  local held = require("lulibre.calibre").running()
  if held and held.gui then
    -- the program keeps the opf files current itself
    if #jobs == 0 then return out end
    error("calibre's program has the library open: these wait until it is closed", 0)
  end
  -- (waits for a server that is stopping to let go); a database calibredb
  -- cannot read fails calibredb's jobs, not lulibre's own (putting a copy back)
  local cols_ok, cols = pcall(columns)
  if not cols_ok then out.columns_error, cols = tostring(cols), nil end
  -- the books' opf files, by calibre: with the server stopped nothing else
  -- writes them (backup_metadata option); before anything that changes the
  -- database's shape, they must be
  local opf_ok = not lulibre.o.backup_metadata or out.restarted
  if not opf_ok then
    local ok, n = pcall(require("lulibre.backup").metadata)
    if ok then out.opf, opf_ok = n, true else out.opf_error = tostring(n) end
  end
  for _, job in ipairs(jobs) do
    require("lulibre.calibre").wait_for_program("changes that wait for the server")
    local check = M.already[job.argv[1]]
    local done = check and cols and check(job.argv, cols)
    local r, err
    local hold = not done and M.STRUCTURAL[job.argv[1]] and (not opf_ok or out.backup_error)
    local handler = M.handlers[job.argv[1]]
    if hold then
      err = out.backup_error and ("waits: calibre's database could not be copied first (" .. out.backup_error .. ")")
        or ("waits: the books' opf files could not be written first (" .. tostring(out.opf_error) .. ")")
    elseif not done and handler then
      local ok, said = pcall(handler, job.argv)
      if ok then
        r = { code = 0 }
        out.said = out.said or {}
        out.said[#out.said + 1] = said
      else
        err = tostring(said)
      end
    elseif not done and not cols then
      err = out.columns_error
    elseif not done then
      r, err = lulibre.system(direct(job.argv), { timeout = 600000 })
    end
    local ok = done or (r and r.code == 0)
    lulibre.store("UPDATE offline SET status = ?, error = ?, done = ? WHERE id = ?", ok and "done" or "failed",
      not ok and M.why(r, err) or (done or nil), os.time(), job.id)
    if not ok then
      out.failed[#out.failed + 1] = { id = job.id, label = job.label, error = M.why(r, err) }
    elseif done then
      out.skipped = out.skipped + 1
    else
      out.done = out.done + 1
      if cols and job.argv[1] == "add_custom_column" then cols[job.argv[2]] = true end
      if cols and job.argv[1] == "remove_custom_column" then cols[job.argv[2]] = nil end
    end
  end
  return out
end

--- Returns `run`'s result as one line.
-- @tparam table r what `run` returned
-- @treturn string
function M.summary(r)
  local parts = {}
  if r.backup then
    parts[#parts + 1] = r.backup.check == "failed" and "calibre's database copied, and the copy FAILS its integrity check"
      or "calibre's database copied"
  end
  if r.backup_error then parts[#parts + 1] = "calibre's database not copied: " .. r.backup_error end
  if r.restarted then parts[#parts + 1] = "the copy and the opf files left to the restart that started the server" end
  for _, said in ipairs(r.said or {}) do parts[#parts + 1] = said end
  if (r.opf or 0) > 0 then
    parts[#parts + 1] = r.opf == 1 and "1 book's opf file written" or ("%d books' opf files written"):format(r.opf)
  end
  if r.opf_error then parts[#parts + 1] = "the opf files not written: " .. r.opf_error end
  if r.done > 0 then parts[#parts + 1] = ("%d done"):format(r.done) end
  if r.skipped > 0 then parts[#parts + 1] = ("%d done already"):format(r.skipped) end
  if #r.failed > 0 then
    parts[#parts + 1] = ("%d failed: %s"):format(#r.failed, r.failed[1].error)
  end
  if r.done + r.skipped + #r.failed == 0 then parts[#parts + 1] = "nothing was waiting" end
  return table.concat(parts, ", ")
end

local function sh(cmd)
  local r, err = lulibre.system({ "sh", "-c", cmd }, { timeout = 120000 })
  if not r or r.code ~= 0 then error(("%s: %s"):format(cmd, M.why(r, err)), 0) end
end

local function until_up(want)
  for _ = 1, 300 do -- 30 s
    if M.server_up() == want then return true end
    lulibre.sleep(100)
  end
  return false
end

--- Returns true if lulibre can stop and start the content server itself
-- (`server_stop` and `server_start` are set).
-- @treturn boolean
function M.can_restart()
  return lulibre.o.server_stop ~= "" and lulibre.o.server_start ~= ""
end

--- Stops the content server, runs the waiting jobs, and starts the server
-- again. The server is started again even if jobs failed.
-- @treturn table what `run` returned
function M.restart()
  if not M.can_restart() then
    error("lulibre cannot stop the content server: set lulibre.o.server_stop and server_start", 0)
  end
  sh(lulibre.o.server_stop)
  if lulibre.o.server ~= "" and not until_up(false) then
    sh(lulibre.o.server_start)
    error("the content server was still answering after server_stop", 0)
  end
  local ok, r = pcall(M.run)
  -- lulibre.service, run by this start, leaves the copy and the opf files
  -- to this run, when it went through (when it failed, the service tries)
  if ok then lulibre.store("INSERT OR REPLACE INTO kv(key, value) VALUES(?, ?)", RESTARTING, tostring(os.time())) end
  local started, err = pcall(sh, lulibre.o.server_start)
  local back = started and (lulibre.o.server == "" or until_up(true))
  lulibre.store("DELETE FROM kv WHERE key = ?", RESTARTING)
  if not started then error(err, 0) end
  lulibre.reload()
  if not ok then error(r, 0) end
  if not back then error(M.summary(r) .. "; but the content server does not answer since server_start", 0) end
  return r
end

--- Says which jobs are waiting and offers what can be done now. The
-- interface calls it after a job is queued. The offer depends on what has
-- the library open (see `lulibre.calibre`):
--
-- - nothing (no server, or it is stopped): run the jobs now
-- - the calibre program: the jobs wait until it is closed
-- - the content server: restart it now, or later
--
-- A replaceable function.
function M.ask()
  local jobs = M.jobs()
  if #jobs == 0 then return end
  local what = #jobs == 1 and (jobs[1].label or jobs[1].argv[1]) or ("%d changes"):format(#jobs)
  local held = require("lulibre.calibre").running()
  local free = held and not held.db or (not held and not M.server_up())
  local interactive = not lulibre.headless and lulibre.task_id()
  local function say(msg, level)
    if interactive then lulibre.notify(msg, level) else print(msg) end
  end
  local function now(how)
    local ok, r = pcall(how)
    say(ok and M.summary(r) or tostring(r), (not ok or #r.failed > 0) and "error" or nil)
  end
  if free then
    -- nothing has the library open: nothing to stop
    if not interactive then return say(("%s waits: `lulibre offline` does it (nothing has the library open)"):format(what)) end
    local pick = lulibre.pick({ "do it now", "not now" }, { title = ("%s: nothing has the library open"):format(what) })
    if pick == "do it now" then return now(M.run) end
    return say(("%s waits (:offline run does it)"):format(what))
  end
  if held and held.gui then
    return say(("%s waits until calibre's program is closed (then :offline run, or lulibre.service at the server's next start)")
      :format(what))
  end
  local later = ("%s waits for the content server's next restart (:offline restart does it now)"):format(what)
  if not interactive then return say(later) end
  if not M.can_restart() then
    return say(("%s waits for the content server to be stopped (set server_stop and server_start to let lulibre restart it)")
      :format(what))
  end
  local pick = lulibre.pick({ "restart now", "not now" },
    { title = ("calibre makes %s only while the content server is stopped"):format(what) })
  if pick ~= "restart now" then return say(later) end
  now(M.restart)
end

return M
