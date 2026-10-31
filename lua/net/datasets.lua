--- Datasets on this machine (lulib._datasets) as services that answer without
-- asking anybody: arXiv's snapshot, Open Library's dumps, zbMATH's table of links. A
-- service with `covers` is asked first (net.enrich_many), and the service it covers
-- isn't asked about what it has. What's found is kept like any answer. A file is
-- read by grep, through gzip when it's packed, for all the works wanted at once: the
-- dumps are tens of gigabytes unpacked and a few hundred lines are wanted.
--
-- @submodule net
local json = require "dkjson"
local service = require "net.service"
local stringx = require "pl.stringx"
local mesr = require "mesr"

local M = {}

local function datasets() return require "lulib._datasets" end

--- The lines of a file that hold any of some strings, and whether the file was
-- read to its end (a file still being fetched is not); nil and why.
function M.lines_with(path, strings)
  local dir = datasets().dir()
  local patterns = ("%s/.lulibre-grep-%d-%d"):format(dir, os.time(), #strings)
  local f, err = io.open(patterns, "w")
  if not f then return nil, tostring(err) end
  f:write(table.concat(strings, "\n"), "\n")
  f:close()
  local errors = patterns .. ".err"
  local reader = path:match("%.gz$") and 'gzip -dc "$1" 2>"$3"' or 'cat "$1" 2>"$3"'
  local r, why = utils.exec({ "sh", "-c", reader .. ' | LC_ALL=C grep -F -f "$2"', "sh", path, patterns, errors }, { timeout = 3600 * 1000 })
  local ef = io.open(errors, "r")
  local complaint = ef and ef:read("a") or ""
  if ef then ef:close() end
  os.remove(patterns)
  os.remove(errors)
  if not r then return nil, tostring(why) end
  if r.code > 1 then return nil, stringx.strip(r.stderr or "") ~= "" and stringx.strip(r.stderr) or ("grep exited " .. r.code) end
  local lines = {}
  for line in (r.stdout or ""):gmatch("[^\n]+") do lines[#lines + 1] = line end
  return lines, stringx.strip(complaint) == ""
end

local MONTH = { Jan = 1, Feb = 2, Mar = 3, Apr = 4, May = 5, Jun = 6, Jul = 7, Aug = 8, Sep = 9, Oct = 10, Nov = 11, Dec = 12 }

--- A line of arXiv's snapshot as fields, or nil.
--   {"id":"0704.0001","authors":"C. Bal\\'azs, E. L. Berger","title":"...","categories":"hep-ph math.AG",
--    "versions":[{"version":"v1","created":"Mon, 2 Apr 2007 19:18:42 GMT"}],"authors_parsed":[["Balázs","C.",""]]}
function M.arxiv_fields(line)
  local j = json.decode(line)
  if type(j) ~= "table" or type(j.title) ~= "string" then return nil end
  local detex = require "lulib._detex"
  local names = {}
  for _, name in ipairs(type(j.author_names) == "table" and j.author_names or {}) do
    if type(name) == "string" and name ~= "" then names[#names + 1] = detex.plain(stringx.strip(name)) end
  end
  for _, a in ipairs(#names == 0 and type(j.authors_parsed) == "table" and j.authors_parsed or {}) do
    if type(a) == "table" and type(a[1]) == "string" then
      -- { family, given, suffix }
      local name = stringx.strip((((type(a[2]) == "string" and a[2] or "") .. " " .. a[1] .. " " .. (type(a[3]) == "string" and a[3] or "")):gsub("%s+", " ")))
      if name ~= "" then names[#names + 1] = detex.plain(name) end
    end
  end
  if #names == 0 and type(j.authors) == "string" then
    for name in (j.authors:gsub("%s+and%s+", ", ") .. ","):gmatch("%s*([^,]+),") do names[#names + 1] = detex.plain(stringx.strip(name)) end
  end
  -- the first version is the submission
  local first = type(j.versions) == "table" and type(j.versions[1]) == "table" and j.versions[1].created
  local day, month, year = (type(first) == "string" and first or ""):match("(%d%d?)%s+(%a%a%a)%s+(%d%d%d%d)")
  local date = MONTH[month or ""] and ("%s-%02d-%02d"):format(year, MONTH[month], tonumber(day)) or nil
  local class = type(j.categories) == "string" and j.categories:match("^%S+") or nil
  return {
    title = (detex.plain(stringx.strip((j.title:gsub("%s+", " "))))),
    authors = #names > 0 and table.concat(names, " & ") or nil,
    pubdate = date,
    tags = class and require("lulib._taxonomy").from_arxiv(class) or nil,
  }
end

--- arXiv's records on this machine: its own snapshot, or else a hypergraph of it,
-- `arxiv.json`, as a file or in `arxiv.zip`: title, authors in no order and classes,
-- but no DOI and no day of submission.
function M.arxiv_path()
  return datasets().path("arxiv-metadata-oai-snapshot.json") or datasets().path("arxiv.json") or datasets().path("arxiv.zip")
end

-- A hypergraph of arXiv: one JSON document over many lines, each paper an "edge" and
-- each author of each paper an "incidence". Read in pieces of whole records, looking
-- only for the numbers wanted; those found come out as a line of the snapshot would.
--   "edges": [ { "attrs": { "title": ..., "categories": ["math.NT"], "date": "2020-08-28" }, "edge": "2002.08172" }, ...
--   "incidences": [ { "edge": "2002.08172", "node": "A. N. Other" }, ...
local function scan_hypergraph(f, want)
  local papers, authors = {}, {}
  local carry, in_authors = "", false
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
    end
    local part = buf:sub(1, cut)
    carry = buf:sub(cut + 1)
    local turns = part:find('\n  "incidences": [', 1, true)
    if not in_authors then
      local prev = 1
      while true do
        local a, e, raw = part:find('\n      "edge": "([^"\n]+)"\n', prev)
        if not a then break end
        if want[raw] then
          local slice = part:sub(prev, e - 1)
          local open = slice:find("    {\n", 1, true)
          local obj = open and json.decode(slice:sub(open) .. "}")
          if type(obj) == "table" and type(obj.attrs) == "table" and type(obj.attrs.title) == "string" then papers[raw] = obj.attrs end
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
            authors[raw] = authors[raw] or {}
            table.insert(authors[raw], json.decode('"' .. node .. '"') or node)
          end
        end
      end
    end
    in_authors = in_authors or turns ~= nil
    taskman.yield()
    if not chunk then break end
  end
  local out = {}
  for id, attrs in pairs(papers) do
    local classes = type(attrs.categories) == "table" and table.concat(attrs.categories, " ") or attrs.categories
    out[id] = json.encode { id = id, title = attrs.title, categories = classes, author_names = authors[id] or {} }
  end
  return out
end

service.define("arxiv-snapshot", {
  ident = "arxiv", covers = "arxiv", pace = 0, hold = 0, batch = 100000,
  available = function() return M.arxiv_path() ~= nil end,
  request = function(keys)
    local path = M.arxiv_path()
    local strings, want = {}, {}
    for i, key in ipairs(keys) do
      strings[i] = '"id":"' .. key .. '"'
      want[key] = true
    end
    if not path:find("arxiv%-metadata") then
      local f = path:match("%.zip$") and io.popen("unzip -p '" .. path:gsub("'", "'\\''") .. "' 2>/dev/null", "r") or io.open(path, "r")
      if not f then return nil, "cannot read " .. path end
      local ok, out = pcall(scan_hypergraph, f, want)
      f:close()
      if not ok then return nil, tostring(out) end
      return out
    end
    local lines, whole = M.lines_with(path, strings)
    if not lines then return nil, whole end
    local out = {}
    for _, line in ipairs(lines) do
      local id = line:match('"id"%s*:%s*"([^"]+)"')
      if id and want[id] then out[id] = line end
    end
    return out
  end,
  record = function(answer) return M.arxiv_fields(answer) end,
})

-- an ISBN's digits
local function plain_isbn(s)
  return (tostring(s or ""):gsub("[^%dXx]", ""):upper())
end

-- the ISBN-10 of a 978 ISBN-13
local function isbn10(isbn)
  if #isbn ~= 13 or isbn:sub(1, 3) ~= "978" then return nil end
  local body, sum = isbn:sub(4, 12), 0
  for i = 1, 9 do sum = sum + (body:byte(i) - 48) * (11 - i) end
  local check = (11 - sum % 11) % 11
  return body .. (check == 10 and "X" or tostring(check))
end

service.define("openlibrary-dump", {
  ident = "isbn", covers = "openlibrary", pace = 0, hold = 0, batch = 100000,
  available = function() return datasets().path("ol_dump_editions_latest.txt.gz") ~= nil end,
  request = function(keys)
    local editions, people = datasets().path("ol_dump_editions_latest.txt.gz"), datasets().path("ol_dump_authors_latest.txt.gz")
    -- every way an ISBN is written, and the key it was asked for as
    local asked, strings = {}, {}
    for _, key in ipairs(keys) do
      for _, form in ipairs { key, isbn10(key) or false } do
        if form and not asked[form] then
          asked[form] = key
          strings[#strings + 1] = '"' .. form .. '"'
        end
      end
    end
    local lines, whole = M.lines_with(editions, strings)
    if not lines then return nil, whole end
    -- the edition that says most, for each ISBN
    local best, wanted_authors = {}, {}
    for _, line in ipairs(lines) do
      local e = json.decode(line:match("\t({.*})%s*$") or "")
      if type(e) == "table" and type(e.title) == "string" then
        local score = (type(e.authors) == "table" and #e.authors > 0 and 4 or type(e.by_statement) == "string" and 3 or 0) + (type(e.lc_classifications) == "table" and 2 or 0)
          + (type(e.publishers) == "table" and 1 or 0) + (type(e.publish_date) == "string" and 1 or 0) + (type(e.series) == "table" and 1 or 0)
        for _, field in ipairs { "isbn_13", "isbn_10" } do
          for _, written in ipairs(type(e[field]) == "table" and e[field] or {}) do
            local key = asked[plain_isbn(written)]
            if key and (not best[key] or score > best[key].score) then best[key] = { score = score, e = e } end
          end
        end
      end
    end
    for _, b in pairs(best) do
      for _, a in ipairs(type(b.e.authors) == "table" and b.e.authors or {}) do
        if type(a) == "table" and type(a.key) == "string" then wanted_authors[a.key] = true end
      end
    end
    -- the authors' names: an edition holds only keys to them
    local names = {}
    if people and next(wanted_authors) then
      local wanted = {}
      for key in pairs(wanted_authors) do wanted[#wanted + 1] = "\t" .. key .. "\t" end
      for _, line in ipairs(M.lines_with(people, wanted) or {}) do
        local key = line:match("^[^\t]*\t([^\t]+)\t")
        local a = json.decode(line:match("\t({.*})%s*$") or "")
        if key and type(a) == "table" and type(a.name) == "string" then names[key] = a.name end
      end
    end
    -- kept in the shape Open Library's own answer has, so that one reader reads both
    local out = {}
    for key, b in pairs(best) do
      local e, authors, publishers = b.e, {}, {}
      for _, a in ipairs(type(e.authors) == "table" and e.authors or {}) do
        local name = type(a) == "table" and names[a.key]
        if name then authors[#authors + 1] = { name = name } end
      end
      for _, p in ipairs(type(e.publishers) == "table" and e.publishers or {}) do
        if type(p) == "string" then publishers[#publishers + 1] = { name = p } end
      end
      local record = {
        title = (type(e.title_prefix) == "string" and e.title_prefix or "") .. e.title, subtitle = e.subtitle, publish_date = e.publish_date,
        by_statement = e.by_statement,
        number_of_pages = e.number_of_pages, series = e.series,
        classifications = { lc_classifications = e.lc_classifications, dewey_decimal_class = e.dewey_decimal_class },
      }
      if #authors > 0 then record.authors = authors end
      if #publishers > 0 then record.publishers = publishers end
      out[key] = json.encode { ["ISBN:" .. key] = record }
    end
    return out
  end,
  record = function(answer)
    local _, b = next(json.decode(answer) or {})
    return service.openlibrary_fields(b or {})
  end,
})

-- zbMATH's table of its links to full texts: "zbmath_id,link", the link mostly
-- "https://arxiv.org/pdf/1111.2222.pdf". All it gives is the zbMATH number.
service.define("zbmath-links", {
  ident = "arxiv", pace = 0, hold = 0, batch = 100000, identifies = true,
  available = function() return datasets().path("zbmath-oa_links.csv") ~= nil end,
  request = function(keys)
    local strings, want = {}, {}
    for _, key in ipairs(keys) do
      want[key] = true
      strings[#strings + 1] = "arxiv.org/pdf/" .. key
      strings[#strings + 1] = "arxiv.org/abs/" .. key
    end
    local lines, whole = M.lines_with(datasets().path("zbmath-oa_links.csv"), strings)
    if not lines then return nil, whole end
    local out = {}
    for _, line in ipairs(lines) do
      local number, id = line:match("^(%d+),https?://arxiv%.org/%a+/(.-)%s*$")
      id = id and mesr.canonical("arxiv", (id:gsub("%.pdf$", "")))
      if id and want[id] then out[id] = number end
    end
    return out
  end,
  record = function(answer) return { ["identifier:zbl"] = answer } end,
})

--- A title in the form papers are looked up by: folded, with every run of
-- characters other than letters and digits made one space.
function M.title_key(title)
  return (require("expr").fold(title or ""):gsub("%$", ""):gsub("[^%w\128-\255]+", " "):gsub("^ ", ""):gsub(" $", ""))
end

--- Looks papers up by title in arXiv's snapshot, without asking anyone. Every record
-- whose title is wanted is kept as its answer for its number.
-- @tparam string path
-- @tparam table wanted `{ [title_key(title)] = true }`
-- @tparam[opt] function progress
-- @treturn table `{ [key] = { id, ... } }`, and how many papers were read; or nil and why
function M.by_title(path, wanted, progress)
  local f, err = io.open(path, "r")
  if not f then return nil, ("cannot read %s: %s"):format(path, tostring(err)) end
  local out, n = {}, 0
  for line in f:lines() do
    n = n + 1
    local raw = line:match('"title"%s*:%s*"(.-[^\\])"%s*,')
    if raw then
      local title = json.decode('"' .. raw .. '"')
      local key = M.title_key(title or raw)
      if wanted[key] then
        local id = mesr.canonical("arxiv", line:match('"id"%s*:%s*"([^"]+)"') or "")
        if id and M.arxiv_fields(line) then
          service.keep("arxiv-snapshot", id, line)
          out[key] = out[key] or {}
          table.insert(out[key], id)
        end
      end
    end
    if n % 200000 == 0 then
      if progress then progress(("%.1f million papers"):format(n / 1e6)) end
      taskman.yield()
    end
  end
  f:close()
  return out, n
end

-- arXiv's snapshot by title, for a book with no identifier to ask by (:enrich
-- titles). One pass through the file for all the titles. The record says the paper's
-- number, so that it's proposed with the rest.
service.define("arxiv-title", {
  ident = "title", covers = "crossref-title", pace = 0, hold = 0, batch = 100000,
  available = function() return datasets().path("arxiv-metadata-oai-snapshot.json") ~= nil end,
  request = function(keys)
    local wanted = {}
    for _, key in ipairs(keys) do wanted[key] = true end
    local found, why = M.by_title(datasets().path("arxiv-metadata-oai-snapshot.json"), wanted)
    if not found then return nil, why end
    local out = {}
    for key, ids in pairs(found) do out[key] = service.kept("arxiv-snapshot", ids[1]) end
    return out
  end,
  record = function(answer)
    local fields = M.arxiv_fields(answer)
    local id = answer:match('"id"%s*:%s*"([^"]+)"')
    if fields and id then fields["identifier:arxiv"] = mesr.canonical("arxiv", id) end
    return fields
  end,
})

return M
