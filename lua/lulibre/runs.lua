--- Runs: one go of proposing for some books, as the "propose, then review"
-- dialog starts (a script of your own can start one the same way). A run is
-- remembered for as long as proposals wait for its books, so that review can
-- show it by itself, apart from everything else that waits, and so that it
-- can be dropped as a whole.
--
-- A script that may be one step of somebody else's run joins it instead:
--
--   local run <close> = runs.join { ids = ids, steps = { "files" } }
--   run:step("files") ...
--
-- which starts a run when the task has none, finishes it when the script
-- ends (as stopped, if it did not get to its end), and inside a run that is
-- going on already does nothing at all.
--
-- What a run going on looks like is decided here and is yours to change, in
-- init.lua:
--
--   runs.badge = function(run) return "busy", "error" end   -- other words, another colour
--   runs.badge = function() end                              -- no badge at all
--   runs.on(function(event, run) ... end)    -- "start", "step", "finish", "drop"
--
-- @module lulibre.runs
-- @usage
-- local runs = require "lulibre.runs"
-- local run = runs.start { ids = ids, label = "my script", steps = { "files", "records" } }
-- runs.step(run, "files") ... runs.step(run, "records") ...
-- runs.finish(run)
local json = require "lulibre.json"

local M = {}

--- Finished runs remembered at most; what older ones proposed still waits under "all".
M.KEEP = 6

local live = {}      -- runs going on now, the newest first
local listeners = {}
local last = 0
local taken = {} -- the ids given out: each taken with lulibre.claim, so two runs started together differ

local function fire(event, run)
  for _, fn in ipairs(listeners) do
    local ok, err = pcall(fn, event, run)
    if not ok then lulibre.log(("a listener for runs failed: %s"):format(tostring(err)), "warn") end
  end
end

