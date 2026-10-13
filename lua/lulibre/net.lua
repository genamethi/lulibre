-- Metadata services: what arXiv, CrossRef, zbMATH Open, Open Library and
-- OpenAlex say about a work that has an identifier. None of them needs an
-- account or a key.
--
-- Everything that is fetched is kept (the table `lookups`), so a work is
-- asked about once: a later run, or the same question from another book, is
-- answered from what was kept, and with M.offline set nothing is asked at
-- all.
--
-- These services are other people's, and free. Each is asked one thing at a
-- time and no faster than M.PACE, whatever else is going on; many works go
-- in one request where the service takes them (arXiv, CrossRef, Open
-- Library); one that says it is asked too much is left alone (M.HOLD) and
-- nothing is retried; and no failure is answered by asking more.
--
-- Every function here waits, so call them from a task. Each gives a record
--
--   { title=, authors={...}, year=, date="YYYY-MM-DD", publisher=, series=, series_index=,
--     subjects={ {tag=, confidence=, why=}, ... }, ids={ doi=, isbn=, arxiv=, zbl= }, type=, source= }
--
-- with whatever the service knows, or nil and why not.
--
--   net.arxiv("1012.6008")            net.crossref("10.2307/2118559")
--   net.zbmath { doi = "10.2307/2118559" }     net.zbmath { arxiv = "1012.6008" }
--   net.openlibrary("9780387900407")  net.openalex("10.2307/2118559")
--   net.arxiv_prefetch { "1012.6008", "hep-th/9711200" }    -- many in one request;
--   net.crossref_prefetch(dois)  net.openlibrary_prefetch(isbns)   -- likewise
--   net.offline = true                -- answer from what is kept, or not at all
--
-- The option contact_email, when set, is sent with each request (in the
-- User-Agent, and as CrossRef's `mailto`): CrossRef and Open Library give
-- more room to callers they can reach. It is empty unless you set it.
local detex = require "lulibre.detex"
local json = require "lulibre.json"
local taxonomy = require "lulibre.taxonomy"

local M = {}

-- Seconds between two requests to one service, counted from the end of one
-- to the start of the next; one request at a time. Each is well inside what
-- the service asks of callers who do not identify themselves:
--   arXiv         "no more than one request every three seconds", "a single connection at a time"
--                 (https://info.arxiv.org/help/api/tou.html)
--   CrossRef      public pool: 5 requests a second, one at a time; "Back off if the response times start to increase"
--                 (https://www.crossref.org/documentation/retrieve-metadata/rest-api/access-and-authentication/)
--   Open Library  "1 request per second" unidentified; "do not use our APIs to bulk download metadata"
--                 (https://openlibrary.org/developers/api)
--   OpenAlex      10 requests a second without a key, and a daily budget
--                 (https://help.openalex.org/how-to-use-the-api/rate-limits-and-authentication)
--   zbMATH Open   its terms could not be read when this was written; asked as slowly as arXiv allows
-- A request that was slow to be answered is followed by a pause as long as
-- it took, so that a service under load is asked less.
M.PACE = { arxiv = 5, crossref = 1, zbmath = 3, openlibrary = 2, openalex = 1 }

-- A service that answers "too many requests" (HTTP 429) or "unavailable"
-- (503) is not asked again for this many seconds, or for as long as it says
-- (Retry-After) if that is longer. Nothing is retried in the meantime: the
-- books it was wanted for are picked up by the next run.
M.HOLD = { arxiv = 1800, default = 300 }

-- how many arXiv numbers go in one request
M.ARXIV_BATCH = 40

-- "no such record" is believed for this many days, then asked again
M.FORGET_DAYS = 30

M.offline = false
-- requests made, answers found already kept, and requests by service
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

--- What requests say they come from.
function M.agent()
  local mail = lulibre.o.contact_email or ""
  return ("lulibre/%s (library metadata lookup%s)"):format(lulibre.version, mail ~= "" and "; mailto:" .. mail or "")
end

--- GET a URL. Returns the body, the HTTP status and what the Retry-After
-- header said (if anything), or nil and a message when nothing came back.
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
  while busy[service] do lulibre.sleep(50) end
  busy[service] = true
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

--- Until when a service is not to be asked (a time, as os.time gives it), or
-- nil when it may be.
function M.held(service)
  local till = mark("net.hold." .. service)
  return till and till > os.time() and till or nil
end

--- Stop asking a service for a number of seconds (0: ask again).
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

--- One request to a service, in its turn. Returns the body and the status,
-- or nil and why. A service that says it is being asked too much is left
-- alone for a while (M.HOLD), and says so here until then.
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

--- What is kept for a key of a service: the body, or false when the service
-- was asked and had nothing; nil when it has not been asked (or said "nothing"
-- so long ago that it is worth asking again).
function M.kept(service, key)
  local row = lulibre.sql("SELECT status, body, at FROM lookups WHERE service = ? AND key = ?", service, key)[1]
  if not row then return nil end
  if row.status == 200 then return row.body end
  if (row.at or 0) < os.time() - M.FORGET_DAYS * 86400 then return nil end
  return false
end

--- Keep an answer.
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

--- The body a service gives for a key: from what is kept if it has been
-- asked before, else from `url` (and kept). nil and why when there is none.
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

-- ---- arXiv ----
-- Its API: https://info.arxiv.org/help/api/user-manual.html (id_list is "a
-- comma-delimited list of arXiv id's"; "Please cache your results"), under
-- the terms at https://info.arxiv.org/help/api/tou.html.

local function arxiv_record(entry)
  local title = entry:match("<title[^>]*>(.-)</title>")
  if not title or trim(title) == "Error" then return nil end
  local authors = {}
  for name in entry:gmatch("<name>(.-)</name>") do authors[#authors + 1] = detex.plain(unescape(trim(name))) end
  local class = entry:match('primary_category[^>]-term="([^"]+)"')
  local date = entry:match("<published>(%d%d%d%d%-%d%d%-%d%d)")
  -- titles are held as their authors typed them, TeX and all
  local plain, clean = detex.plain(unescape(trim(title):gsub("%s+", " ")))
  local rec = {
    title = plain, title_tex = not clean or nil, authors = authors, class = class,
    year = tonumber(date and date:sub(1, 4)), date = date, subjects = {}, ids = {}, type = "preprint",
    summary = unescape(trim(entry:match("<summary[^>]*>(.-)</summary>") or ""):gsub("%s+", " ")),
  }
  local doi = entry:match("<arxiv:doi[^>]*>(.-)</arxiv:doi>")
  if doi then rec.ids.doi = trim(doi) end
  local subject = taxonomy.from_arxiv(class)
  if subject then rec.subjects[1] = { tag = subject, confidence = 0.95, why = "arXiv class " .. class } end
  return rec
end

local WEEKDAY_MONTH = { Jan = 1, Feb = 2, Mar = 3, Apr = 4, May = 5, Jun = 6, Jul = 7, Aug = 8, Sep = 9, Oct = 10, Nov = 11, Dec = 12 }

-- A record as arXiv's metadata snapshot holds it: one JSON object to a line,
--   {"id":"0704.0001","authors":"C. Bal\\'azs, E. L. Berger","title":"...","doi":"...","categories":"hep-ph math.AG",
--    "versions":[{"version":"v1","created":"Mon, 2 Apr 2007 19:18:42 GMT"}],"authors_parsed":[["Balázs","C.",""]], ...}
local function snapshot_record(line)
  local ok, j = pcall(json.decode, line)
  if not ok or type(j) ~= "table" or type(j.title) ~= "string" then return nil end
  local authors = {}
  for _, name in ipairs(type(j.author_names) == "table" and j.author_names or {}) do
    if type(name) == "string" and trim(name) ~= "" then authors[#authors + 1] = trim(name) end
  end
  for _, a in ipairs(#authors == 0 and type(j.authors_parsed) == "table" and j.authors_parsed or {}) do
    if type(a) == "table" and type(a[1]) == "string" then
      -- { family, given, suffix }
      local name = trim(((type(a[2]) == "string" and a[2] or "") .. " " .. a[1] .. " " .. (type(a[3]) == "string" and a[3] or "")):gsub("%s+", " "))
      if name ~= "" then authors[#authors + 1] = name end
    end
  end
  if #authors == 0 and type(j.authors) == "string" then
    for name in (j.authors:gsub("%s+and%s+", ", ") .. ","):gmatch("%s*([^,]+),") do authors[#authors + 1] = trim(name) end
  end
  -- the first version is the submission
  local first = type(j.versions) == "table" and type(j.versions[1]) == "table" and j.versions[1].created
  local day, month, year = (type(first) == "string" and first or ""):match("(%d%d?)%s+(%a%a%a)%s+(%d%d%d%d)")
  local date = WEEKDAY_MONTH[month or ""] and ("%s-%02d-%02d"):format(year, WEEKDAY_MONTH[month], tonumber(day)) or nil
  local class = type(j.categories) == "string" and j.categories:match("^%S+") or nil
  for i, name in ipairs(authors) do authors[i] = detex.plain(name) end
  local plain, clean = detex.plain(trim(j.title:gsub("%s+", " ")))
  local rec = {
    -- with no day of submission, the number still says the year
    title = plain, title_tex = not clean or nil, authors = authors, class = class,
    year = tonumber(date and date:sub(1, 4)) or (type(j.id) == "string" and require("lulibre.ids").arxiv_year(j.id) or nil),
    date = date, subjects = {}, ids = {}, type = "preprint",
    summary = type(j.abstract) == "string" and trim(j.abstract:gsub("%s+", " ")) or "",
  }
  if j.unordered and #authors > 1 then rec.authors_unordered = true end
  if type(j.doi) == "string" and j.doi ~= "" then rec.ids.doi = trim(j.doi) end
  local subject = class and taxonomy.from_arxiv(class)
  if subject then rec.subjects[1] = { tag = subject, confidence = 0.95, why = "arXiv class " .. class } end
  return rec
end

--- An arXiv number as arXiv itself writes it, or nil if it is not one:
-- without a version ("1012.6008v2" is "1012.6008") and, for the numbers of
-- before April 2007, without the subject class ("math.AG/0601001" is
-- "math/0601001").
function M.arxiv_id(id)
  id = trim(tostring(id)):gsub("^[aA][rR][xX][iI][vV]:", ""):gsub("v%d+$", "")
  if id:match("^%d%d%d%d%.%d%d%d%d%d?$") then return id end
  local archive, number = id:match("^([%a%-]+)%.?%u*/(%d%d%d%d%d%d%d)$")
  return archive and (archive:lower() .. "/" .. number) or nil
end

-- "http://arxiv.org/abs/hep-th/9711200v3" -> "hep-th/9711200"
local function entry_id(entry)
  local id = entry:match("<id>%s*https?://arxiv%.org/abs/(.-)%s*</id>")
  return id and M.arxiv_id(id)
end

--- The requests arXiv would be sent for these numbers: one URL for each
-- M.ARXIV_BATCH of them, with the numbers each asks for.
function M.arxiv_urls(ids)
  local out = {}
  for from = 1, #ids, M.ARXIV_BATCH do
    local chunk = { table.unpack(ids, from, math.min(from + M.ARXIV_BATCH - 1, #ids)) }
    -- the numbers as they are, with commas between: letters, digits, dots, a
    -- hyphen and a slash, none of which a URL needs to have escaped
    out[#out + 1] = { ids = chunk, url = ("https://export.arxiv.org/api/query?id_list=%s&start=0&max_results=%d"):format(
      table.concat(chunk, ","), #chunk) }
  end
  return out
end

--- Take what an answer from arXiv holds for the numbers that were asked for:
-- each record is kept, and a number it has no record of is remembered as
-- such, but only when the answer is a whole one. Returns how many records.
function M.arxiv_take(asked, body)
  local seen, got = {}, 0
  for entry in body:gmatch("<entry>(.-)</entry>") do
    local id = entry_id(entry)
    if id and arxiv_record(entry) then
      M.keep("arxiv", id, 200, "<entry>" .. entry .. "</entry>")
      seen[id] = true
      got = got + 1
    end
  end
  -- An answer cut short, an error, or an empty one to a question about many
  -- numbers is not arXiv saying that it has none of them.
  local whole = body:find("</feed>", 1, true) ~= nil and not body:find("arxiv.org/api/errors", 1, true)
  local total = tonumber(body:match("<opensearch:totalResults[^>]*>%s*(%d+)"))
  for _, id in ipairs(asked) do
    if not seen[id] then
      if whole and (got > 0 or (#asked == 1 and total == 0)) then
        M.keep("arxiv", id, 404)
      else
        give_up("arxiv", id)
      end
    end
  end
  return got
end

--- Ask arXiv about many numbers in as few requests as it takes, keeping each
-- answer; M.arxiv then answers from what was kept. Returns how many were
-- newly fetched. A request that fails is not made again, and none of its
-- numbers is asked for one by one.
function M.arxiv_prefetch(ids)
  local want, have = {}, {}
  for _, raw in ipairs(ids) do
    local id = M.arxiv_id(raw)
    if id and not have[id] and M.kept("arxiv", id) == nil and not gave_up("arxiv", id) then
      want[#want + 1] = id
      have[id] = true
    end
  end
  if M.offline or #want == 0 then return 0 end
  local got = 0
  for _, req in ipairs(M.arxiv_urls(want)) do
    local body, status = M.request("arxiv", req.url)
    if body and status == 200 then
      got = got + M.arxiv_take(req.ids, body)
    else
      for _, id in ipairs(req.ids) do give_up("arxiv", id) end
      if M.held("arxiv") then
        -- told to wait: the batches after this one are not sent either
        break
      end
    end
  end
  return got
end

-- The file as arXiv's own snapshot: one paper to a line.
local function scan_lines(f, want, left, progress)
  local found, lines = 0, 0
  for line in f:lines() do
    lines = lines + 1
    -- the number is looked for without decoding the line: there are millions
    local id = line:match('^%s*{%s*"id"%s*:%s*"([^"]+)"') or line:match('"id"%s*:%s*"([^"]+)"')
    id = id and M.arxiv_id(id)
    if id and want[id] and snapshot_record(line) then
      M.keep("arxiv", id, 200, line)
      want[id] = nil
      found, left = found + 1, left - 1
      if left == 0 then break end
    end
    if progress and lines % 200000 == 0 then progress(("%.1f million papers"):format(lines / 1e6)) end
  end
  return found, lines
end

-- The file as a hypergraph of arXiv (the Hypergraph Interchange Format, one
-- JSON document set out over many lines): each paper an "edge" with its
-- title, classes and date of last change, then each author of each paper as
-- an "incidence" of a "node" on that edge:
--   "edges": [ { "attrs": { "title": ..., "categories": ["math.NT"], "date": "2020-08-28" }, "edge": "2002.08172" }, ... ],
--   "incidences": [ { "edge": "2002.08172", "node": "A. N. Other" }, ... ]
-- It is read in pieces of whole records, looking only for the numbers that
-- are wanted; nothing of it is held in memory but those.
local function scan_hypergraph(f, want, progress)
  local papers, authors, n = {}, {}, 0
  local carry, bytes, in_authors = "", 0, false
  while true do
    local chunk = f:read(1 << 23)
    local buf = chunk and (carry .. chunk) or carry
    local cut = #buf
    if chunk then
      -- up to where the last whole record ends; the rest waits for the next piece
      local from, last = math.max(1, #buf - (1 << 18)), nil
      while true do
        local at = buf:find("\n    {\n", from, true)
        if not at then break end
        last, from = at, at + 1
      end
      cut = last or 0
      bytes = bytes + #chunk
    end
    local part = buf:sub(1, cut)
    carry = buf:sub(cut + 1)
    local turns = part:find('\n  "incidences": [', 1, true)
    if not in_authors then
      -- a paper: everything from the brace that opens it to its number
      local prev = 1
      while true do
        local a, e, raw = part:find('\n      "edge": "([^"\n]+)"\n', prev)
        if not a then break end
        n = n + 1
        local id = want[raw] and raw or nil -- the file writes numbers as arXiv does
        if id then
          local slice = part:sub(prev, e - 1)
          local open = slice:find("    {\n", 1, true)
          local ok, obj = pcall(json.decode, open and (slice:sub(open) .. "}") or "")
          if ok and type(obj) == "table" and type(obj.attrs) == "table" and type(obj.attrs.title) == "string" then papers[id] = obj.attrs end
        end
        prev = e
      end
    end
    if in_authors or turns then
      -- millions of these, a few of them wanted: the name is read only for those
      for raw, at in part:gmatch('\n      "edge": "([^"\n]+)",()') do
        if want[raw] then
          local node = part:match('^\n      "node": "([^\n]*)"\n', at)
          if node then
            local ok, name = pcall(json.decode, '"' .. node .. '"')
            authors[raw] = authors[raw] or {}
            table.insert(authors[raw], ok and type(name) == "string" and name or node)
          end
        end
      end
    end
    in_authors = in_authors or turns ~= nil
    if progress then progress(("%.1f GB"):format(bytes / 1e9)) end
    if not chunk then break end
  end
  local found = 0
  for id, attrs in pairs(papers) do
    local classes = type(attrs.categories) == "table" and table.concat(attrs.categories, " ") or attrs.categories
    -- a hypergraph has no first author: the names come in no order
    M.keep("arxiv", id, 200, json.encode { id = id, title = attrs.title, categories = classes, author_names = authors[id] or {}, unordered = true,
      abstract = type(attrs.abstract) == "string" and attrs.abstract or nil, update_date = attrs.date })
    want[id] = nil
    found = found + 1
  end
  return found, n
end

local function file_time(path)
  local ok, uv = pcall(require, "luv")
  local st = ok and uv.fs_stat(path)
  return st and st.mtime and st.mtime.sec or 0
end

--- Where arXiv's records are looked for on this machine: the option
-- arxiv_snapshot, else a file named arxiv-metadata-oai-snapshot.json,
-- arxiv.json or arxiv.zip in lulibre's data folder (beside the index; a link
-- to the file will do). nil when there is none.
function M.arxiv_snapshot_path()
  local set = lulibre.o.arxiv_snapshot or ""
  if set ~= "" then return set end
  local dir = lulibre.settings.paths().data_dir
  -- arXiv's own snapshot first: it says more than a hypergraph of it does
  for _, name in ipairs { "arxiv-metadata-oai-snapshot.json", "arxiv.json", "arxiv.zip" } do
    local f = dir and io.open(dir .. "/" .. name, "r")
    if f then
      f:close()
      return dir .. "/" .. name
    end
  end
  return nil
end

--- Read papers' records out of a file of arXiv's metadata instead of asking
-- arXiv. Two kinds of file are read, told apart by how they begin:
--   * arXiv's own snapshot (on Kaggle as arxiv-metadata-oai-snapshot.json):
--     every paper, one JSON object to a line, with its DOI and the day of
--     each version;
--   * a hypergraph of arXiv (papers as edges, authors as nodes): title,
--     authors and classes, but no DOI and no day of submission.
-- path: the file, or the .zip it comes in. ids: the numbers wanted. The file
-- is read through once, each record found is kept as an answer from arXiv,
-- and a number it does not hold is left to be asked for (the paper may be
-- newer than the file) and not looked for again until the file changes.
-- progress(text): called now and then with how far the reading is. Returns
-- how many were found and how many papers were passed, or nil and why.
function M.arxiv_snapshot(path, ids, progress)
  local zip = path:lower():match("%.zip$") ~= nil
  local function open()
    if zip then return io.popen("unzip -p '" .. path:gsub("'", "'\\''") .. "' 2>/dev/null", "r") end
    return io.open(path, "r")
  end
  local f, err = open()
  if not f then return nil, ("cannot read %s: %s"):format(path, tostring(err)) end
  local head = f:read(4096) or ""
  f:close()
  if head == "" then return nil, ("%s is empty"):format(path) end
  local kind
  if head:find('"network%-type"') or head:find('^%s*{%s*"metadata"') or head:find('"edges"%s*:%s*%[') then
    kind = "hypergraph"
  elseif head:find('^%s*{%s*"id"%s*:') or head:find('"authors_parsed"') or head:find('"versions"') then
    kind = "lines"
  else
    return nil, ("%s is not a file of arXiv's records that lulibre knows how to read"):format(path)
  end

  local stamp = file_time(path)
  local want, left = {}, 0
  for _, raw in ipairs(ids) do
    local id = M.arxiv_id(raw)
    local kept = id and M.kept("arxiv", id)
    -- A record that came from a hypergraph (no order of authors, no DOI, no
    -- day) is looked for again in arXiv's own snapshot, which has them.
    local poorer = kind == "lines" and type(kept) == "string" and kept:find('"unordered":true', 1, true) ~= nil
    if id and not want[id] and (not kept or poorer) then
      local missed = lulibre.sql("SELECT at FROM lookups WHERE service = 'arxiv-snapshot' AND key = ?", id)[1]
      if not (missed and stamp > 0 and (missed.at or 0) >= stamp) then
        want[id] = true
        left = left + 1
      end
    end
  end
  if left == 0 then return 0, 0 end
  f = assert(open())
  local found, passed
  if kind == "hypergraph" then
    found, passed = scan_hypergraph(f, want, progress)
  else
    found, passed = scan_lines(f, want, left, progress)
  end
  f:close()
  -- what the file does not hold is not looked for in it again
  for id in pairs(want) do
    -- (a record of the hypergraph's that this file did not better counts as not held, too)
    M.keep("arxiv-snapshot", id, 404)
  end
  return found, passed
end

--- arXiv's record for a number ("1012.6008", "hep-th/9711200"; a version is ignored).
function M.arxiv(raw)
  local id = M.arxiv_id(raw)
  if not id then return nil, ("'%s' is not an arXiv number"):format(tostring(raw)) end
  local kept = M.kept("arxiv", id)
  if kept == nil then
    M.arxiv_prefetch { id }
    kept = M.kept("arxiv", id)
  else
    M.stats.kept = M.stats.kept + 1
  end
  if kept == nil then
    if M.offline then return nil, ("arxiv has not been asked about %s (offline)"):format(id) end
    local till = M.held("arxiv")
    return nil, till and paused("arxiv", till) or ("arXiv gave no answer about " .. id)
  end
  -- kept as arXiv's API gave it (an Atom entry), or as its snapshot holds it (JSON)
  local rec = kept and (kept:find("^%s*{") and snapshot_record(kept) or arxiv_record(kept))
  if not rec then return nil, "arXiv has no record of " .. id end
  rec.ids.arxiv, rec.source = id, "arXiv " .. id
  return rec
end

--- Put names that came in no order into the order a text has them in (a
-- paper's first page names its authors in order): by where each family name
-- first stands in the text. Returns the names, and whether every one of
-- them was found (so that the order can be trusted).
function M.in_order_of(authors, text)
  local folded = lulibre.fold(text or "")
  local at, all = {}, true
  for i, name in ipairs(authors) do
    local family = lulibre.fold(name:match("([^%s]+)%s*$") or name)
    local pos = #family >= 2 and folded:find(family, 1, true) or nil
    if not pos then all = false end
    at[name] = { pos or math.huge, i }
  end
  local out = { table.unpack(authors) }
  table.sort(out, function(a, b)
    if at[a][1] ~= at[b][1] then return at[a][1] < at[b][1] end
    return at[a][2] < at[b][2]
  end)
  return out, all
end

-- ---- CrossRef ----

local BOOKISH = { book = true, monograph = true, ["edited-book"] = true, ["reference-book"] = true, ["book-chapter"] = true }

local function crossref_record(m)
  local authors = {}
  for _, a in ipairs(m.author or {}) do
    local name = trim((a.given or "") .. " " .. (a.family or a.name or ""))
    if name ~= "" then authors[#authors + 1] = name end
  end
  local issued = m.issued and m.issued["date-parts"] and m.issued["date-parts"][1]
  local year = issued and issued[1]
  local rec = {
    title = m.title and m.title[1] and unescape(m.title[1]:gsub("%s+", " ")) or nil,
    authors = authors, year = year, type = m.type, subjects = {},
    ids = { doi = m.DOI, isbn = m.ISBN and m.ISBN[1] and m.ISBN[1]:gsub("[^%dXx]", "") or nil },
    container = m["container-title"] and m["container-title"][1] and unescape(m["container-title"][1]:gsub("%s+", " ")) or nil,
    member = m.publisher,
    -- the member that registered a DOI is the publisher of a book, but often an
    -- archive for an article (JSTOR for the Annals): only a book's is offered
    publisher = BOOKISH[m.type or ""] and m.publisher or nil,
    doi = m.DOI, isbn = m.ISBN and m.ISBN[1],
  }
  if issued and issued[2] and issued[3] then rec.date = ("%04d-%02d-%02d"):format(issued[1], issued[2], issued[3]) end
  return rec
end

local function mailto(sep)
  local mail = lulibre.o.contact_email or ""
  return mail ~= "" and sep .. "mailto=" .. encode(mail) or ""
end

--- CrossRef's record for a DOI.
function M.crossref(doi)
  local body, err = M.fetch("crossref", doi:lower(), "https://api.crossref.org/works/" .. encode(doi) .. mailto("?"))
  if not body then return nil, err end
  local ok, data = pcall(json.decode, body)
  if not ok or type(data) ~= "table" or not data.message then return nil, "unreadable reply from CrossRef" end
  local rec = crossref_record(data.message)
  rec.source = "CrossRef " .. doi
  return rec
end

-- how many DOIs go in one request to CrossRef
M.CROSSREF_BATCH = 20

--- Ask CrossRef about many DOIs in as few requests as it takes (its `filter`
-- takes several, and `select` leaves out the reference lists and the rest
-- that is not wanted), keeping each answer; M.crossref then answers from
-- what was kept. Returns how many were newly fetched.
function M.crossref_prefetch(dois)
  local keys = {}
  for _, doi in ipairs(dois) do
    -- a comma would end the DOI in a list of them: such a one is asked for alone
    if not doi:find("[,%s]") then keys[#keys + 1] = doi:lower() end
  end
  return in_batches("crossref", keys, M.CROSSREF_BATCH, function(chunk)
    local list = {}
    for i, doi in ipairs(chunk) do list[i] = "doi:" .. encode(doi) end
    return ("https://api.crossref.org/works?filter=%s&rows=%d&select=DOI,type,title,author,issued,publisher,ISBN,container-title%s"):format(
      table.concat(list, ","), #chunk, mailto("&"))
  end, function(_, body)
    local ok, data = pcall(json.decode, body)
    local items = ok and type(data) == "table" and type(data.message) == "table" and data.message.items
    if type(items) ~= "table" then return nil end
    local found = {}
    for _, item in ipairs(items) do
      if type(item.DOI) == "string" then found[item.DOI:lower()] = json.encode { status = "ok", message = item } end
    end
    return found
  end)
end

--- Are two titles the same work? Deliberately strict: a wrong match would
-- put someone else's authors on a book.
function M.same_title(a, b)
  local stop = { the = 1, a = 1, an = 1, of = 1, ["in"] = 1, on = 1, ["for"] = 1, ["and"] = 1, to = 1, with = 1,
    by = 1, from = 1, at = 1, is = 1, are = 1 }
  local function words(s)
    local set, n = {}, 0
    for w in lulibre.fold(s):gmatch("[%w]+") do
      if not stop[w] and not set[w] then
        set[w] = true
        n = n + 1
      end
    end
    return set, n
  end
  local wa, na = words(a)
  local wb, nb = words(b)
  if na == 0 or nb == 0 then return false end
  local both = 0
  for w in pairs(wa) do
    if wb[w] then both = both + 1 end
  end
  if na <= 3 or nb <= 3 then return both / math.max(na, nb) > 0.6 end
  return both >= 3 and both / (na + nb - both) > 0.4
end

--- Search CrossRef by title; the record only if its title really matches.
function M.crossref_search(title)
  local body, err = M.fetch("crossref-title", lulibre.fold(title),
    "https://api.crossref.org/works?rows=3&query.bibliographic=" .. encode(title) .. mailto("&"))
  if not body then return nil, err end
  local ok, data = pcall(json.decode, body)
  if not ok or type(data) ~= "table" or not data.message then return nil, "unreadable reply from CrossRef" end
  for _, item in ipairs(data.message.items or {}) do
    local rec = crossref_record(item)
    if rec.title and M.same_title(title, rec.title) then
      rec.source = "CrossRef title search"
      return rec
    end
  end
  return nil, "no confident match"
end

-- ---- zbMATH Open ----

-- "Wiles, Andrew" the right way round
local function forename_first(name)
  local family, given = name:match("^([^,]+),%s*(.+)$")
  return family and (trim(given) .. " " .. trim(family)) or name
end

--- zbMATH Open's record for a work, by { doi = } or { arxiv = }: what gives
-- a mathematics paper or book its subject, since each is classified by hand
-- (the MSC codes), besides its title, authors, year and Zbl number.
function M.zbmath(by)
  local key, param
  if by.doi then key, param = "doi:" .. by.doi:lower(), "DOI=" .. encode(by.doi)
  elseif by.arxiv then key, param = "arxiv:" .. by.arxiv, "arXiv%20ID=" .. encode(by.arxiv)
  else return nil, "zbmath wants a doi or an arxiv id" end
  local body, err = M.fetch("zbmath", key,
    "https://api.zbmath.org/v1/document/_structured_search?page=0&results_per_page=1&" .. param)
  if not body then return nil, err end
  local ok, data = pcall(json.decode, body)
  local doc = ok and type(data) == "table" and type(data.result) == "table" and data.result[1]
  if not doc then
    M.keep("zbmath", key, 404)
    return nil, "zbMATH has no record of " .. key
  end
  local rec = { authors = {}, subjects = {}, ids = {}, year = tonumber(doc.year), source = "zbMATH " .. tostring(doc.identifier or "") }
  if type(doc.title) == "table" and type(doc.title.title) == "string" then
    rec.title = doc.title.title:gsub("%s+", " "):gsub("%s*%.$", "")
  end
  for _, a in ipairs(type(doc.contributors) == "table" and doc.contributors.authors or {}) do
    if type(a.name) == "string" then rec.authors[#rec.authors + 1] = forename_first(a.name) end
  end
  if type(doc.identifier) == "string" then rec.ids.zbl = doc.identifier end
  if type(doc.document_type) == "table" then rec.type = doc.document_type.description end
  -- the first code is the work's main class; its first two figures are the area
  local seen = {}
  for i, m in ipairs(type(doc.msc) == "table" and doc.msc or {}) do
    local area = type(m.code) == "string" and m.code:match("^(%d%d)")
    local tag = area and taxonomy.msc[area]
    if tag and not seen[tag] and tag ~= "math/general" then
      seen[tag] = true
      rec.subjects[#rec.subjects + 1] = { tag = tag, confidence = i == 1 and 0.9 or 0.75, why = "MSC " .. m.code }
    end
  end
  return rec
end

-- ---- Open Library ----

local MONTHS = { january = 1, february = 2, march = 3, april = 4, may = 5, june = 6, july = 7, august = 8, september = 9,
  october = 10, november = 11, december = 12 }

-- how many ISBNs go in one request to Open Library
M.OPENLIBRARY_BATCH = 20

local function plain_isbn(isbn)
  return (isbn:gsub("[^%dXx]", ""):upper())
end

--- Ask Open Library about many ISBNs in as few requests as it takes, keeping
-- each answer; M.openlibrary then answers from what was kept. Returns how
-- many were newly fetched.
function M.openlibrary_prefetch(isbns)
  local keys = {}
  for i, isbn in ipairs(isbns) do keys[i] = plain_isbn(isbn) end
  return in_batches("openlibrary", keys, M.OPENLIBRARY_BATCH, function(chunk)
    local list = {}
    for i, isbn in ipairs(chunk) do list[i] = "ISBN:" .. isbn end
    return "https://openlibrary.org/api/books?format=json&jscmd=data&bibkeys=" .. table.concat(list, ",")
  end, function(chunk, body)
    local ok, data = pcall(json.decode, body)
    if not ok or type(data) ~= "table" then return nil end
    local found = {}
    for _, isbn in ipairs(chunk) do
      local b = data["ISBN:" .. isbn]
      if type(b) == "table" then found[isbn] = json.encode { ["ISBN:" .. isbn] = b } end
    end
    return found
  end)
end

--- Open Library's record for an ISBN: a book's title, authors, publisher and
-- year, the series when the title carries it in brackets, and its subject
-- from the class number libraries shelve it under.
function M.openlibrary(isbn)
  isbn = plain_isbn(isbn)
  local body, err = M.fetch("openlibrary", isbn,
    "https://openlibrary.org/api/books?format=json&jscmd=data&bibkeys=ISBN:" .. isbn)
  if not body then return nil, err end
  local ok, data = pcall(json.decode, body)
  local b = ok and type(data) == "table" and data["ISBN:" .. isbn]
  if not b then
    M.keep("openlibrary", isbn, 404)
    return nil, "Open Library has no record of ISBN " .. isbn
  end
  local rec = { authors = {}, subjects = {}, ids = { isbn = isbn }, type = "book", source = "Open Library " .. isbn }
  local title = type(b.title) == "string" and trim(b.title) or nil
  if title then
    -- "Algebraic Geometry (Graduate Texts in Mathematics)": the bracket is the series
    local head, series = title:match("^(.-)%s*%(([^()]+)%)$")
    if head and #head >= 3 and series:find("%a") then
      title = head
      local name, number = series:match("^(.-)%s*[;,]?%s*[vVnNoO.#]*%s*(%d+)$")
      rec.series, rec.series_index = name and #name > 3 and name or series, name and #name > 3 and number or nil
    end
    if type(b.subtitle) == "string" and b.subtitle ~= "" then title = title .. ": " .. trim(b.subtitle) end
    rec.title = title
  end
  for _, a in ipairs(type(b.authors) == "table" and b.authors or {}) do
    if type(a.name) == "string" then rec.authors[#rec.authors + 1] = a.name end
  end
  local pub = type(b.publishers) == "table" and b.publishers[1]
  if type(pub) == "table" and type(pub.name) == "string" then rec.publisher = pub.name end
  if type(b.publish_date) == "string" then
    rec.year = tonumber(b.publish_date:match("%f[%d](%d%d%d%d)%f[%D]"))
    local month, day = b.publish_date:match("^(%a+)%s+(%d+),")
    if rec.year and month and MONTHS[month:lower()] then
      rec.date = ("%04d-%02d-%02d"):format(rec.year, MONTHS[month:lower()], tonumber(day))
    end
  end
  local class = type(b.classifications) == "table" and b.classifications or {}
  for _, lcc in ipairs(type(class.lc_classifications) == "table" and class.lc_classifications or {}) do
    local tag = taxonomy.from_lcc(lcc)
    if tag then
      rec.subjects[1] = { tag = tag, confidence = 0.85, why = "class " .. lcc:match("^%S+") }
      break
    end
  end
  if not rec.subjects[1] then
    for _, dewey in ipairs(type(class.dewey_decimal_class) == "table" and class.dewey_decimal_class or {}) do
      local tag = taxonomy.from_dewey(dewey)
      if tag then
        rec.subjects[1] = { tag = tag, confidence = 0.8, why = "Dewey " .. dewey }
        break
      end
    end
  end
  return rec
end

-- ---- OpenAlex ----

--- OpenAlex's record for a DOI: title, authors and date, for works CrossRef
-- does not have.
function M.openalex(doi)
  local body, err = M.fetch("openalex", doi:lower(), "https://api.openalex.org/works/doi:" .. encode(doi))
  if not body then return nil, err end
  local ok, w = pcall(json.decode, body)
  if not ok or type(w) ~= "table" or not w.title then return nil, "unreadable reply from OpenAlex" end
  local rec = { title = type(w.title) == "string" and unescape(w.title:gsub("%s+", " ")) or nil, authors = {}, subjects = {},
    ids = { doi = doi }, year = tonumber(w.publication_year), type = w.type, source = "OpenAlex " .. doi,
    date = type(w.publication_date) == "string" and w.publication_date or nil }
  for _, a in ipairs(type(w.authorships) == "table" and w.authorships or {}) do
    if type(a.author) == "table" and type(a.author.display_name) == "string" then
      rec.authors[#rec.authors + 1] = a.author.display_name
    end
  end
  -- where it appeared: the journal, and the house or society behind it
  local place = type(w.primary_location) == "table" and type(w.primary_location.source) == "table" and w.primary_location.source or nil
  if place and type(place.display_name) == "string" and (place.type == nil or place.type == "journal" or place.type == "conference") then
    rec.container = place.display_name
    rec.member = type(place.host_organization_name) == "string" and place.host_organization_name or nil
  end
  -- (no subject is taken from it: OpenAlex sorts works into topics by
  -- machine, and files Wiles's proof of Fermat under mathematical physics)
  return rec
end

return M
