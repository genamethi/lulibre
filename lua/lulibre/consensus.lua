--- Measures how far a book's sources agree, and how much to trust each kind
-- of source.
--
-- Several sources describe a book: its title page, a cataloguing block, the
-- metadata inside the file, an arXiv record, its bibliography. Each source
-- gives values for some fields. Two sources that give the same field should
-- agree. A value all the sources agree on has been checked more than once,
-- and a field where the sources disagree needs a look.
--
-- (In mathematical terms this is a small sheaf. The sources are the open
-- sets, each source's values are a section over its set, and a value that
-- all of the sections restrict to is a global section. Robinson calls the
-- distance from the sources' values to the nearest global section the
-- consistency radius. Here that distance is `disagreement`.)
--
-- @judging lulibre.consensus
-- @usage
-- local consensus = require "lulibre.consensus"
-- consensus.distance("title", a, b)        --> 0 (the same) .. 1 (nothing in common)
-- consensus.fuse(candidates, "title")      --> { value=, confidence=, disagreement=, agree=, sources= }
-- consensus.book(id)                       --> { fields = { title = {...}, ... }, disagreement = }
-- consensus.learn()                        -- measure each kind of source against the library as it stands
-- consensus.weight("title page", "title")  --> how often that source has been right about that field here
-- consensus.set("title page", "title", 0.5)   -- say so yourself; nil gives it back to the measurement
local json = require "lulibre.json"

local M = {}

--- The fields consensus compares across sources.
M.fields = { "title", "authors", "pubdate", "publisher", "series", "tags" }
--- The distance at or below which two values count as the same.
M.NEAR = 0.25

local function words(s)
  local set, n = {}, 0
  for w in lulibre.fold(s or ""):gsub("\226\128[\144-\159]", " "):gmatch("[%w\128-\255]+") do
    if not set[w] then set[w], n = true, n + 1 end
  end
  return set, n
end

local function jaccard(a, na, b, nb)
  if na == 0 or nb == 0 then return 1 end
  local both = 0
  for w in pairs(a) do
    if b[w] then both = both + 1 end
  end
  return 1 - both / (na + nb - both)
end

local function surnames(s)
  local set, n = {}, 0
  for name in ((s or ""):gsub(" and ", " & ") .. "&"):gmatch("%s*(.-)%s*[&;]") do
    local last = lulibre.fold(name):match("([%w\128-\255%-]+)%s*$")
    if last and last ~= "unknown" and not set[last] then set[last], n = true, n + 1 end
  end
  return set, n
end

