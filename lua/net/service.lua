--- A service as a resource (design 41): its queue, its pace, its batch
-- size, and its hold when the service says it is asked too much. A caller
-- asks about one work and waits; one task per service asks the service,
-- for as many waiting works as a request takes, no sooner than the pace
-- allows. Every answer is kept (design 43), for every library, in the
-- file path.netdb.
--
-- @submodule net
local sql = require "sql"

local M = {}

--- The services, by name.
M.services = {}

--- Seconds a "no such record" answer is trusted before the service is
-- asked again.
M.FORGET = 30 * 86400

--- Defines a service.
-- @tparam string name
-- @tparam table how `{ ident=, pace=, hold=, batch=, request=, record= }`:
-- ident, the identifier type it is asked by ("doi", "isbn", "arxiv"), a list of
-- them, or "title" for the book's folded title (net.keys);
-- pace, the seconds between two requests; hold, the seconds it is left
-- alone after it says it is asked too much; batch, the works one request
-- asks about; request(keys, mail), which returns `{ [key] = answer }` (an answer
-- is the service's text, false when it has no record), or nil, the reason,
-- and true when the service asked to be left alone (with the seconds it
-- asked for); record(answer, key), the fields of the record: `{ title=,
-- authors=, pubdate=, publisher=, series=, ... }`, as calibre names them
function M.define(name, how)
  M.services[name] = { name = name, how = how, queue = {}, answers = {}, asking = {}, next_at = 0, held_until = 0 }
end

local function now()
  return os.time()
end

local db

-- a statement on the file, opened (and the file made) on first use
local function run(query, ...)
  if not db then
    db = sql.open(setman.get("path.netdb"))
    db:exec("PRAGMA journal_mode=WAL;"
            .. "CREATE TABLE IF NOT EXISTS answers(service TEXT NOT NULL, key TEXT NOT NULL, answer TEXT,"
            .. " ts INTEGER, PRIMARY KEY(service, key)) WITHOUT ROWID;")
  end
  return sql.run(db, query, ...)
end

--- The answer kept for a key: the answer, or false for "no record" still
-- trusted; nil when none is kept.
function M.kept(name, key)
  local row = run("SELECT answer, ts FROM answers WHERE service = ? AND key = ?", name, key)[1]
  if not row then return nil end
  if row.answer == "" then
    if now() - (row.ts or 0) > M.FORGET then return nil end
    return false
  end
  return row.answer
end

--- Keeps an answer, as though the service had given it.
local function keep(name, key, answer)
  run("INSERT OR REPLACE INTO answers(service, key, answer, ts) VALUES (?, ?, ?, ?)", name, key, answer or "", now())
end

M.keep = keep

local serve

-- Starts the service's task unless it runs.
local function start(s)
  if s.busy then return end
  s.busy = true
  taskman.spawn(serve, s)
end

-- The service's task: asks for what waits, at its pace, in batches. It
-- takes the contact address once, as it starts (design 3). However it
-- ends, a work queued as it ended is not left without a task.
-- The answer for a key, and the tasks waiting for it woken.
local function answer(s, key, a)
  s.answers[key] = a
  for _, id in ipairs(s.asking[key] or {}) do taskman.wake(id) end
end

function serve(s)
  local keys = {}
  local _ <close> = setmetatable({}, { __close = function(_, err)
    s.busy = nil
    -- a request that ended in an error outside the service's own still answers
    for _, key in ipairs(keys) do
      if not s.answers[key] then answer(s, key, { nil, "the service's task ended: " .. tostring(err) }) end
    end
    if #s.queue > 0 then start(s) end
  end })
  local mail <const> = setman.get("contact_email")
  while #s.queue > 0 do
    if now() < s.held_until then
      for _, key in ipairs(s.queue) do answer(s, key, { nil, "held back: the service asked to be left alone" }) end
      s.queue = {}
      break
    end
    local wait = s.next_at - now()
    if wait > 0 then taskman.sleep(wait * 1000) end
    keys = {}
    while #s.queue > 0 and #keys < (s.how.batch or 1) do keys[#keys + 1] = table.remove(s.queue, 1) end
    local started = now()
    local ok, got, err, hold = pcall(s.how.request, keys, mail)
    if not ok then got, err = nil, tostring(got) end
    -- a slow answer is followed by a pause as long as it took
    s.next_at = now() + math.max(s.how.pace or 1, now() - started)
    if got then
      for _, key in ipairs(keys) do
        local a = got[key] or false
        keep(s.name, key, a)
        answer(s, key, { a })
      end
    else
      if hold then s.held_until = now() + math.max(s.how.hold or 300, tonumber(hold) or 0) end
      for _, key in ipairs(keys) do answer(s, key, { nil, err }) end
    end
  end
end

--- Asks a service about a work, and waits for the answer: kept, or asked.
-- The same work asked for by several tasks at once is asked for once.
-- @treturn string|false|nil the answer, false when the service has no
-- record, or nil and the reason
-- @treturn boolean true when the service was asked now, not answered from
-- what was kept
function M.ask(name, key)
  local s = M.services[name]
  if not s then return nil, "no service is called " .. name end
  local kept = M.kept(name, key)
  if kept ~= nil then return kept, false end
  local waiting = s.asking[key]
  if not waiting then
    waiting = {}
    s.asking[key] = waiting
    s.answers[key] = nil
    table.insert(s.queue, key)
  end
  waiting[#waiting + 1] = taskman.self()
  start(s)
  while not s.answers[key] do taskman.sleep() end
  local a = s.answers[key]
  s.asking[key] = nil
  if a[1] == nil then return nil, a[2] end
  return a[1], true
end

--- Asks a service about many works at once, so that they go in as few requests
-- as it takes; waits for all. fn(key, answer) is called for each answer that is
-- new, as it comes, and fn(key, nil, why) for each that fails.
-- @tparam string name
-- @tparam {string,...} keys
-- @tparam[opt] function fn
function M.ask_all(name, keys, fn)
  local s = M.services[name]
  if not s then return nil, "no service is called " .. name end
  local pending = {}
  for _, key in ipairs(keys) do
    if M.kept(name, key) == nil and not pending[key] then
      if not s.asking[key] then
        s.asking[key] = {}
        s.answers[key] = nil
        table.insert(s.queue, key)
      end
      table.insert(s.asking[key], taskman.self())
      pending[key] = true
    end
  end
  if not next(pending) then return true end
  start(s)
  while next(pending) do
    taskman.sleep()
    for key in pairs(pending) do
      local a = s.answers[key]
      if a then
        pending[key] = nil
        s.asking[key] = nil
        if fn then
          if a[1] == nil then fn(key, nil, a[2]) else fn(key, a[1]) end
        end
      end
    end
  end
  return true
end

return M
