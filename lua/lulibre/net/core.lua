--- Holds the code lulibre.net's services share: how often each service is
-- asked, the stored answers, fetching, and helpers. Require lulibre.net,
-- not this file: lulibre.net is this table, with each service's functions
-- added from lulibre/net/*.lua.
--
-- @submodule lulibre.net

local M = {}

--- The seconds between two requests to one service, counted from the end
-- of one request to the start of the next. Only one request runs at a time.
-- Each pace is well within what the service asks of callers who do not
-- identify themselves:
--   arXiv         "no more than one request every three seconds", "a single connection at a time"
--                 (https://info.arxiv.org/help/api/tou.html)
--   CrossRef      public pool: 5 requests a second, one at a time; "Back off if the response times start to increase"
--                 (https://www.crossref.org/documentation/retrieve-metadata/rest-api/access-and-authentication/)
--   Open Library  "1 request per second" unidentified; "do not use our APIs to bulk download metadata"
--                 (https://openlibrary.org/developers/api)
--   OpenAlex      10 requests a second without a key, and a daily budget
--                 (https://help.openalex.org/how-to-use-the-api/rate-limits-and-authentication)
--   zbMATH Open   "keeping the number of HTTP requests per second to a reasonable rate"; when it is
--                 "heavily loaded ... the use has to be retried" (its API's terms of June 2021,
--                 https://static.zbmath.org/legal/api-terms-and-conditions.html; the data is CC-BY-SA 4.0)
-- A slow answer is followed by a pause as long as the request took, so a
-- service under load is asked less.
M.PACE = { arxiv = 5, crossref = 1, zbmath = 2, openlibrary = 2, openalex = 1 }

--- How many seconds a service is left alone after it answers "too many
-- requests" (HTTP 429) or "unavailable" (503). If the service's Retry-After
-- is longer, that is used. Nothing is retried in the meantime; the next run
-- picks up the books.
M.HOLD = { arxiv = 1800, default = 300 }

--- How many arXiv numbers go in one request.
M.ARXIV_BATCH = 40

--- How many days a "no such record" answer is trusted before the service
-- is asked again.
M.FORGET_DAYS = 30

--- If true, answers come only from storage, and no service is asked.
M.offline = false
--- Counts of requests made, answers found in storage, and requests by service.
M.stats = { asked = 0, kept = 0, by = {} }

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function unescape(s)
  return (s:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&#39;", "'"):gsub("&amp;", "&"))
end

local function encode(s)
  return (s:gsub("[^%w%-%._~]", function(c) return ("%%%02X"):format(c:byte()) end))
end

--- Returns the User-Agent that requests send.
-- @treturn string the User-Agent
function M.agent()
  local mail = lulibre.o.contact_email or ""
  return ("lulibre/%s (library metadata lookup%s)"):format(lulibre.version, mail ~= "" and "; mailto:" .. mail or "")
end

--- Fetches a URL with GET. Returns nil and a message if nothing came back.
-- @tparam string url
-- @treturn[1] string the body
-- @treturn[1] integer the HTTP status
-- @treturn[1] string|nil the Retry-After header, if any
-- @treturn[2] nil
-- @treturn[2] string the message
function M.get(url)
  local r, err = lulibre.system({ "curl", "-sS", "-L", "--max-time", "25", "-A", M.agent(), "-w",
    "\n%{http_code} %header{retry-after}", url }, { timeout = 30000 })
  if not r then return nil, err end
  if r.code ~= 0 then return nil, trim(r.stderr) ~= "" and trim(r.stderr) or ("curl exited " .. r.code) end
  local body, status, after = r.stdout:match("^(.*)\n(%d%d%d) ?([^\n]*)$")
  return body or r.stdout, tonumber(status) or 0, tonumber(after and after:match("^%s*(%d+)%s*$"))
end

local function mark(key)
  local row = lulibre.sql("SELECT value FROM kv WHERE key = ?", key)[1]
  return row and tonumber(row.value)
end

local last, busy, took = {}, {}, {}

local function monotonic()
  local ok, uv = pcall(require, "luv")
  return ok and uv.hrtime() / 1e9 or os.time()
end

-- Wait this service's turn: one request at a time, PACE apart. The time of
-- the last request is also kept in the index, so that another lulibre (a
-- script run beside the interface, or the same command run again at once)
-- keeps to the same pace.
local function turn(service)
  -- (a test and a set in one step: two tasks must not both find it free)
  while not lulibre.claim(busy, service) do lulibre.sleep(50) end
  -- no sooner than the pace, nor sooner than the last answer took to come
  local pace = math.min(60, math.max(M.PACE[service] or 1, took[service] or 0))
  local wait = (last[service] or -math.huge) + pace - monotonic()
  local elsewhere = mark("net.last." .. service)
  -- the clock on the wall counts in whole seconds: allow one more
  if elsewhere then wait = math.max(wait, elsewhere + math.ceil(pace) + 1 - os.time()) end
  if wait > 0 then lulibre.sleep(math.ceil(math.min(wait, pace + 2) * 1000)) end
end

local function done(service)
  last[service] = monotonic()
  lulibre.store("INSERT OR REPLACE INTO kv(key, value) VALUES(?, ?)", "net.last." .. service, tostring(os.time()))
  busy[service] = nil
end

--- Returns the time until which a service is left alone (as os.time gives
-- it), or nil if the service may be asked now.
-- @tparam string service
-- @treturn integer|nil
function M.held(service)
  local till = mark("net.hold." .. service)
  return till and till > os.time() and till or nil
end

--- Leaves a service alone for a number of seconds.
-- @tparam string service
-- @tparam number seconds 0 allows asking again
function M.hold(service, seconds)
  if seconds <= 0 then
    lulibre.store("DELETE FROM kv WHERE key = ?", "net.hold." .. service)
  else
    lulibre.store("INSERT OR REPLACE INTO kv(key, value) VALUES(?, ?)", "net.hold." .. service, tostring(os.time() + seconds))
  end
end

local function paused(service, till)
  return ("%s asked for a pause: it is not asked again before %s"):format(service, os.date("%H:%M", till))
end

--- Makes one request to a service, waiting for the service's turn. A
-- service that says it is asked too much is left alone for a while (see
-- `HOLD`); until then, `request` returns nil and says so.
-- @tparam string service
-- @tparam string url
-- @treturn[1] string the body
-- @treturn[1] integer the status
-- @treturn[2] nil
-- @treturn[2] string why
function M.request(service, url)
  local till = M.held(service)
  if till then return nil, paused(service, till) end
  turn(service)
  local began = monotonic()
  local ok, body, status, after = pcall(M.get, url)
  took[service] = monotonic() - began
  done(service)
  M.stats.asked = M.stats.asked + 1
  M.stats.by[service] = (M.stats.by[service] or 0) + 1
  if not ok then return nil, tostring(body) end
  if not body then return nil, tostring(status) end
  if status == 429 or status == 503 then
    M.hold(service, math.max(after or 0, M.HOLD[service] or M.HOLD.default))
    local why = paused(service, M.held(service) or os.time())
    lulibre.log(("%s answered %d (%s): %s"):format(service, status, trim(body):sub(1, 60), why), "warn")
    return nil, why
  end
  return body, status
end

--- Returns what is stored for a service's key: the body, or false if the
-- service was asked and had nothing. Returns nil if the service has not
-- been asked, or said "nothing" long enough ago to be asked again.
-- @tparam string service
-- @tparam string key
-- @treturn string|false|nil
function M.kept(service, key)
  local row = lulibre.sql("SELECT status, body, at FROM lookups WHERE service = ? AND key = ?", service, key)[1]
  if not row then return nil end
  if row.status == 200 then return row.body end
  if (row.at or 0) < os.time() - M.FORGET_DAYS * 86400 then return nil end
  return false
end

--- Stores an answer.
-- @tparam string service
-- @tparam string key
-- @tparam integer status
-- @tparam string|nil body
function M.keep(service, key, status, body)
  lulibre.store("INSERT OR REPLACE INTO lookups(service, key, at, status, body) VALUES(?, ?, ?, ?, ?)", service, key,
    os.time(), status, status == 200 and body or nil)
end

-- what was asked for and not answered, and when: it is not asked for again
-- within the hour, however often a caller wants it
local unanswered = {}

local function gave_up(service, key)
  local at = unanswered[service .. "\0" .. key]
  return at ~= nil and monotonic() - at < 3600
end

local function give_up(service, key)
  unanswered[service .. "\0" .. key] = monotonic()
end

--- Returns the body a service gives for a key: from storage if the service
-- was asked before, or else fetched from `url` and stored.
-- @tparam string service
-- @tparam string key
-- @tparam string url
-- @treturn[1] string the body
-- @treturn[2] nil
-- @treturn[2] string why
function M.fetch(service, key, url)
  local kept = M.kept(service, key)
  if kept then
    M.stats.kept = M.stats.kept + 1
    return kept
  elseif kept == false then
    M.stats.kept = M.stats.kept + 1
    return nil, ("%s has no record of %s"):format(service, key)
  end
  if M.offline then return nil, ("%s has not been asked about %s (offline)"):format(service, key) end
  local till = M.held(service)
  if till then return nil, paused(service, till) end
  if gave_up(service, key) then return nil, ("%s gave no answer about %s a moment ago"):format(service, key) end
  local body, status = M.request(service, url)
  if not body then
    give_up(service, key)
    return nil, status
  end
  if status == 200 then
    M.keep(service, key, 200, body)
    return body
  elseif status == 404 or status == 400 then
    M.keep(service, key, 404)
    return nil, ("%s has no record of %s"):format(service, key)
  end
  give_up(service, key)
  return nil, ("%s answered %d"):format(service, status) -- not kept: it may answer another day
end

-- Ask a service about many keys, `size` to a request. url_of(keys) is the
-- request for some of them; take(keys, body) gives { key = what to keep for
-- it }, or nil when the answer is not a whole one. A key a whole answer does
-- not hold is remembered as not there. A request that fails is not made
-- again, and its keys are not then asked for one by one. Returns how many
-- answers were newly kept.
local function in_batches(service, keys, size, url_of, take)
  local want, have = {}, {}
  for _, key in ipairs(keys) do
    if not have[key] and M.kept(service, key) == nil and not gave_up(service, key) then
      want[#want + 1] = key
      have[key] = true
    end
  end
  if M.offline then return 0 end
  local got = 0
  for from = 1, #want, size do
    local chunk = { table.unpack(want, from, math.min(from + size - 1, #want)) }
    local body, status = M.request(service, url_of(chunk))
    local found = body and status == 200 and take(chunk, body) or nil
    for _, key in ipairs(chunk) do
      if found and found[key] then
        M.keep(service, key, 200, found[key])
        got = got + 1
      elseif found then
        M.keep(service, key, 404)
      else
        give_up(service, key)
      end
    end
    if not body and M.held(service) then break end -- told to wait: the rest is not sent either
  end
  return got
end

-- ---- shared by the services (lulibre/net/*.lua) ----

local function file_time(path)
  local ok, uv = pcall(require, "luv")
  local st = ok and uv.fs_stat(path)
  return st and st.mtime and st.mtime.sec or 0
end

-- "Wiles, Andrew" the right way round
local function forename_first(name)
  local family, given = name:match("^([^,]+),%s*(.+)$")
  return family and (trim(given) .. " " .. trim(family)) or name
end

-- The lines of a file that hold any of some strings. grep does the reading,
-- which it is built for, through gzip when the file is packed: the dumps
-- are tens of gigabytes unpacked and a few hundred lines are wanted.
-- Returns the lines and whether the file was read to its end (a file still
-- being fetched is not), or nil and why.
local function lines_with(path, strings)
  local patterns, errors = os.tmpname(), os.tmpname()
  local f = assert(io.open(patterns, "w"))
  f:write(table.concat(strings, "\n"), "\n")
  f:close()
  local reader = path:match("%.gz$") and 'gzip -dc "$1" 2>"$3"' or 'cat "$1" 2>"$3"'
  local r, err = lulibre.system({ "sh", "-c", reader .. ' | LC_ALL=C grep -F -f "$2"', "sh", path, patterns, errors }, { timeout = 2 * 3600 * 1000 })
  local ef = io.open(errors, "r")
  local complaint = ef and ef:read("a") or ""
  if ef then ef:close() end
  os.remove(patterns)
  os.remove(errors)
  if not r then return nil, tostring(err) end
  if r.code > 1 then return nil, trim(r.stderr or "") ~= "" and trim(r.stderr) or ("grep exited " .. r.code) end
  local lines = {}
  for line in (r.stdout or ""):gmatch("[^\n]+") do lines[#lines + 1] = line end
  return lines, trim(complaint) == ""
end

local function missed(service, key, stamp)
  local row = lulibre.sql("SELECT at FROM lookups WHERE service = ? AND key = ?", service, key)[1]
  return row ~= nil and stamp > 0 and (row.at or 0) >= stamp
end

-- for the services' modules: lulibre's own plumbing (names that begin with _)
M._trim = trim
M._unescape = unescape
M._encode = encode
M._mark = mark
M._paused = paused
M._gave_up = gave_up
M._give_up = give_up
M._in_batches = in_batches
M._file_time = file_time
M._forename_first = forename_first
M._lines_with = lines_with
M._missed = missed

return M
