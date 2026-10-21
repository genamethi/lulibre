--- Identifiers found in page text: DOI, ISBN, arXiv id, MSC area.
--
-- @module lulibre.ids
-- @usage
-- local ids = require "lulibre.ids"
-- ids.isbn("ISBN 0-387-90040-3")       --> "0387900403"
-- ids.isbn13("0387900403")              --> "9780387900407"
-- ids.doi_in(text)                      --> "10.1007/...", true (its own)
-- ids.arxiv("arXiv:1012.6008v1 [math.CO]") --> "1012.6008", "math.CO"
local M = {}

-- A DOI runs to the first space, comma, quote or bracket; a parenthesis is
-- part of it when it is closed within it (Elsevier's "S1570-7954(96)80014-3"),
-- and a closing one it did not open ends it ("(see doi:10.1/x)").
local DOI = "10%.%d%d%d%d+/[^%s,;\"'%]>]+"
local function trim_doi(d)
  d = d:gsub("[%.]+$", "")
  while d:sub(-1) == ")" and select(2, d:gsub("%(", "")) < select(2, d:gsub("%)", "")) do d = d:sub(1, -2) end
  local open = d:find("%)") and select(2, d:gsub("%(", "")) < select(2, d:gsub("%)", "")) and d:find("%)")
  if open then d = d:sub(1, open - 1) end
  return (d:gsub("[%.]+$", ""))
end

--- The first DOI in a text, its trailing punctuation trimmed.
-- @tparam string text
-- @treturn string|nil
function M.doi(text)
  local d = text:match(DOI)
  return d and trim_doi(d) or nil
end

--- Bytes from the start of a text that count as its top (`doi_in`).
M.DOI_TOP = 4000

--- The DOI in a text, and whether it reads as the text's own rather than
-- that of a work it cites. Its own: near the top (a journal's heading, a
-- cover sheet), or on a line that holds nothing but the DOI and its label
-- ("DOI 10.1007/...", "https://doi.org/10...") before any list of
-- references has begun. One that follows other words on its line further
-- down ("... Linearization for Dylan: https://doi.org/10...") or stands
-- among the references is a citation.
-- @tparam string text
-- @treturn[1] string the DOI
-- @treturn[1] boolean is it the text's own
-- @treturn[2] nil when there is none
function M.doi_in(text)
  local s, e = text:find(DOI)
  if not s then return nil end
  local doi = trim_doi(text:sub(s, e))
  if s <= M.DOI_TOP then return doi, true end
  local low = text:sub(1, s - 1):lower()
  if low:find("\n%s*references%s*\n", M.DOI_TOP) or low:find("\n%s*bibliography%s*\n", M.DOI_TOP) then return doi, false end
  local label = (low:match("([^\n]*)$") or ""):gsub("^%s+", ""):gsub("%s+$", "")
  -- "doi", "doi:" (and what a scan makes of it: "dol:", "d0i"), or an address with it and nothing else
  local own = label:find("^d[o0][il1]:?$") or label:find("^digital object identifier:?$")
    or (not label:find("%s") and label:find("d[o0][il1]"))
  return doi, own and true or false
end

--- The identifiers a file's own metadata gives it (lulibre.doc_metadata:
-- a PDF's XMP packet and Info dictionary, an EPUB's package document).
-- Only those labelled as the work's own are taken: prism:doi, pdfx:doi,
-- crossmark:DOI, dc:identifier (with a doi or isbn scheme or prefix), and
-- an Info entry named doi or a "doi:" in its Subject. Returns a list of
-- { kind=, value=, where= } ("XMP", "PDF info", "EPUB package").
-- @tparam string text `lulibre.doc_metadata`'s
-- @treturn {table,...}
function M.from_metadata(text)
  local out, seen = {}, {}
  if not text or text == "" then return out end
  local where = text:find("<package", 1, true) and "EPUB package" or "XMP"
  local function add(kind, value, place)
    if kind == "isbn" then value = M.isbn13(value) end
    if kind == "doi" then value = value and M.doi(value) end
    -- arXiv's own DOIs (10.48550/arXiv.2504.14413) stand for the arXiv number
    local ax = kind == "doi" and value and value:match("^10%.48550/[aA][rR][xX][iI][vV]%.(.+)$")
    if ax then kind, value = "arxiv", ax end
    if value and not seen[kind .. ":" .. value:lower()] then
      seen[kind .. ":" .. value:lower()] = true
      out[#out + 1] = { kind = kind, value = value, where = place }
    end
  end
  -- elements and attributes that name the DOI
  for _, tag in ipairs { "prism:doi", "pdfx:doi", "crossmark:DOI", "pdfx:DOI", "prism:DOI" } do
    for v in text:gmatch("<" .. tag:gsub("%p", "%%%0") .. "[^>]*>%s*([^<]+)") do add("doi", v, where) end
    for v in text:gmatch(tag:gsub("%p", "%%%0") .. '="([^"]+)"') do add("doi", v, where) end
  end
  -- dc:identifier: an rdf:li list, or the element itself (EPUB)
  for block in text:gmatch("<dc:identifier[^>]*>(.-)</dc:identifier>") do
    local items = {}
    for li in block:gmatch("<rdf:li[^>]*>%s*([^<]+)") do items[#items + 1] = li end
    if #items == 0 then items[1] = block end
    for _, v in ipairs(items) do
      local low = v:lower()
      if low:find("isbn") or (low:gsub("[^%dx]", "")):match("^97[89]%d%d%d%d%d%d%d%d%d%d$") then add("isbn", v:gsub("^.-isbn:?", ""), where)
      elseif low:find("10%.%d%d%d%d") then add("doi", v, where) end
    end
  end
  -- an EPUB names the scheme in an attribute: <dc:identifier opf:scheme="ISBN">
  for scheme, v in text:gmatch('<dc:identifier[^>]-scheme="(%a+)"[^>]*>%s*([^<]+)') do
    if scheme:lower() == "isbn" then add("isbn", v, where) elseif scheme:lower() == "doi" then add("doi", v, where) end
  end
  -- the Info dictionary, as "Key: value" lines
  for key, v in text:gmatch("\n?([%w_]+): ([^\n]*)") do
    local k = key:lower()
    if k == "doi" then add("doi", v, "PDF info")
    elseif k == "subject" or k == "keywords" then
      local d = v:match("[dD][oO][iI]:?%s*(10%.%d%d%d%d+/%S+)")
      if d then add("doi", d, "PDF info") end
    end
  end
  return out
end

local function isbn13_ok(d)
  local sum = 0
  for i = 1, 13 do sum = sum + (d:byte(i) - 48) * (i % 2 == 0 and 3 or 1) end
  return sum % 10 == 0
end

local function isbn10_ok(d)
  local sum = 0
  for i = 1, 10 do
    local c = d:sub(i, i)
    local n = (c == "X" or c == "x") and 10 or tonumber(c)
    if not n or (n == 10 and i < 10) then return false end
    sum = sum + n * (11 - i)
  end
  return sum % 11 == 0
end

--- An ISBN of ten figures as one of thirteen ("0387900403" is
-- "9780387900407"), or nil if it is not one.
-- @tparam string isbn
-- @treturn string|nil
function M.isbn13(isbn)
  local d = tostring(isbn):gsub("[^%dXx]", ""):upper()
  if #d == 13 then return isbn13_ok(d) and d or nil end
  if #d ~= 10 or not isbn10_ok(d) then return nil end
  local body, sum = "978" .. d:sub(1, 9), 0
  for i = 1, 12 do sum = sum + (body:byte(i) - 48) * (i % 2 == 0 and 3 or 1) end
  return body .. tostring((10 - sum % 10) % 10)
end

--- An ISBN of thirteen figures as one of ten, where there is one (those
-- that begin 978), or nil.
-- @tparam string isbn
-- @treturn string|nil
function M.isbn10(isbn)
  local d = tostring(isbn):gsub("[^%dXx]", ""):upper()
  if #d == 10 then return isbn10_ok(d) and d or nil end
  if #d ~= 13 or d:sub(1, 3) ~= "978" or not isbn13_ok(d) then return nil end
  local body, sum = d:sub(4, 12), 0
  for i = 1, 9 do sum = sum + (body:byte(i) - 48) * (11 - i) end
  local check = (11 - sum % 11) % 11
  return body .. (check == 10 and "X" or tostring(check))
end

--- The first ISBN whose check digit is right. The Python version accepted
-- any 13 digits starting 97, which let page ranges and phone numbers through.
-- @tparam string text
-- @treturn string|nil
function M.isbn(text)
  for cand in text:gmatch("97[89][%d%- ]+") do
    local d = cand:gsub("%D", "")
    if #d >= 13 and isbn13_ok(d:sub(1, 13)) then return d:sub(1, 13) end
  end
  for _, pat in ipairs({ "ISBN[%- ]*10[: ]+([%dXx][%dXx%- ]+)", "ISBN[: ]*([%dXx][%dXx%- ]+)" }) do
    for cand in text:gmatch(pat) do
      local d = cand:gsub("[^%dXx]", "")
      if #d >= 10 and isbn10_ok(d:sub(1, 10)) then return d:sub(1, 10):upper() end
    end
  end
  return nil
end

--- The margin stamp "arXiv:1012.6008v1 [math.CO] 29 Dec 2010": id and class.
-- @tparam string text
-- @treturn[1] string the id
-- @treturn[1] string the class
-- @treturn[2] nil
function M.arxiv_stamp(text)
  local id, class = text:match("arXiv:%s*(%S-)%s*%[([%w%.%-]+)%]")
  if not id then return nil end
  return (id:gsub("v%d+$", "")), class
end

--- An arXiv id from page text, else from a file name that is nothing but one.
-- @tparam string text
-- @tparam[opt] string filename
-- @treturn string|nil the id
-- @treturn[opt] string its class, where the margin stamp gives one
function M.arxiv(text, filename)
  local id, class = M.arxiv_stamp(text)
  if id then return id, class end
  id = text:match("arXiv:%s*(%d%d%d%d%.%d%d%d%d%d?)") or text:match("arXiv:%s*([%a%-]+/%d%d%d%d%d%d%d)")
  if id then return id end
  if filename then
    local stem = filename:gsub("^.*/", ""):gsub("%.%w+$", "")
    return stem:match("^(%d%d%d%d%.%d%d%d%d%d?)v?%d*$")
  end
  return nil
end

--- Year an arXiv id was assigned: 1012.6008 -> 2010, math/0601054 -> 2006.
-- @tparam string id
-- @treturn integer|nil
function M.arxiv_year(id)
  local yy = id:match("^(%d%d)%d%d%.") or id:match("/(%d%d)%d%d%d%d%d$")
  if not yy then return nil end
  yy = tonumber(yy)
  return yy >= 91 and 1900 + yy or 2000 + yy
end

--- Two-digit MSC area from a "Mathematics Subject Classification" footnote.
-- @tparam string text
-- @treturn string|nil
function M.msc(text)
  local i = text:find("[Ss]ubject%s+[Cc]lassif") or text:find("MSC%s*%d*%s*[:%(]")
  if not i then return nil end
  return text:sub(i, i + 160):match("(%d%d)%u%d%d")
end

return M
