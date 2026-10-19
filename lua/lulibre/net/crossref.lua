-- CrossRef: records by DOI, in batches, and a search by title.
-- Part of lulibre.net: require that, not this (it adds these functions to
-- lulibre.net's table; lulibre/net/core.lua has what they share).
local M = require "lulibre.net.core"
local json = require "lulibre.json"
local trim, unescape, encode, in_batches = M._trim, M._unescape, M._encode, M._in_batches

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
    -- an article's page range, as a length: held against the file's (lulibre.verify)
    pages = type(m.page) == "string" and (function()
      local a, b = m.page:match("^%s*(%d+)%s*[-–]%s*(%d+)")
      a, b = tonumber(a), tonumber(b)
      return a and b and b >= a and b - a + 1 or nil
    end)() or nil,
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
  -- CrossRef keeps a subtitle apart from the title: "MATLAB Deep Learning" / "With Machine Learning, ..."
  local sub = type(m.subtitle) == "table" and type(m.subtitle[1]) == "string" and unescape(m.subtitle[1]:gsub("%s+", " "))
  if rec.title and sub and sub ~= "" and not lulibre.fold(rec.title):find(lulibre.fold(sub), 1, true) then
    rec.title = rec.title .. ": " .. sub
  end
  rec.title = rec.title and require("lulibre.titlecase").numerals(rec.title)
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
    return ("https://api.crossref.org/works?filter=%s&rows=%d&select=DOI,type,title,subtitle,author,issued,publisher,ISBN,container-title,page%s"):format(
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

--- Search CrossRef by title; the record only if it is that work (title_match
-- says how). authors: the book's, when it has any worth the name. The
-- record carries `trust`: how far the match can be believed.
function M.crossref_search(title, authors)
  local body, err = M.fetch("crossref-title", lulibre.fold(title),
    "https://api.crossref.org/works?rows=3&query.bibliographic=" .. encode(title) .. mailto("&"))
  if not body then return nil, err end
  local ok, data = pcall(json.decode, body)
  if not ok or type(data) ~= "table" or not data.message then return nil, "unreadable reply from CrossRef" end
  for _, item in ipairs(data.message.items or {}) do
    local rec = crossref_record(item)
    local trust = rec.title and M.title_match(title, rec.title, authors, rec.authors)
    if trust then
      rec.source, rec.trust = "CrossRef title search", trust
      return rec
    end
  end
  return nil, "no confident match"
end

return M
