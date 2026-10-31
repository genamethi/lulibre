--- The calibre commands that wait for nothing to hold the library (calibredb
-- won't make a custom column through the content server, say). They are queued in
-- the journal as store.command's `when = "closed"` makes them, and run once nothing
-- has the library open: in the interface, in `lulibre offline`, or at a server's
-- restart by lulibre's systemd unit (:units). This lists them, cancels one, tries
-- one again that failed, and restarts the server for them.
--
-- @library lulib._offline
local sql = require "sql"
local sqlite3 = require "lsqlite3"
local store = require "store"

local M = {}

--- What waits, and what failed: `{ {batch=, label=, args=, state=, error=, ts=}, ... }`.
function M.jobs()
  local db = sql.open(setman.get("path.journaldb"), sqlite3.OPEN_READONLY)
  local rows = sql.run(db, "SELECT batch, label, argv, state, error, ts FROM journal WHERE argv IS NOT NULL AND need = 1"
                           .. " AND state IN (0, 1, 3) ORDER BY id")
  db:close()
  local out = {}
  for _, r in ipairs(rows) do
    local args = {}
    for a in (r.argv .. "\t"):gmatch("(.-)\t") do args[#args + 1] = a end
    out[#out + 1] = { batch = r.batch, label = r.label, args = args, error = r.error, ts = r.ts,
                      state = r.state == 3 and "failed" or r.state == 1 and "running" or "waiting" }
  end
  return out
end

--- Takes a job out of the queue.
function M.cancel(batch)
  return store.cancel(batch)
end

--- Tries the failed jobs again; how many.
function M.retry()
  local n = 0
  for _, j in ipairs(M.jobs()) do
    if j.state == "failed" then
      store.cancel(j.batch)
      taskman.spawn(function() store.command(j.args, { label = j.label }) end)
      n = n + 1
    end
  end
  return n
end

-- how many still wait to run
local function waiting()
  local left = 0
  for _, j in ipairs(M.jobs()) do
    if j.state ~= "failed" then left = left + 1 end
  end
  return left
end

--- Stops the content server, waits for the jobs to be done, and starts it again:
-- by the settings server_stop and server_start, or else by its systemd unit. Returns
-- how many are left, or nil and why it can't.
function M.restart()
  local stop, start = setman.get("server_stop"), setman.get("server_start")
  if stop == "" or start == "" then
    local server = require("units").find()[1]
    if not server then
      return nil, "no way to stop calibre's content server: set server_stop and server_start, or stop it and they run"
    end
    local verb = "systemctl " .. (server.user and "--user " or "")
    stop, start = verb .. "stop '" .. server.name .. "'", verb .. "start '" .. server.name .. "'"
  end
  local r, err = utils.exec({ "sh", "-c", stop }, { timeout = 120000 })
  if not r or r.code ~= 0 then return nil, ("%s: %s"):format(stop, r and r.stderr or tostring(err)) end
  local waited = 0
  while waited < 120 and waiting() > 0 do
    taskman.sleep(500)
    waited = waited + 0.5
  end
  r, err = utils.exec({ "sh", "-c", start }, { timeout = 120000 })
  if not r or r.code ~= 0 then return nil, ("%s: %s"):format(start, r and r.stderr or tostring(err)) end
  return waiting()
end

--- The jobs as rows of a list.
function M.rows()
  local rows = {}
  for _, j in ipairs(M.jobs()) do
    rows[#rows + 1] = { tostring(j.batch), j.state, os.date("%Y-%m-%d %H:%M", j.ts or 0), j.label or "",
                        table.concat(j.args, " "), j.error or "", style = j.state == "failed" and "warn" or nil, batch = j.batch }
  end
  return rows
end

return M
