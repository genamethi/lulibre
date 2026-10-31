--- The packaged services: Crossref (by DOI, and by title), zbMATH (by DOI or
-- arXiv number), OpenAlex (by DOI), Open Library (by ISBN), arXiv (by arXiv
-- number). Each pace is well within what the service asks
-- of callers who do not identify themselves:
--
-- - arXiv: "no more than one request every three seconds", "a single
--   connection at a time" (https://info.arxiv.org/help/api/tou.html)
-- - Crossref: public pool, "Back off if the response times start to increase"
-- - Open Library: "1 request per second" unidentified
-- - zbMATH Open and OpenAlex: paced as 0.2 did, no faster than Crossref
--
-- @submodule net
local service = require "net.service"
local json = require "dkjson"
local stringx = require "pl.stringx"

local function net() return require "net" end

local function encode(s)
  return (s:gsub("[^%w%-%._~/]", function(c) return ("%%%02X"):format(c:byte()) end))
end

-- an HTTP status as request's answer: the body, no record, or a hold
local function status(body, code, retry)
  if code == 200 then return body end
  if code == 404 then return false end
  if code == 429 or code == 503 then return nil, ("the service asked to be left alone (%d)"):format(code), retry or true end
  return nil, ("HTTP %s"):format(tostring(code))
end

-- "123-145" as 23 pages
local function pages_of(range)
  local from, to = tostring(range or ""):match("^(%d+)%s*%-%s*(%d+)$")
  if from and tonumber(to) >= tonumber(from) then return tonumber(to) - tonumber(from) + 1 end
end

