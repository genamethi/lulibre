--- The packaged services: Crossref (by DOI), Open Library (by ISBN),
-- arXiv (by arXiv number). Each pace is well within what the service asks
-- of callers who do not identify themselves:
--
-- - arXiv: "no more than one request every three seconds", "a single
--   connection at a time" (https://info.arxiv.org/help/api/tou.html)
-- - Crossref: public pool, "Back off if the response times start to increase"
-- - Open Library: "1 request per second" unidentified
--
-- @submodule lulibre.net
local service = require "lulibre.net.service"
local json = require "dkjson"

local function net() return require "lulibre.net" end

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

local function people(list, given, family)
  local names = {}
  for _, p in ipairs(list or {}) do
    local name = ((p[given] or "") .. " " .. (p[family] or "")):gsub("^%s+", ""):gsub("%s+$", "")
    if name ~= "" then names[#names + 1] = name end
  end
  return #names > 0 and table.concat(names, " & ") or nil
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
    local m = (json.decode(answer) or {}).message or {}
    local issued = m.issued and m.issued["date-parts"] and m.issued["date-parts"][1]
    return {
      title = m.title and m.title[1],
      authors = people(m.author, "given", "family"),
      publisher = m.publisher,
      series = m["container-title"] and m["container-title"][1],
      year = issued and issued[1] and tostring(issued[1]),
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
      year = year,
    }
  end,
})

local function xml_text(s)
  return (s:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&amp;", "&")
    :gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
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
      year = answer:match("<published>(%d%d%d%d)"),
    }
  end,
})
