--- A file's identifiers, and which are its own and which it only mentions.
--
-- The file's own metadata first: only identifiers labelled as the work's
-- own count there. Then the text up to its references or bibliography, what
-- follows being other works'. Such a word alone on a line means that only in
-- the end of a document, from the share id_refs_from of its pages on: earlier
-- they are a contents page's, a title's or a running head's. In the text an
-- identifier is the file's own when:
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
  * (nocase "references" + nocase "bibliography" + nocase "bibliographie" + nocase "literaturverzeichnis"
     + nocase "literature" + nocase "literatur" + nocase "works cited" + nocase "bibliografia")
  * blank ^ 0 * S ":." ^ -1 * blank ^ 0 * #S "\n\f"
local headings = Ct((Cp() * heading + 1) ^ 0)

-- how far through the document a position of its text is, 0 to 1: how far
-- its page reaches, so that references that begin at the top of a short
-- paper's last page count; in a document of one page, by the bytes
local function share_at(text, pos, pages)
  if pages <= 1 then return (pos - 1) / math.max(1, #text) end
  local page, stop = 1, text:find("\f", 1, true)
  while stop and stop < pos do
    page = page + 1
    stop = text:find("\f", stop + 1, true)
  end
  return page / pages
end

--- Where a text's references begin, or nil: the first such heading from the
-- share `from` of the document on.
-- @tparam string text
-- @tparam[opt] integer pages the document's pages, of which the text may hold
-- only the first; by default those the text holds
-- @tparam[opt] number from the setting id_refs_from
function M.references(text, pages, from)
  if not pages or pages <= 0 then pages = select(2, text:gsub("\f", "")) + 1 end
  for _, pos in ipairs(expr.match(text, headings) or {}) do
    if share_at(text, pos + 1, pages) >= (from or 0.8) then return pos end
  end
  return nil
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
-- @tparam[opt] integer pages the document's pages
-- @tparam[opt] number from the setting id_refs_from
function M.in_text(text, top, pages, from)
  local stop_at = M.references(text, pages, from) or math.huge
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

--- Reads arXiv's margin stamp, "arXiv:1012.6008v1 [math.CO] 29 Dec 2010":
-- the number and the class, or nil.
function M.arxiv_stamp(text)
  local id, class = text:match("arXiv:%s*(%S-)%s*%[([%w%.%-]+)%]")
  if not id then return nil end
  return (id:gsub("v%d+$", "")), class
end

--- The year an arXiv number was given: 1012.6008 gives 2010, math/0601054
-- gives 2006.
function M.arxiv_year(id)
  local yy = id:match("^(%d%d)%d%d%.") or id:match("/(%d%d)%d%d%d%d%d$")
  if not yy then return nil end
  yy = tonumber(yy)
  return yy >= 91 and 1900 + yy or 2000 + yy
end

--- The two-digit MSC area of a "Mathematics Subject Classification" footnote.
function M.msc(text)
  local i = text:find("[Ss]ubject%s+[Cc]lassif") or text:find("MSC%s*%d*%s*[:%(]")
  if not i then return nil end
  return text:sub(i, i + 160):match("(%d%d)%u%d%d")
end

--- A file named only by an arXiv number: that number, or nil.
function M.in_name(path)
  local stem = (path or ""):gsub("^.*/", ""):gsub("%.%w+$", "")
  local id = stem:match("^(%d%d%d%d%.%d%d%d%d%d?)v?%d*$")
  return id and { kind = "arxiv", value = id, own = true } or nil
end

--- What finds a file's identifiers, in order: `{ name=, version=, key=,
-- find = function(file, text, o) }`, each kept apart, so that one added or changed
-- runs alone. find returns `{ {kind=, value=, own=, start=, stop=}, ... }`; text is
-- the file's lulib._kept.reader, o the settings `{ top=, from= }`; key(o), what its
-- answer depends on besides the file.
--     table.insert(require("lulib._ids").finders, { name = "mine", find = function(file, text) ... end })
M.finders = {
  { name = "metadata", version = 1,
    find = function(file) return M.in_metadata(txt.metadata(file.id)) end },
  { name = "name", version = 1,
    find = function(file) return { M.in_name(file.path) } end },
  { name = "text", version = 2,
    key = function(o) return o.top .. ":" .. o.from end,
    find = function(file, text, o)
      local t = text.get()
      return t and M.in_text(t.text, o.top, file.pages, o.from) or {}
    end },
}

--- A file's identifiers, by the finders, none twice; a finder runs only if it
-- hasn't on this file as it is.
-- @tparam table file a row of bookman.files
-- @param k the file's lulib._kept
-- @param text its lulib._kept.reader
-- @tparam integer top the setting id_top
-- @treturn {table,...} `{ kind=, value=, own=, start=, stop= }`
function M.of(file, k, text, top)
  local o = { top = top, from = setman.get("id_refs_from") }
  local list, seen = {}, {}
  for _, finder in ipairs(M.finders) do
    local key = ("%s:%s:%s"):format(finder.name, tostring(finder.version or ""), finder.key and finder.key(o) or "")
    local found = k:get("ids", key)
    if not found then
      found = finder.find(file, text, o) or {}
      k:put("ids", key, found)
    end
    for _, f in ipairs(found) do
      local id = f.kind .. ":" .. f.value
      if seen[id] then
        seen[id].own = seen[id].own or f.own
      else
        seen[id] = f
        list[#list + 1] = f
      end
    end
  end
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