local function people(list, given, family)
  local names = {}
  for _, p in ipairs(list or {}) do
    local name = stringx.strip((p[given] or "") .. " " .. (p[family] or ""))
    if name ~= "" then names[#names + 1] = name end
  end
  return #names > 0 and table.concat(names, " & ") or nil
end

-- what Crossref registers as a book's
local BOOKISH = { book = true, monograph = true, ["edited-book"] = true, ["reference-book"] = true, ["book-chapter"] = true,
                  ["book-section"] = true, ["book-series"] = true, ["book-set"] = true }

-- a Crossref item as fields. The member that registered a DOI is the publisher
-- of a book, but often an archive for an article: an article's is its journal,
-- after a house that's known.
local function crossref_fields(m)
  local issued = m.issued and m.issued["date-parts"] and m.issued["date-parts"][1]
  local title = m.title and m.title[1]
  local sub = type(m.subtitle) == "table" and m.subtitle[1]
  local expr = require "expr"
  if title and sub and sub ~= "" and not expr.fold(title):find(expr.fold(sub), 1, true) then
    title = title .. ": " .. sub
  end
  local container = m["container-title"] and m["container-title"][1]
  local bookish = m.type == nil or BOOKISH[m.type]
  local layouts = require "lulib._layouts"
  return {
    title = title and require("lulib._titlecase").numerals((title:gsub("%s+", " "))),
    authors = people(m.author, "given", "family"),
    publisher = bookish and m.publisher or layouts.with_journal(layouts.known_house(m.publisher), container),
    series = bookish and container or nil,
    pubdate = issued and issued[1] and tostring(issued[1]),
    pages = pages_of(m.page),
  }
end

service.define("crossref", {
  ident = "doi", pace = 1, hold = 300, batch = 1,
  request = function(keys, mail)
    local key = keys[1]
    local body, code, retry = net().get("https://api.crossref.org/works/" .. encode(key), mail)
    if not body then return nil, code end
    local answer, err, hold = status(body, code, retry)
    if answer == nil then return nil, err, hold end
    return { [key] = answer }
  end,
  record = function(answer)
    return crossref_fields((json.decode(answer) or {}).message or {})
  end,
})

-- Crossref by title, for a book with no identifier to ask by (:enrich titles).
-- A search always returns something: what's kept is the first of its answers whose
-- title agrees (lulib._check.titles_agree), or no record. Whether it is the book
-- is for proposing to say, which has the book's authors and pages.
service.define("crossref-title", {
  ident = "title", pace = 2, hold = 300, batch = 1,
  request = function(keys, mail)
    local key = keys[1]
    local body, code, retry = net().get("https://api.crossref.org/works?rows=3&query.bibliographic=" .. encode(key), mail)
    if not body then return nil, code end
    local answer, err, hold = status(body, code, retry)
    if answer == nil then return nil, err, hold end
    local check = require "lulib._check"
    for _, item in ipairs(((json.decode(answer or "") or {}).message or {}).items or {}) do
      local fields = crossref_fields(item)
      if fields.title and check.titles_agree(key, fields.title) then return { [key] = json.encode(item) } end
    end
    return { [key] = false }
  end,
  record = function(answer)
    return crossref_fields(json.decode(answer) or {})
  end,
})

-- "Family, Given" as "Given Family"
local function forename_first(name)
  local family, given = name:match("^([^,]+),%s*(.+)$")
  return family and (stringx.strip(given) .. " " .. stringx.strip(family)) or name
end

-- zbMATH Open classifies each work by hand: its MSC codes are the best source of
-- a mathematics work's subject. Asked by DOI or arXiv number.
service.define("zbmath", {
  ident = { "doi", "arxiv" }, pace = 2, hold = 300, batch = 1,
  request = function(keys, mail)
    local key = keys[1]
    local param = key:find("^10%.") and "DOI=" or "arXiv%20ID="
    local body, code, retry = net().get("https://api.zbmath.org/v1/document/_structured_search?page=0&results_per_page=1&"
                                        .. param .. encode(key), mail)
    if not body then return nil, code end
    local answer, err, hold = status(body, code, retry)
    if answer == nil then return nil, err, hold end
    local doc = ((answer and json.decode(answer)) or {}).result
    if type(doc) ~= "table" or not doc[1] then return { [key] = false } end
    return { [key] = json.encode(doc[1]) }
  end,
  record = function(answer)
    local doc = json.decode(answer) or {}
    local names = {}
    for _, a in ipairs(type(doc.contributors) == "table" and doc.contributors.authors or {}) do
      if type(a.name) == "string" then names[#names + 1] = forename_first(a.name) end
    end
    local title = type(doc.title) == "table" and type(doc.title.title) == "string" and doc.title.title or nil
    local taxonomy = require "lulib._taxonomy"
    local tags, seen = {}, {}
    for _, m in ipairs(type(doc.msc) == "table" and doc.msc or {}) do
      local area = type(m.code) == "string" and m.code:match("^(%d%d)")
      local tag = area and taxonomy.msc[area]
      if tag and not seen[tag] and tag ~= "math/general" then
        seen[tag] = true
        tags[#tags + 1] = tag
      end
    end
    return {
      title = title and (title:gsub("%s+", " "):gsub("%s*%.$", "")),
      authors = #names > 0 and table.concat(names, " & ") or nil,
      pubdate = doc.year and tostring(doc.year),
      tags = #tags > 0 and table.concat(tags, ", ") or nil,
    }
  end,
})

-- OpenAlex: works Crossref doesn't have. (No subject is taken from it: it sorts
-- works into topics by machine.)
service.define("openalex", {
  ident = "doi", pace = 1, hold = 300, batch = 1,
  request = function(keys, mail)
    local key = keys[1]
    local body, code, retry = net().get("https://api.openalex.org/works/doi:" .. encode(key), mail)
    if not body then return nil, code end
    local answer, err, hold = status(body, code, retry)
    if answer == nil then return nil, err, hold end
    return { [key] = answer }
  end,
  record = function(answer)
    local w = json.decode(answer) or {}
    local names = {}
    for _, a in ipairs(type(w.authorships) == "table" and w.authorships or {}) do
      if type(a.author) == "table" and type(a.author.display_name) == "string" then names[#names + 1] = a.author.display_name end
    end
    local place = type(w.primary_location) == "table" and type(w.primary_location.source) == "table" and w.primary_location.source
    local layouts = require "lulib._layouts"
    return {
      title = type(w.title) == "string" and (w.title:gsub("%s+", " ")) or nil,
      authors = #names > 0 and table.concat(names, " & ") or nil,
      pubdate = w.publication_date or (w.publication_year and tostring(w.publication_year)),
      publisher = place and type(place.display_name) == "string"
        and layouts.with_journal(layouts.known_house(place.host_organization_name), place.display_name) or nil,
    }
  end,
})

service.define("openlibrary", {
  ident = "isbn", pace = 2, hold = 300, batch = 1,
  request = function(keys, mail)
    local key = keys[1]
    local body, code, retry = net().get(("https://openlibrary.org/api/books?bibkeys=ISBN:%s&format=json&jscmd=data"):format(key), mail)
    if not body then return nil, code end
    local answer, err, hold = status(body, code, retry)
    if answer == nil then return nil, err, hold end
    if answer and answer:match("^%s*{%s*}%s*$") then answer = false end
    return { [key] = answer }
  end,
  record = function(answer)
    local _, b = next(json.decode(answer) or {})
    b = b or {}
    local authors = {}
    for _, a in ipairs(b.authors or {}) do authors[#authors + 1] = a.name end
    local year = b.publish_date and b.publish_date:match("%d%d%d%d")
    return {
      title = b.title and (b.subtitle and (b.title .. ": " .. b.subtitle) or b.title),
      authors = #authors > 0 and table.concat(authors, " & ") or nil,
      publisher = b.publishers and b.publishers[1] and b.publishers[1].name,
      pubdate = year,
      pages = tonumber(b.number_of_pages),
    }
  end,
})

local function xml_text(s)
  return stringx.strip((s:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&amp;", "&")
    :gsub("%s+", " ")))
end

service.define("arxiv", {
  ident = "arxiv", pace = 5, hold = 1800, batch = 40,
  request = function(keys, mail)
    local url = "https://export.arxiv.org/api/query?max_results=" .. #keys .. "&id_list=" .. table.concat(keys, ",")
    local body, code, retry = net().get(url, mail)
    if not body then return nil, code end
    local answer, err, hold = status(body, code, retry)
    if answer == nil then return nil, err, hold end
    local out = {}
    for entry in (answer or ""):gmatch("<entry>(.-)</entry>") do
      local id = entry:match("<id>[^<]*/abs/([^<]-)v?%d*</id>")
      if id then out[id] = "<entry>" .. entry .. "</entry>" end
    end
    return out
  end,
  record = function(answer)
    local authors = {}
    for name in answer:gmatch("<author>%s*<name>(.-)</name>") do authors[#authors + 1] = xml_text(name) end
    return {
      title = xml_text(answer:match("<title>(.-)</title>") or ""),
      authors = #authors > 0 and table.concat(authors, " & ") or nil,
      pubdate = answer:match("<published>(%d%d%d%d)"),
      pages = tonumber(answer:match("<arxiv:comment[^>]*>.-(%d+)%s+pages")),
    }
  end,
})
