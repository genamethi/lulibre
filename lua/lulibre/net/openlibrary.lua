--- Open Library: records by ISBN, from its API or its dumps on this machine.
-- Part of lulibre.net: require that, not this (it adds these functions to
-- lulibre.net's table; lulibre/net/core.lua has what they share).
--
-- @submodule lulibre.net
local M = require "lulibre.net.core"
local json = require "lulibre.json"
local taxonomy = require "lulibre.taxonomy"
local trim, in_batches, file_time, forename_first, lines_with, missed = M._trim, M._in_batches, M._file_time, M._forename_first, M._lines_with, M._missed

-- ---- Open Library ----

local MONTHS = { january = 1, february = 2, march = 3, april = 4, may = 5, june = 6, july = 7, august = 8, september = 9,
  october = 10, november = 11, december = 12 }

--- how many ISBNs go in one request to Open Library
M.OPENLIBRARY_BATCH = 20

local function plain_isbn(isbn)
  return (isbn:gsub("[^%dXx]", ""):upper())
end

--- Ask Open Library about many ISBNs in as few requests as it takes, keeping
-- each answer; M.openlibrary then answers from what was kept. Returns how
-- many were newly fetched.
-- @tparam {string,...} isbns
-- @treturn integer
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
-- @tparam string isbn
-- @treturn[1] table the record
-- @treturn[2] nil
-- @treturn[2] string why not
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
  local rec = { authors = {}, subjects = {}, ids = { isbn = isbn }, type = "book", source = "Open Library " .. isbn,
    pages = tonumber(b.number_of_pages) }
  local title = type(b.title) == "string" and trim(b.title) or nil
  -- "Local Fields\r\n   \r\n   Graduate Texts in Mathematics": a title with the
  -- series under it, after a blank line
  local under
  if title then
    local head, rest = title:match("^(.-)%s*\r?\n%s*\r?\n%s*(.+)$")
    if head and head:find("%a") then title, under = head, rest:gsub("%s+", " ") end
    title = title:gsub("%s+", " ")
  end
  if title then
    -- "Algebraic Geometry (Graduate Texts in Mathematics)": the bracket is the series
    local head, series = title:match("^(.-)%s*%(([^()]+)%)$")
    if head and #head >= 3 and series:find("%a") then
      title = head
      local name, number = series:match("^(.-)%s*[;,]?%s*[vVnNoO.#]*%s*(%d+)$")
      rec.series, rec.series_index = name and #name > 3 and name or series, name and #name > 3 and number or nil
    end
    if type(b.subtitle) == "string" and b.subtitle:find("%S") then title = title .. ": " .. trim(b.subtitle:gsub("%s+", " ")) end
    rec.title = require("lulibre.titlecase").numerals(title)
  end
  -- an edition's own note of its series: "Graduate texts in mathematics ; 52"
  local noted = type(b.series) == "table" and b.series[1]
  -- (the number may be noted apart: { "Progress in brain research ;", "v. 110" })
  local apart = type(noted) == "string" and type(b.series[2]) == "string" and b.series[2]:match("^%s*[vVnN]%a*%.?%s*%d+%s*$")
  if apart then noted = noted .. " " .. apart end
  if type(noted) ~= "string" and under and under:find("%a") then noted = under end
  if not rec.series and type(noted) == "string" and noted:find("%a") then
    local name, number = noted:match("^(.-)%s*[;,:]?%s*%-*%s*[vVnNoO.#]*%s*(%d+)%s*$")
    if not (name and #name > 3) then name, number = noted:gsub("[%s;,:%-]+$", ""), nil end
    rec.series, rec.series_index = require("lulibre.titlecase").apply(trim(name)), number
  end
  for _, a in ipairs(type(b.authors) == "table" and b.authors or {}) do
    -- "Cohen, Henri." is Henri Cohen: a catalogue's way of writing a name is not news
    if type(a.name) == "string" then rec.authors[#rec.authors + 1] = forename_first((a.name:gsub("(%l%l)%.$", "%1"))) end
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

--- Read books' records out of Open Library's dumps instead of asking it: the
-- editions (ol_dump_editions_latest.txt.gz) for a book by its ISBN, and the
-- authors (ol_dump_authors_latest.txt.gz) for their names, which an edition
-- holds only keys to. Both are looked for in lulibre's data folder (see
-- lulibre.datasets); with no editions there, nothing is done. Each record
-- found is kept as an answer from Open Library; an ISBN the dump does not
-- hold is not looked for in it again until the file changes. Returns how
-- many were found, or nil and why.
-- @tparam {string,...} isbns
-- @treturn[1] integer
-- @treturn[2] nil
-- @treturn[2] string why
function M.openlibrary_dump(isbns)
  local datasets = require "lulibre.datasets"
  local ids = require "lulibre.ids"
  local editions, people = datasets.path("ol_dump_editions_latest.txt.gz"), datasets.path("ol_dump_authors_latest.txt.gz")
  if not editions then return 0 end
  local stamp = file_time(editions)
  -- every way an ISBN is written, and the ISBN it was asked for as
  local asked, strings, n, wanted = {}, {}, 0, {}
  for _, raw in ipairs(isbns) do
    local isbn = plain_isbn(raw)
    if not wanted[isbn] and not M.kept("openlibrary", isbn) and not missed("openlibrary-dump", isbn, stamp) then
      wanted[isbn] = true
      n = n + 1
      for _, form in ipairs { isbn, ids.isbn13(isbn) or false, ids.isbn10(isbn) or false } do
        if form and not asked[form] then
          asked[form] = isbn
          strings[#strings + 1] = '"' .. form .. '"'
        end
      end
    end
  end
  if n == 0 then return 0 end
  local lines, whole = lines_with(editions, strings)
  if not lines then return nil, whole end

  -- the edition that says most, for each ISBN
  local best, keys = {}, {}
  for _, line in ipairs(lines) do
    local ok, e = pcall(json.decode, line:match("\t({.*})%s*$") or "")
    if ok and type(e) == "table" and type(e.title) == "string" then
      local score = (type(e.authors) == "table" and #e.authors > 0 and 4 or 0) + (type(e.lc_classifications) == "table" and 2 or 0)
        + (type(e.publishers) == "table" and 1 or 0) + (type(e.publish_date) == "string" and 1 or 0) + (type(e.series) == "table" and 1 or 0)
      for _, field in ipairs { "isbn_13", "isbn_10" } do
        for _, written in ipairs(type(e[field]) == "table" and e[field] or {}) do
          local isbn = type(written) == "string" and asked[plain_isbn(written)]
          if isbn and (not best[isbn] or score > best[isbn].score) then best[isbn] = { score = score, e = e } end
        end
      end
    end
  end
  for _, b in pairs(best) do
    for _, a in ipairs(type(b.e.authors) == "table" and b.e.authors or {}) do
      if type(a) == "table" and type(a.key) == "string" then keys[a.key] = true end
    end
  end
  -- the authors' names
  local names = {}
  if people and next(keys) then
    local wanted = {}
    for key in pairs(keys) do wanted[#wanted + 1] = "\t" .. key .. "\t" end
    for _, line in ipairs(lines_with(people, wanted) or {}) do
      local key = line:match("^[^\t]*\t([^\t]+)\t")
      local ok, a = pcall(json.decode, line:match("\t({.*})%s*$") or "")
      if key and ok and type(a) == "table" and type(a.name) == "string" then names[key] = a.name end
    end
  end

  -- kept in the shape Open Library's own answer has, so that one reader reads both
  local found = 0
  for isbn, b in pairs(best) do
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
      classifications = { lc_classifications = e.lc_classifications, dewey_decimal_class = e.dewey_decimal_class }, series = e.series, key = e.key, number_of_pages = e.number_of_pages,
    }
    -- (a list with nothing in it is left out: written out it would read as a table of fields)
    if #authors > 0 then record.authors = authors end
    if #publishers > 0 then record.publishers = publishers end
    -- under every way of writing the ISBN that was asked for
    for form in pairs(wanted) do
      if asked[form] == isbn then
        M.keep("openlibrary", form, 200, json.encode { ["ISBN:" .. form] = record })
        found = found + 1
      end
    end
  end
  if whole then
    for isbn in pairs(wanted) do
      if not best[asked[isbn]] then M.keep("openlibrary-dump", isbn, 404) end
    end
  end
  return found, whole
end

return M
