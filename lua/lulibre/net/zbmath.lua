-- zbMATH Open: records by DOI or arXiv number, and its table of links to arXiv.
-- Part of lulibre.net: require that, not this (it adds these functions to
-- lulibre.net's table; lulibre/net/core.lua has what they share).
local M = require "lulibre.net.core"
local json = require "lulibre.json"
local taxonomy = require "lulibre.taxonomy"
local encode, forename_first, lines_with = M._encode, M._forename_first, M._lines_with

-- ---- zbMATH Open ----

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

--- The zbMATH number of arXiv papers, from the table of zbMATH's links to
-- full texts (zbmath-oa_links.csv in the data folder: "zbmath_id,link", the
-- link mostly "https://arxiv.org/pdf/1111.2222.pdf"). Returns { [arXiv
-- number] = zbMATH number }; an empty table when the file is not there.
function M.zbmath_links(arxiv_ids)
  local path = require("lulibre.datasets").path("zbmath-oa_links.csv")
  local out, wanted, strings = {}, {}, {}
  if not path then return out end
  for _, raw in ipairs(arxiv_ids) do
    local id = M.arxiv_id(raw)
    if id and not wanted[id] then
      wanted[id] = true
      strings[#strings + 1] = "arxiv.org/pdf/" .. id
      strings[#strings + 1] = "arxiv.org/abs/" .. id
    end
  end
  if #strings == 0 then return out end
  for _, line in ipairs(lines_with(path, strings) or {}) do
    local number, id = line:match("^(%d+),https?://arxiv%.org/%a+/(.-)%s*$")
    id = id and M.arxiv_id((id:gsub("%.pdf$", "")))
    if id and wanted[id] then out[id] = number end
  end
  return out
end

return M
