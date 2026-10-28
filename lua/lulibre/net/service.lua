--- A service as a resource (design 41): its queue, its pace, its batch
-- size, and its hold when the service says it is asked too much. A caller
-- asks about one work and waits; one task per service asks the service,
-- for as many waiting works as a request takes, no sooner than the pace
-- allows. Every answer is kept in the index's lookups (design 43).
--
-- @submodule lulibre.net
local M = {}

--- The services, by name.
M.services = {}

--- Seconds a "no such record" answer is trusted before the service is
-- asked again.
M.FORGET = 30 * 86400

--- Defines a service.
-- @tparam string name
-- @tparam table how `{ ident=, pace=, hold=, batch=, request=, record= }`:
-- ident, the identifier type it is asked by ("doi", "isbn", "arxiv");
-- pace, the seconds between two requests; hold, the seconds it is left
-- alone after it says it is asked too much; batch, the works one request
-- asks about; request(keys, mail), which returns `{ [key] = answer }` (an answer
-- is the service's text, false when it has no record), or nil, the reason,
-- and true when the service asked to be left alone (with the seconds it
-- asked for); record(answer), the fields of the record: `{ title=,
-- authors=, year=, publisher=, series=, ... }`
function M.define(name, how)
  M.services[name] = { name = name, how = how, queue = {}, answers = {}, next_at = 0, held_until = 0 }
end

local function now()
  return os.time()
end

--- The answer kept for a key: the answer, or false for "no record" still
-- trusted; nil when none is kept.
function M.kept(name, key)
  local row = lulibre.sql("SELECT answer, ts FROM lookups WHERE service = ? AND key = ?", name, key)[1]
  if not row then return nil end
  if row.answer == "" then
    if now() - (row.ts or 0) > M.FORGET then return nil end
    return false
  end
  return row.answer
end

local function keep(name, key, answer)
  lulibre.store("INSERT OR REPLACE INTO lookups(service, key, answer, ts) VALUES (?, ?, ?, ?)", name, key,
    answer or "", now())
end

-- The service's task: asks for what waits, at its pace, in batches. It
-- takes the contact address once, as it starts (design 3).
local function serve(s)
  local mail <const> = setman.get("contact_email")
  while #s.queue > 0 do
    if now() < s.held_until then
      for _, key in ipairs(s.queue) do s.answers[key] = { nil, "held back: the service asked to be left alone" } end
      s.queue = {}
      break
    end
    local wait = s.next_at - now()
    if wait > 0 then lulibre.sleep(wait * 1000) end
    local keys = {}
    while #s.queue > 0 and #keys < (s.how.batch or 1) do keys[#keys + 1] = table.remove(s.queue, 1) end
    local started = now()
    local got, err, hold = s.how.request(keys, mail)
    -- a slow answer is followed by a pause as long as it took
    s.next_at = now() + math.max(s.how.pace or 1, now() - started)
    if got then
      for _, key in ipairs(keys) do
        local answer = got[key] or false
        keep(s.name, key, answer)
        s.answers[key] = { answer }
      end
    else
      if hold then s.held_until = now() + math.max(s.how.hold or 300, tonumber(hold) or 0) end
      for _, key in ipairs(keys) do s.answers[key] = { nil, err } end
    end
  end
  s.busy = false
end

--- Asks a service about a work, and waits for the answer: kept, or asked.
-- @treturn string|false|nil the answer, false when the service has no
-- record, or nil and the reason
-- @treturn boolean true when the service was asked now, not answered from
-- what was kept
function M.ask(name, key)
  local s = M.services[name]
  if not s then return nil, "no service is called " .. name end
  local kept = M.kept(name, key)
  if kept ~= nil then return kept, false end
  s.answers[key] = nil
  table.insert(s.queue, key)
  if not s.busy then
    s.busy = true
    lulibre.spawn(function() serve(s) end, "lookups: " .. name)
  end
  while not s.answers[key] do lulibre.sleep(200) end
  local a = s.answers[key]
  s.answers[key] = nil
  if a[1] == nil then return nil, a[2] end
  return a[1], true
end

return M
