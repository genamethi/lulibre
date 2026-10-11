-- Metadata services, through curl so nothing blocks. Every function here
-- waits, so call them from a task.
local json = require "lulibre.json"

local M = {}

local AGENT = "lulibre/0.1 (library metadata lookup)"

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function unescape(s)
  return (s:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&amp;", "&"))
end

--- GET a URL. Returns the body, or nil and a message.
function M.get(url)
  local r, err = lulibre.system({ "curl", "-sS", "-L", "--fail", "--max-time", "25", "-A", AGENT, url },
    { timeout = 30000 })
  if not r then return nil, err end
  if r.code ~= 0 then return nil, trim(r.stderr) ~= "" and trim(r.stderr) or ("curl exited " .. r.code) end
  return r.stdout
end

local function encode(s)
  return (s:gsub("[^%w%-%._~]", function(c) return ("%%%02X"):format(c:byte()) end))
end

--- arXiv's record for an id: { title=, authors={...}, class=, year=, summary= }.
function M.arxiv(id)
  local body, err = M.get("https://export.arxiv.org/api/query?max_results=1&id_list=" .. encode(id))
  if not body then return nil, err end
  local entry = body:match("<entry>(.-)</entry>")
  if not entry then return nil, "arXiv has no record of " .. id end
  local title = entry:match("<title[^>]*>(.-)</title>")
  if not title or trim(title) == "Error" then return nil, "arXiv has no record of " .. id end
  local authors = {}
  for name in entry:gmatch("<name>(.-)</name>") do authors[#authors + 1] = unescape(trim(name)) end
  return {
    title = unescape(trim(title):gsub("%s+", " ")),
    authors = authors,
    class = entry:match('primary_category[^>]-term="([^"]+)"'),
    year = tonumber(entry:match("<published>(%d%d%d%d)")),
    summary = unescape(trim(entry:match("<summary[^>]*>(.-)</summary>") or ""):gsub("%s+", " ")),
  }
end

local function crossref_record(m)
  local authors = {}
  for _, a in ipairs(m.author or {}) do
    local name = trim((a.given or "") .. " " .. (a.family or a.name or ""))
    if name ~= "" then authors[#authors + 1] = name end
  end
  local issued = m.issued and m.issued["date-parts"] and m.issued["date-parts"][1]
  return {
    title = m.title and m.title[1] and unescape(m.title[1]:gsub("%s+", " ")) or nil,
    authors = authors, publisher = m.publisher, year = issued and issued[1],
    doi = m.DOI, isbn = m.ISBN and m.ISBN[1], type = m.type,
    container = m["container-title"] and m["container-title"][1],
  }
end

--- CrossRef's record for a DOI: { title=, authors=, publisher=, year=, ... }.
function M.crossref(doi)
  local body, err = M.get("https://api.crossref.org/works/" .. encode(doi))
  if not body then return nil, err end
  local ok, data = pcall(json.decode, body)
  if not ok or type(data) ~= "table" or not data.message then return nil, "unreadable reply from CrossRef" end
  return crossref_record(data.message)
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
  local body, err = M.get("https://api.crossref.org/works?rows=3&query.bibliographic=" .. encode(title))
  if not body then return nil, err end
  local ok, data = pcall(json.decode, body)
  if not ok or type(data) ~= "table" or not data.message then return nil, "unreadable reply from CrossRef" end
  for _, item in ipairs(data.message.items or {}) do
    local rec = crossref_record(item)
    if rec.title and M.same_title(title, rec.title) then return rec end
  end
  return nil, "no confident match"
end

return M
