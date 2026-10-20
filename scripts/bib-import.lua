-- Use a .bib file (from Zotero, JabRef, a paper's bibliography, or written by
-- a build next to its own output) to fill in metadata. Each entry is matched
-- to a book by the file it names (same bytes, by MD5), else by DOI, ISBN,
-- arXiv id or title, and what it says becomes proposals for :review.
--   :run bib-import ~/library.bib
--   lulibre run bib-import library.bib
--   lulibre run bib-import library.bib --dry     only say what would match
local bib = require "lulibre.bib"
local dupes = require "lulibre.dupes"
local proposals = require "lulibre.proposals"

local path, dry
for _, a in ipairs({ ... }) do
  if a == "--dry" then dry = true else path = a end
end
if not path then error("give the .bib file to read", 0) end
path = path:gsub("^~", os.getenv("HOME") or "~")
local f = assert(io.open(path))
local entries = bib.parse(f:read("a"))
f:close()
local dir = path:match("^(.*)/[^/]*$") or "."

local function norm(s)
  return (lulibre.fold(s or ""):gsub("[^%w]+", " "):gsub("^ +", ""):gsub(" +$", ""))
end

-- index the library once by identifier and by normalised title
local by_ident, by_title = {}, {}
for _, row in ipairs(lulibre.sql("SELECT book, type, val FROM idents WHERE book > 0")) do
  by_ident[row.type .. ":" .. row.val:lower()] = row.book
end
for _, row in ipairs(lulibre.sql("SELECT id, title FROM books WHERE id > 0")) do
  local k = norm(row.title)
  if #k >= 12 then by_title[k] = by_title[k] == nil and row.id or false end -- false: ambiguous
end

-- which books hold the files the entries name; hashing runs in parallel
local uv = require "luv"
local holders, names_file = {}, {}
lulibre.each(entries, function(e)
  for _, file in ipairs(bib.files(e, dir)) do
    if uv.fs_stat(file) then names_file[e] = file end
    local ids = dupes.holders(file)
    if #ids > 0 then holders[e] = ids end
  end
end)

local matched, added, by_how, absent = 0, 0, {}, {}
for _, e in ipairs(entries) do
  local m = bib.metadata(e)
  local ids, how, conf = holders[e], "bib: same file", 1.0
  if not ids and names_file[e] then
    -- The entry is about a file that is right here and that no book holds.
    -- A book that merely shares its title is some other book.
    absent[#absent + 1] = names_file[e]
  elseif not ids then
    local id
    for _, ident in ipairs(m.identifiers) do
      if not ident:find("^url:") then id = id or by_ident[ident:lower()] end
    end
    how, conf = "bib: identifier", 0.95
    if not id and m.title then
      id = by_title[norm(m.title)] or nil
      how, conf = "bib: same title", 0.8
    end
    ids = id and { id } or nil
  end
  for _, id in ipairs(ids or {}) do
    matched = matched + 1
    by_how[how] = (by_how[how] or 0) + 1
    local function propose(field, value, op)
      if not value or value == "" then return end
      if dry then
        local book = lulibre.book(id)
        local edit = require "lulibre.edit"
        if book and edit.resolve(book, field, op or "set", value) ~= edit.current(book, field) then added = added + 1 end
      elseif proposals.add(id, field, value, { op = op, source = how, confidence = conf }) then
        added = added + 1
      end
    end
    propose("title", m.title)
    propose("authors", m.authors)
    propose("pubdate", m.pubdate)
    propose("publisher", m.publisher)
    propose("series", m.series)
    propose("series_index", m.series_index)
    propose("tags", m.tags, "add")
    for _, ident in ipairs(m.identifiers) do propose("identifiers", ident, "add") end
  end
end
local hows = {}
for how, n in pairs(by_how) do hows[#hows + 1] = ("%d by %s"):format(n, (how:gsub("^bib: ", ""))) end
table.sort(hows)
print(("%d entries, %d matched to books%s, %s %d proposals%s"):format(#entries, matched,
  #hows > 0 and " (" .. table.concat(hows, ", ") .. ")" or "", dry and "would make" or "made", added,
  dry and "" or ("." .. require("lulibre.proposals").to_review(" "))))
if #absent > 0 then
  print(("%d entries name files that are not in the library%s"):format(#absent,
    #absent <= 8 and (": " .. table.concat(absent, ", "):gsub("[^, ]*/", "")) or "; :run onboard adds such files"))
end
