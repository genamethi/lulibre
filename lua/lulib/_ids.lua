--- A file's identifiers, and which are its own and which it only mentions.
--
-- The file's own metadata first: only identifiers labelled as the work's
-- own count there. Then the text up to its references or bibliography, what
-- follows being other works'. In the text an identifier is the file's own
-- when:
--
-- - an ISBN has its label before it;
-- - a DOI is in the first `id_top` bytes, or begins a line with its label;
-- - an arXiv number is in the first `id_top` bytes, or has its margin
--   stamp's class after it (arXiv:1012.6008v1 [math.CO]).
--
-- A file named only by an arXiv number has that one too. An ISSN is a
-- series', never one work's: it is found but never the file's own. The first
-- reading is kept (lulib._kept).
--
-- @library lulib._ids
local expr = require "expr"
local lex = require "lex"
local kept = require "lulib._kept"
local mesr = require "mesr"
local txt = require "txt"

local M = {}

local P, S, R, Cc, Cp, Ct = expr.P, expr.S, expr.R, expr.Cc, expr.Cp, expr.Ct

-- word in any case
local function nocase(word)
  local p = P(true)
  for c in word:gmatch(".") do p = p * S(c:lower() .. c:upper()) end
  return p
end

-- a heading alone on its line, numbered or not
local blank = S " \t"
local heading = S "\n\f" * blank ^ 0 * (R "09" ^ 1 * S ". " ^ 0) ^ -1
  * (nocase "references" + nocase "bibliography" + nocase "bibliographie" + nocase "literatur")
  * blank ^ 0 * S ":." ^ -1 * blank ^ 0 * S "\n\f"

--- Where a text's references begin, or nil.
function M.references(text)
  return (expr.find(text, heading))
end

-- a capture's number and class under their names
local function named(kind)
  local function id_of(id, class) return { value = id, class = class } end
  local labelled = lex.labelled[kind] and (lex.labelled[kind] / id_of) * Cc(true) or P(false)
  local bare = (lex[kind] / id_of) * Cc(false)
  return Cp() * (labelled + bare) * Cp() / function(start, id, is_labelled, stop)
    return { kind = kind, value = id.value, class = id.class, labelled = is_labelled, start = start, stop = stop - 1 }
  end
end

local scan = Ct((named "isbn" + named "doi" + named "arxiv" + named "issn" + 1) ^ 0)

-- whether the text has only a line's blanks before position pos
local function begins_line(text, pos)
  local i = pos - 1
  while i >= 1 do
    local c = text:sub(i, i)
    if c == "\n" or c == "\f" then return true end
    if c ~= " " and c ~= "\t" then return false end
    i = i - 1
  end
  return true
end

-- an arXiv DOI stands for the arXiv number
local function arxiv_doi(found)
  local ax = found.kind == "doi" and found.value:match("^10%.48550/arxiv%.(.+)$")
  if ax then found.kind, found.value = "arxiv", ax end
end

