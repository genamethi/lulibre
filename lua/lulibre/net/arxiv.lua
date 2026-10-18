-- arXiv: its API, its snapshot of every paper's record, titles looked up in it.
-- Part of lulibre.net: require that, not this (it adds these functions to
-- lulibre.net's table; lulibre/net/core.lua has what they share).
local M = require "lulibre.net.core"
local detex = require "lulibre.detex"
local json = require "lulibre.json"
local taxonomy = require "lulibre.taxonomy"
local trim, unescape, paused, gave_up, give_up, file_time = M._trim, M._unescape, M._paused, M._gave_up, M._give_up, M._file_time

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

--- A title as compared when looking papers up by it: folded, every run of
-- what is not a letter or a figure one space.
function M.title_key(title)
  return (lulibre.fold(title or ""):gsub("%$", ""):gsub("[^%w\128-\255]+", " "):gsub("^ ", ""):gsub(" $", ""))
end

--- Look papers up by title in arXiv's own snapshot (the file of one JSON
-- record a line; a hypergraph has no use here), asking nobody. wanted:
-- { [M.title_key(title)] = true }. Every record whose title is one of them
-- is kept as arXiv's answer for its number. Returns { [key] = { id, ... } }
-- and how many papers were passed, or nil and why.
function M.arxiv_by_title(path, wanted, progress)
  local f, err = io.open(path, "r")
  if not f then return nil, ("cannot read %s: %s"):format(path, tostring(err)) end
  local head = f:read(4096) or ""
  if not (head:find('^%s*{%s*"id"%s*:') or head:find('"versions"')) then
    f:close()
    return nil, path .. " is not arXiv's own snapshot (one record a line): looking up by title needs that one"
  end
  f:seek("set", 0)
  local out, n = {}, 0
  for line in f:lines() do
    n = n + 1
    local raw = line:match('"title"%s*:%s*"(.-[^\\])"%s*,')
    if raw then
      local ok, title = pcall(json.decode, '"' .. raw .. '"')
      local key = M.title_key(ok and title or raw)
      if wanted[key] then
        local id = M.arxiv_id(line:match('"id"%s*:%s*"([^"]+)"') or "")
        if id and snapshot_record(line) then
          M.keep("arxiv", id, 200, line)
          out[key] = out[key] or {}
          table.insert(out[key], id)
        end
      end
    end
    if progress and n % 200000 == 0 then progress(("%.1f million papers"):format(n / 1e6)) end
  end
  f:close()
  return out, n
end

--- The record kept for a work, read from what was kept and asking nobody:
-- kind is "doi" (CrossRef, else OpenAlex), "isbn" (Open Library) or "arxiv".
-- nil when nothing was kept. It neither waits nor reads the arXiv snapshot.
function M.kept_record(kind, value)
  if not value or value == "" then return nil end
  local tries
  if kind == "doi" then
    tries = { { "crossref", value:lower(), M.crossref }, { "openalex", value:lower(), M.openalex } }
  elseif kind == "isbn" then
    local digits = value:gsub("[^%dXx]", ""):upper()
    tries = { { "openlibrary", digits, M.openlibrary } }
  elseif kind == "arxiv" then
    local id = M.arxiv_id(value)
    tries = { { "arxiv", id, M.arxiv } }
  else
    return nil
  end
  for _, t in ipairs(tries) do
    if t[2] and M.kept(t[1], t[2]) then
      local was = M.offline
      M.offline = true
      local ok, rec = pcall(t[3], value)
      M.offline = was
      if ok and type(rec) == "table" then return rec end
    end
  end
  return nil
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

return M
