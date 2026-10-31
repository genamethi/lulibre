--- The packaged grammar "pages": a file's first pages read as a person reads
-- them. A cover sheet that labels its fields, a thesis cover's template, the
-- cataloguing block and copyright line of a book's verso, a series named on
-- its page, a journal's heading, and the title page by its lines' roles: the
-- largest for the title, the names under it for the authors. What each says
-- goes by how sure of it the reading is; for each field, the surest reading's
-- value is the parse's (lulib._layouts, lulib._titlepage, lulib._names,
-- lulib._junk).
--
-- @library exprman._pages
local exprman = require "exprman"
local ids = require "lulib._ids"
local junk = require "lulib._junk"
local layouts = require "lulib._layouts"
local names = require "lulib._names"
local notation = require "lulib._notation"
local titlecase = require "lulib._titlecase"
local titlepage = require "lulib._titlepage"

local M = {}

--- How many of the first pages are read by their lines.
M.leading = 4

-- the text as lines per page, and as text per page
local function pages_of(t)
  local pages = {}
  for i = 1, #t do
    local l = t:line(i)
    if l.page > M.leading then break end
    pages[l.page] = pages[l.page] or {}
    table.insert(pages[l.page], l)
  end
  for n = 1, M.leading do
    if not pages[n] then pages[n] = {} end
  end
  local texts = {}
  for page in (t.text .. "\f"):gmatch("(.-)\f") do texts[#texts + 1] = page end
  return pages, texts
end

--- Reads a text's first pages.
-- @param t a text (txt)
-- @tparam[opt] integer book
-- @treturn table the fields, by name
function M.read(t, book)
  local pages, texts = pages_of(t)
  local best, sure = {}, {}
  local function times(name)
    local n, from = 0, 1
    local low = t.text:lower()
    local needle = name:lower()
    while true do
      local _, b = low:find(needle, from, true)
      if not b then return n end
      n, from = n + 1, b + 1
    end
  end
  local function add(field, value, confidence)
    if value == nil or value == "" then return end
    if field == "title" then value = titlecase.proposed(value) end
    if field == "authors" then
      local people, twice = {}, true
      for name in (value .. " & "):gmatch("(.-) & ") do
        if not names.never(name) then
          people[#people + 1] = name
          if times(name) < 2 or not names.is_person(name, t.text) then twice = false end
        end
      end
      value = table.concat(people, " & ")
      if value == "" then return end
      if twice then confidence = confidence + 0.1 end
    end
    if not best[field] or confidence > sure[field] then best[field], sure[field] = value, confidence end
  end
  local function people(list)
    local out = {}
    for i, a in ipairs(list or {}) do out[i] = names.titlecase(a) end
    return table.concat(out, " & ")
  end

  -- the first pages only: further on, a name stands in a list of references
  local front = { table.unpack(texts, 1, M.leading) }
  for _, c in ipairs(layouts.read { id = book, texts = front }) do add(c.field, c.value, c.confidence or 0.8) end

  local lab = titlepage.labelled(pages[1])
  if lab then
    local certain, less = 0.85, 0.8
    if lab.labels >= 2 then certain, less = 0.95, 0.9 end
    add("authors", people(lab.authors), certain)
    if lab.title and not junk.title(lab.title) then add("title", lab.title, certain) end
    add("pubdate", lab.year, less)
    add("publisher", lab.journal and layouts.with_journal(lab.publisher, lab.journal) or lab.publisher, less)
  end

  local th = titlepage.thesis(pages[1])
  if th then
    add("authors", people(th.authors), 0.85)
    if th.title and not junk.title(th.title) then add("title", names.title_caps(th.title), 0.8) end
    add("pubdate", th.year, 0.8)
    add("publisher", th.institution, 0.75)
  end

  local tp = titlepage.classify_pages(pages)
  local conf = tp.arxiv and 0.9 or 0.75
  if tp.title and not junk.title(tp.title) then
    local title = tp.title_math and notation.title(tp.title_math, names.title_caps) or names.title_caps(tp.title)
    add("title", title, tp.arxiv and conf or tp.name_first and 0.75 or 0.7)
  end
  if #tp.authors > 0 then
    add("authors", people(tp.authors), tp.byline and math.max(conf, 0.9) or tp.name_first and math.max(conf, 0.8) or conf)
  end
  add("tags", tp.subject, 0.9)
  add("series", tp.series, 0.8)
  add("series_index", tp.series and tp.series_index, 0.8)
  local year = tp.arxiv and ids.arxiv_year(tp.arxiv)
  add("pubdate", year and tostring(year), 0.75)

  -- the copyright line, on any page, when nothing surer gave a publisher
  for _, text in ipairs(front) do
    local holder, known = layouts.copyright_holder(text)
    if holder and known then
      add("publisher", holder, 0.7)
      break
    end
  end
  return best
end

exprman.add("pages", M.read)

return M