--- Returns how far apart two values of a field are: 0 if the values are
-- the same, 1 if they have nothing in common.
-- @tparam string field
-- @tparam string a
-- @tparam string b
-- @treturn number 0 to 1
function M.distance(field, a, b)
  a, b = tostring(a or ""), tostring(b or "")
  if a == b then return 0 end
  if a == "" or b == "" then return 1 end
  if field == "title" then
    local fa, fb = lulibre.fold(a), lulibre.fold(b)
    if fa == fb then return 0 end
    -- a title cut short, or with its subtitle, is nearly the same title
    if (#fa >= 12 and fb:sub(1, #fa) == fa) or (#fb >= 12 and fa:sub(1, #fb) == fb) then return 0.1 end
    local wa, na = words(a)
    local wb, nb = words(b)
    return jaccard(wa, na, wb, nb)
  elseif field == "authors" then
    local sa, na = surnames(a)
    local sb, nb = surnames(b)
    return jaccard(sa, na, sb, nb)
  elseif field == "pubdate" then
    local ya, yb = tonumber(a:match("^%d%d%d%d")), tonumber(b:match("^%d%d%d%d"))
    if not ya or not yb then return 1 end
    if ya == yb then return (#a > 4 and #b > 4 and not a:find("%-01%-01$") and not b:find("%-01%-01$")) and 0.05 or 0 end
    return math.min(1, math.abs(ya - yb) / 3)
  elseif field == "tags" then
    if a:sub(1, #b + 1) == b .. "/" or b:sub(1, #a + 1) == a .. "/" then return 0.25 end
    return a:match("^[^/]+") == b:match("^[^/]+") and 0.5 or 1
  end
  local fa, fb = lulibre.fold(a), lulibre.fold(b)
  if fa == fb then return 0 end
  if fa:find(fb, 1, true) or fb:find(fa, 1, true) then return 0.2 end
  return 1
end

--- Returns the kind of source a proposal's source names. For example,
-- "arXiv 1012.6008" is "arXiv record", "vocabulary (22)" is "vocabulary",
-- and "by-line, named twice" is "by-line".
-- @tparam string source
-- @treturn string
function M.kind(source)
  local s = tostring(source or "?")
  s = s:gsub("%s*%b()", ""):gsub(",.*$", ""):gsub("%s+$", "")
  if s:find("^arXiv %S+$") and not s:find("^arXiv class") and not s:find("^arXiv id") and not s:find("^arXiv stamp") then return "arXiv record" end
  for _, service in ipairs { "CrossRef", "zbMATH", "Open Library", "OpenAlex" } do
    if s:find("^" .. service) then return service end
  end
  if s:find("^learned") then return "learned phrases" end
  if s:find("^MSC") then return "MSC" end
  if s:find("^class ") or s:find("^Dewey") then return "shelf class" end
  return s
end

local function stored(key)
  local row = lulibre.store("SELECT value FROM kv WHERE key = ?", key)[1]
  local ok, t = pcall(json.decode, row and row.value or "{}")
  return ok and type(t) == "table" and t or {}
end

local measured, manual

local function load()
  if not measured then measured, manual = stored("consensus:weights"), stored("consensus:manual") end
end

--- Clears the weights held in memory, so they are read from the index again.
function M.reload()
  measured, manual = nil, nil
end

--- Returns true if the sources have been measured on this library.
-- @treturn boolean
function M.ready()
  load()
  return next(measured) ~= nil
end

--- Returns how far a kind of source is trusted about a field: the weight
-- you set, or else the share of times the source agreed with the library's
-- own records. A measured share counts only if the source was measured
-- often enough. Returns nil if nothing is known about the source.
-- @tparam string kind
-- @tparam string field
-- @treturn number|nil 0 to 1
function M.weight(kind, field)
  load()
  local key = kind .. "\t" .. field
  if manual[key] then return manual[key], "set by hand" end
  local m = measured[key]
  if m and m.n >= 5 then return m.w, ("%d of %d"):format(m.agree, m.n) end
  return nil
end

--- Sets a weight by hand, or returns the weight to the measurement.
-- @tparam string kind
-- @tparam string field
-- @tparam number|nil w 0 to 1, or nil to use the measurement again
function M.set(kind, field, w)
  load()
  manual[kind .. "\t" .. field] = w and math.max(0, math.min(1, w)) or nil
  lulibre.store("INSERT OR REPLACE INTO kv(key, value) VALUES('consensus:manual', ?)", next(manual) and json.encode(manual) or "{}")
end

--- Returns every weight, sorted by field and then by kind.
-- @treturn {table,...} `{ {kind=, field=, n=, agree=, measured=, manual=, weight=}, ... }`
function M.table()
  load()
  local seen, out = {}, {}
  local function row(key)
    if seen[key] then return end
    seen[key] = true
    local kind, field = key:match("^(.-)\t(.*)$")
    local m = measured[key]
    out[#out + 1] = { kind = kind, field = field, n = m and m.n or 0, agree = m and m.agree or 0, measured = m and m.n >= 5 and m.w or nil,
      manual = manual[key], weight = manual[key] or (m and m.n >= 5 and m.w) or nil }
  end
  for key in pairs(measured) do row(key) end
  for key in pairs(manual) do row(key) end
  table.sort(out, function(a, b)
    if a.field ~= b.field then return a.field < b.field end
    return a.kind < b.kind
  end)
  return out
end

-- how far a source's own confidence is taken once it has been measured: the
-- measurement, pulled towards what the source claims while it rests on few books
local function believed(c, field)
  local own = c.confidence or 0.5
  local w = M.weight(M.kind(c.source), field)
  if not w then return own end
  if manual[M.kind(c.source) .. "\t" .. field] then return w end
  local m = measured[M.kind(c.source) .. "\t" .. field]
  return (m.n * w + 10 * own) / (m.n + 10)
end

--- Combines what a book's sources say about one field.
-- @tparam {table,...} candidates as `lulibre.extract` gives them
-- @tparam string field
-- @treturn table|nil nil if no source gives the field. Otherwise a table:
--
-- - `value`: the value with most of the weight behind it
-- - `confidence`: how sure that value is, counting every source that agrees
-- - `disagreement`: 0 (all sources agree) to 1
-- - `sources`: how many sources give the field
-- - `agree`: how many of those sources give the value
-- - `by`: `{ {source=, value=, confidence=, agrees=}, ... }`
function M.fuse(candidates, field)
  local said = {}
  for _, c in ipairs(candidates) do
    if c.field == field and c.value and c.value ~= "" then said[#said + 1] = { c = c, w = believed(c, field) } end
  end
  if #said == 0 then return nil end
  local best, best_score, total = nil, -1, 0
  for _, s in ipairs(said) do total = total + s.w end
  for _, u in ipairs(said) do
    local score = 0
    for _, s in ipairs(said) do score = score + s.w * (1 - M.distance(field, u.c.value, s.c.value)) end
    if score > best_score then best, best_score = u, score end
  end
  local out = { value = best.c.value, sources = #said, agree = 0, by = {}, disagreement = total > 0 and 1 - best_score / total or 0 }
  -- every source that agrees is one more check: the surest of them, and each other counted for half
  local top, rest = 0, 1
  for _, s in ipairs(said) do
    local agrees = M.distance(field, best.c.value, s.c.value) <= M.NEAR
    out.by[#out.by + 1] = { source = s.c.source, value = s.c.value, confidence = s.w, agrees = agrees }
    if agrees then
      out.agree = out.agree + 1
      if s.w > top then
        if top > 0 then rest = rest * (1 - 0.5 * top) end
        top = s.w
      else
        rest = rest * (1 - 0.5 * s.w)
      end
    end
  end
  out.confidence = math.min(0.99, (1 - (1 - top) * rest) * (1 - out.disagreement / 2))
  return out
end

--- Returns what a book's sources say, field by field, and the largest
-- disagreement over the fields that more than one source gives.
-- @tparam integer id
-- @tparam[opt] {table,...} candidates read from the file if not given
-- @treturn table `{ fields = { title = <fuse>, ... }, disagreement= }`
function M.book(id, candidates)
  candidates = candidates or require("lulibre.extract").candidates(id)
  local out = { fields = {}, disagreement = 0 }
  for _, field in ipairs(M.fields) do
    local f = M.fuse(candidates, field)
    if f then
      out.fields[field] = f
      if f.sources > 1 and f.disagreement > out.disagreement then out.disagreement, out.worst = f.disagreement, field end
    end
  end
  return out
end

--- Measures every kind of source against the library as it is now. For
-- each book and field with a value worth trusting (not empty, not junk),
-- the measurement checks whether each source agrees with that value. Takes
-- some seconds, and stores the measurements in the index.
-- @tparam[opt] {integer,...} ids the books to measure on; every book if not given
-- @treturn integer how many books were used
function M.learn(ids)
  local extract, edit, propose = require "lulibre.extract", require "lulibre.edit", require "lulibre.propose"
  ids = ids or lulibre.ids("")
  local counts, used = {}, 0
  for n, id in ipairs(ids) do
    local book = lulibre.book(id)
    local any = false
    for _, c in ipairs(book and extract.candidates(id) or {}) do
      local cur = c.field ~= "identifiers" and edit.current(book, c.field) or ""
      if cur ~= "" and not propose.is_gap(c.field, cur, id) then
        local d = 1
        if c.field == "tags" then
          for tag in cur:gmatch("[^,]+") do d = math.min(d, M.distance("tags", (tag:gsub("^%s+", ""):gsub("%s+$", "")), c.value)) end
        else
          d = M.distance(c.field, cur, c.value)
        end
        local key = M.kind(c.source) .. "\t" .. c.field
        counts[key] = counts[key] or { n = 0, agree = 0 }
        counts[key].n = counts[key].n + 1
        if d <= M.NEAR then counts[key].agree = counts[key].agree + 1 end
        any = true
      end
    end
    if any then used = used + 1 end
    if n % 100 == 0 then lulibre.progress(("measuring the sources: %d/%d"):format(n, #ids)) end
  end
  lulibre.progress(nil)
  for _, m in pairs(counts) do m.w = (m.agree + 1) / (m.n + 2) end
  lulibre.store("INSERT OR REPLACE INTO kv(key, value) VALUES('consensus:weights', ?)", json.encode(counts))
  M.reload()
  return used
end

return M