--- Call fn(event, run) when a run starts, moves to its next step, finishes
-- or is dropped.
-- @tparam function fn `fn(event, run)`, event "start", "step", "finish" or "drop"
function M.on(fn)
  listeners[#listeners + 1] = fn
end

local function stored()
  local row = lulibre.store("SELECT value FROM kv WHERE key = 'runs'")[1]
  local ok, list = pcall(json.decode, row and row.value or "[]")
  return ok and type(list) == "table" and list or {}
end

local function store(list)
  local out = {}
  for i, run in ipairs(list) do
    if i > M.KEEP then break end
    local fields
    if run.fields then
      fields = {}
      for f in pairs(run.fields) do fields[#fields + 1] = f end
      table.sort(fields)
    end
    out[i] = { id = run.id, label = run.label, started = run.started, finished = run.finished, ids = run.ids,
      fields = fields, min = run.min, sort = run.sort, first = run.first, seen = run.seen }
  end
  lulibre.store("INSERT OR REPLACE INTO kv(key, value) VALUES('runs', ?)", #out > 0 and json.encode(out) or "[]")
end

local function revive(run)
  if run.fields and run.fields[1] then
    local set = {}
    for _, f in ipairs(run.fields) do set[f] = true end
    run.fields = set
  elseif run.fields and not next(run.fields) then
    run.fields = nil
  end
  run.ids = run.ids or {}
  return run
end

--- Does proposal pr belong to the run: is it for one of its books, in one of
-- its fields, and not below the confidence it was asked to show?
-- @tparam table run
-- @tparam table pr a proposal
-- @treturn boolean
function M.covers(run, pr)
  if not run.books then
    run.books = {}
    for _, id in ipairs(run.ids) do run.books[id] = true end
  end
  return run.books[pr.book] == true and (not run.fields or run.fields[pr.field] == true)
    and (not run.min or pr.status == "accepted" or (pr.confidence or 0) >= run.min)
end

--- Did the run itself make proposal pr (a row of the proposals table)? A
-- run's view also holds what waited for its books before it began; this
-- tells the two apart, so that dropping a run takes only what it added.
-- @tparam table run
-- @tparam table pr
-- @treturn boolean
function M.own(run, pr)
  return M.covers(run, pr) and pr.id >= (run.first or math.huge) and (pr.created or 0) >= run.started
    and (not run.finished or (pr.created or 0) <= run.finished)
end

--- How many proposals wait for the run's books: to be decided, or written.
-- @tparam table run
-- @treturn integer
function M.waiting(run)
  local n = 0
  local proposals = require "lulibre.proposals"
  for _, pr in ipairs(lulibre.store("SELECT book, field, confidence, source, status, asked FROM proposals WHERE status IN ('pending', 'accepted')")) do
    if M.covers(run, pr) and proposals.shown(pr) then n = n + 1 end
  end
  return n
end

--- The runs: those going on first, then the finished ones that still have
-- something waiting, the newest first. scope ("library" or "sync") keeps to
-- the runs with a book on that side. A finished run nothing waits for any
-- more is forgotten here.
-- @tparam[opt] string scope
-- @treturn {table,...} runs
function M.list(scope)
  local out = {}
  for _, run in ipairs(live) do out[#out + 1] = run end
  local kept, all = {}, stored()
  local waiting = lulibre.store("SELECT book, field, confidence, status FROM proposals WHERE status IN ('pending', 'accepted')"
    .. require("lulibre.proposals").shown_sql())
  for _, run in ipairs(all) do
    revive(run)
    local any = false
    for _, pr in ipairs(waiting) do
      if M.covers(run, pr) then
        any = true
        break
      end
    end
    if any then kept[#kept + 1] = run end
  end
  if #kept ~= #all then store(kept) end
  for _, run in ipairs(kept) do out[#out + 1] = run end
  if not scope then return out end
  local mine = {}
  for _, run in ipairs(out) do
    local first = run.ids[1] or 0
    if (scope == "sync") == (first < 0) then mine[#mine + 1] = run end
  end
  return mine
end

--- The run review opens on when it is not told what to show: one that is
-- going on, or the newest finished one that has not been looked at yet.
-- @tparam[opt] string scope
-- @treturn table|nil
function M.fresh(scope)
  for _, run in ipairs(M.list(scope)) do
    if not run.finished or not run.seen then return run end
  end
end

--- The run has been looked at: review no longer opens on it by itself.
-- @tparam table run
function M.seen(run)
  if run.seen or not run.finished then return end
  run.seen = true
  local list = stored()
  for i, r in ipairs(list) do
    revive(r)
    if r.id == run.id then r.seen = true end
    list[i] = r
  end
  store(list)
end

--- The run going on now (the newest, if there are several), or nil.
-- @treturn table|nil
function M.running()
  return live[1]
end

--- Start a run. t: ids (the books), label (what the tab says; the time and
-- how many books when omitted), fields (a set, when not all), min and sort
-- (what review is to show, and in what order), steps (their names, in
-- order, for the badge). Returns the run; give it to step and finish.
-- @tparam table t `{ ids=, label=, fields=, min=, sort=, steps= }`
-- @treturn table the run: `{ id=, started=, ids=, label=, steps=, at=, step=, ... }`
function M.start(t)
  local now = os.time()
  local id = math.max(last + 1, now)
  while not lulibre.claim(taken, id) do id = id + 1 end
  last = math.max(last, id)
  local run = { id = id, started = now, ids = t.ids or {}, fields = t.fields, min = t.min, sort = t.sort,
    steps = t.steps or {}, at = 0, task = lulibre.task_id and lulibre.task_id() or nil,
    -- what is proposed from here on is the run's own
    first = (lulibre.store("SELECT coalesce(max(id), 0) AS n FROM proposals")[1].n or 0) + 1 }
  run.label = t.label or ("%s · %d book%s"):format(os.date("%H:%M", now), #run.ids, #run.ids == 1 and "" or "s")
  table.insert(live, 1, run)
  fire("start", run)
  return run
end

--- Join the run this task is in, or start one (t as for start). Returns a
-- handle with :step(name), to be kept in a <close> variable: when it goes
-- out of scope a run it started is finished, as done if :done() was called
-- and as stopped otherwise; a run it only joined is left to whoever began it.
-- @tparam table t
-- @treturn table the handle: `:step(name)`, `:done()`, `.run`
function M.join(t)
  local task = lulibre.task_id and lulibre.task_id() or nil
  local run, mine
  for _, r in ipairs(live) do
    if task and r.task == task then run = r end
  end
  if not run then run, mine = M.start(t), true end
  local done = false
  return setmetatable({ run = run, mine = mine or false }, {
    __index = {
      step = function(_, name)
        if mine then M.step(run, name) end
      end,
      done = function() done = true end,
    },
    __close = function()
      if mine then M.finish(run, done and "done" or "cancelled") end
    end,
  })
end

--- The run has reached the step of that name.
-- @tparam table run
-- @tparam string name
function M.step(run, name)
  run.step = name
  for i, s in ipairs(run.steps) do
    if s == name then run.at = i end
  end
  fire("step", run)
end

--- The run is over: "done" (remembered while its proposals wait), or
-- "failed" or "cancelled" (not remembered; what it had proposed still waits
-- under "all"). Safe to call twice.
-- @tparam table run
-- @tparam[opt] string state "done" when not given
function M.finish(run, state)
  if run.finished then return end
  run.finished, run.state, run.step = os.time(), state or "done", nil
  for i, r in ipairs(live) do
    if r == run then
      table.remove(live, i)
      break
    end
  end
  if run.state == "done" then
    -- an earlier run whose books are all among this one's is replaced by it:
    -- what it proposed still waits, and shows in this run's view as "from before"
    M.covers(run, { book = 0 })
    local list = { run }
    for _, r in ipairs(stored()) do
      revive(r)
      local within = not run.fields
      for _, id in ipairs(r.ids) do
        if not run.books[id] then within = false end
      end
      if not within then list[#list + 1] = r end
    end
    store(list)
  end
  fire("finish", run)
end

--- Drop a run: the proposals it made that are still waiting are deleted
-- (not rejected: they may be proposed again), and it is forgotten. What
-- waited for its books before it began stays. A run still going on is
-- stopped first. Returns how many proposals went.
-- @tparam table run
-- @treturn integer how many proposals went
function M.drop(run)
  if not run.finished then
    if run.task and lulibre.cancel then lulibre.cancel(run.task) end
    M.finish(run, "cancelled")
  end
  local gone = {}
  for _, pr in ipairs(lulibre.store("SELECT id, book, field, confidence, status, created FROM proposals WHERE status IN ('pending', 'accepted')")) do
    if M.own(run, pr) then gone[#gone + 1] = pr.id end
  end
  for from = 1, #gone, 400 do
    lulibre.store(("DELETE FROM proposals WHERE id IN (%s)"):format(table.concat(gone, ",", from, math.min(from + 399, #gone))))
  end
  local list = {}
  for _, r in ipairs(stored()) do
    if r.id ~= run.id then list[#list + 1] = revive(r) end
  end
  store(list)
  fire("drop", run)
  return #gone
end

--- What the status line says while a run is going on: the text of the badge
-- and its style (accent ok warn error dim). Return nothing for no badge.
-- Replace this function to say it your way.
-- @tparam table run
-- @treturn[opt] string the text
-- @treturn[opt] string its style
function M.badge(run)
  local where = run.step and (#run.steps > 1 and ("%s, step %d of %d"):format(run.step, run.at, #run.steps) or run.step) or "starting"
  return ("⟳ PROPOSING  %d book%s: %s"):format(#run.ids, #run.ids == 1 and "" or "s", where), "warn"
end

-- the badge follows the runs
M.on(function()
  if not lulibre.status then return end
  local run = live[1]
  local text, style
  if run then text, style = M.badge(run) end
  lulibre.status("run", text, text and style or nil)
end)

return M