--- The identifiers in a text, in order, none twice: `{ kind=, value=,
-- start=, stop=, own= }`.
-- @tparam string text
-- @tparam integer top the setting id_top
function M.in_text(text, top)
  local stop_at = M.references(text) or math.huge
  local out, seen = {}, {}
  for _, f in ipairs(expr.match(text, scan) or {}) do
    if f.start < stop_at then
      arxiv_doi(f)
      if f.kind == "isbn" then f.own = f.labelled
      elseif f.kind == "doi" then f.own = f.start <= top or (f.labelled and begins_line(text, f.start))
      elseif f.kind == "arxiv" then f.own = f.start <= top or f.class ~= nil
      else f.own = false end
      local key = f.kind .. ":" .. f.value
      if seen[key] then
        seen[key].own = seen[key].own or f.own
      else
        seen[key] = { kind = f.kind, value = f.value, start = f.start, stop = f.stop, own = f.own }
        out[#out + 1] = seen[key]
      end
    end
  end
  return out
end

--- The identifiers in a file's own metadata, as `txt.metadata` gives it:
-- prism:doi, pdfx:doi, crossmark:DOI, dc:identifier (with a doi or isbn
-- scheme or prefix), and an Info entry named doi or a "doi:" in the Info
-- Subject or Keywords.
-- @treturn {table,...} `{ kind=, value=, own = true }`
function M.in_metadata(text)
  local out, seen = {}, {}
  if not text or text == "" then return out end
  local function add(kind, value)
    value = value and mesr.canonical(kind, (value:gsub("^%s+", ""):gsub("%s+$", "")))
    if not value then return end
    local f = { kind = kind, value = value, own = true }
    arxiv_doi(f)
    local key = f.kind .. ":" .. f.value
    if not seen[key] then
      seen[key] = true
      out[#out + 1] = f
    end
  end
  for _, tag in ipairs { "prism:doi", "pdfx:doi", "crossmark:DOI", "pdfx:DOI", "prism:DOI" } do
    local esc = tag:gsub("%p", "%%%0")
    for v in text:gmatch("<" .. esc .. "[^>]*>%s*([^<]+)") do add("doi", v) end
    for v in text:gmatch(esc .. '="([^"]+)"') do add("doi", v) end
  end
  -- dc:identifier: an rdf:li list, or the element itself (EPUB)
  for block in text:gmatch("<dc:identifier[^>]*>(.-)</dc:identifier>") do
    local items = {}
    for li in block:gmatch("<rdf:li[^>]*>%s*([^<]+)") do items[#items + 1] = li end
    if #items == 0 then items[1] = block end
    for _, v in ipairs(items) do
      local low = v:lower()
      if low:find("isbn") or low:gsub("[^%dx]", ""):match("^97[89]%d%d%d%d%d%d%d%d%d%d$") then
        add("isbn", (v:gsub("^.-[iI][sS][bB][nN]:?", "")))
      elseif low:find("10%.%d%d%d%d") then
        add("doi", v)
      end
    end
  end
  -- an EPUB names the scheme in an attribute: <dc:identifier opf:scheme="ISBN">
  for scheme, v in text:gmatch('<dc:identifier[^>]-scheme="(%a+)"[^>]*>%s*([^<]+)') do
    local low = scheme:lower()
    if low == "isbn" or low == "doi" then add(low, v) end
  end
  -- the Info dictionary, as "Key: value" lines
  for key, v in text:gmatch("\n?([%w_]+): ([^\n]*)") do
    local k = key:lower()
    if k == "doi" then add("doi", v)
    elseif k == "subject" or k == "keywords" then
      local d = v:match("[dD][oO][iI]:?%s*(10%.%d%d%d%d+/%S+)")
      if d then add("doi", d) end
    end
  end
  return out
end

--- A file named only by an arXiv number: that number, or nil.
function M.in_name(path)
  local stem = (path or ""):gsub("^.*/", ""):gsub("%.%w+$", "")
  local id = stem:match("^(%d%d%d%d%.%d%d%d%d%d?)v?%d*$")
  return id and { kind = "arxiv", value = id, own = true } or nil
end

--- A file's identifiers, its metadata's first: kept once worked out.
-- @tparam table file a row of bookman.files
-- @param k the file's lulib._kept
-- @param text its lulib._kept.reader
-- @tparam integer top the setting id_top
-- @treturn {table,...} `{ kind=, value=, own=, start=, stop= }`
function M.of(file, k, text, top)
  local list = k:get("ids", "")
  if list then return list end
  list = {}
  local seen = {}
  local function take(f)
    local key = f.kind .. ":" .. f.value
    if seen[key] then
      seen[key].own = seen[key].own or f.own
    else
      seen[key] = f
      list[#list + 1] = f
    end
  end
  local meta = txt.metadata(file.id)
  for _, f in ipairs(M.in_metadata(meta)) do take(f) end
  local named_id = M.in_name(file.path)
  if named_id then take(named_id) end
  local t = text.get()
  if t then
    for _, f in ipairs(M.in_text(t.text, top)) do take(f) end
  end
  k:put("ids", "", list)
  return list
end

--- A book's identifiers: those of the file it is read from, or none.
function M.book(book)
  local file = kept.file_of(book)
  if not file then return {} end
  local k <close> = kept.open(file.id, file.indexed)
  local text <close> = kept.reader(file)
  return M.of(file, k, text, setman.get("id_top"))
end

return M
