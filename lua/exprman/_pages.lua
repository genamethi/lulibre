--- The packaged grammar "pages": a file's first pages read as a person reads
-- them. A cover sheet that labels its fields, a thesis cover's template, the
-- cataloguing block and copyright line of a book's verso, a series named on
-- its page, a journal's heading, and the title page by its lines' roles: the
-- largest for the title, the names under it for the authors. Each value says which
-- reading it came from and how sure that reading is, and those are what it's scored
-- and shown by (lulib._layouts, lulib._titlepage, lulib._names, lulib._junk).
--
-- @library exprman._pages
local expr = require "expr"
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
-- @treturn table the fields: `{ value=, how=, sure=, also = { ... } }`, by name
function M.read(t, book)
  local pages, texts = pages_of(t)
  local readings = {}
  -- words the pages have in lower case: a person's name is not made only of those
  local lower
  local function all_words_lower(name)
    if not lower then
      lower = {}
      for w in t.text:gmatch("%f[%a]%l+%f[%A]") do lower[w] = true end
    end
    local any = false
    for w in name:gmatch("[%a\128-\255]+") do
      if #w > 2 then
        any = true
        if not lower[expr.lower(w)] then return false end
      end
    end
    return any
  end
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
  local function add(field, value, how, sure)
    if value == nil or value == "" then return end
    value = tostring(value)
    if field == "title" then value = titlecase.proposed(value) end
    if field == "authors" then
      local people, twice = {}, true
      for name in (value .. " & "):gmatch("(.-) & ") do
        local person = names.is_person(name, t.text)
        -- a heading set like a name ("Velocity Versus Speed")
        if not names.never(name) and (person or not all_words_lower(name)) then
          people[#people + 1] = name
          if times(name) < 2 or not person then twice = false end
        end
      end
      value = table.concat(people, " & ")
      if value == "" then return end
      if twice then
        sure = sure + 0.1
        how = how .. ", named twice"
      end
    end
    readings[field] = readings[field] or {}
    table.insert(readings[field], { value = value, how = how, sure = math.min(1, sure) })
  end
  local function people(list)
    local out = {}
    for i, a in ipairs(list or {}) do out[i] = names.titlecase(a) end
    return table.concat(out, " & ")
  end

  -- the first pages only: further on, a name stands in a list of references
  local front = { table.unpack(texts, 1, M.leading) }
  for _, c in ipairs(layouts.read { id = book, texts = front }) do add(c.field, c.value, c.source, c.confidence or 0.8) end

  local lab = titlepage.labelled(pages[1])
  if lab then
    local certain, less = 0.85, 0.8
    if lab.labels >= 2 then certain, less = 0.95, 0.9 end
    add("authors", people(lab.authors), "cover sheet", certain)
    if lab.title and not junk.title(lab.title) then add("title", lab.title, "cover sheet", certain) end
    add("pubdate", lab.year, "cover sheet", less)
    add("publisher", lab.journal and layouts.with_journal(lab.publisher, lab.journal) or lab.publisher, "cover sheet", less)
  end

  local th = titlepage.thesis(pages[1])
  if th then
    add("authors", people(th.authors), "thesis cover", 0.85)
    if th.title and not junk.title(th.title) then add("title", names.title_caps(th.title), "thesis cover", 0.8) end
    add("pubdate", th.year, "thesis cover", 0.8)
    add("publisher", th.institution, "thesis cover", 0.75)
  end

  local tp = titlepage.classify_pages(pages)
  local conf = tp.arxiv and 0.9 or 0.75
  if tp.title and not junk.title(tp.title) then
    local title = tp.title_math and notation.title(tp.title_math, names.title_caps) or names.title_caps(tp.title)
    add("title", title, "title page", tp.arxiv and conf or tp.name_first and 0.75 or 0.7)
  end
  if #tp.authors > 0 then
    if tp.byline then add("authors", people(tp.authors), "by-line", math.max(conf, 0.9))
    elseif tp.name_first then add("authors", people(tp.authors), "first line", math.max(conf, 0.8))
    else add("authors", people(tp.authors), "title page", conf) end
  end
  add("tags", tp.subject, tp.subject_source or "title page", 0.9)
  add("series", tp.series, "title page", 0.8)
  add("series_index", tp.series and tp.series_index, "title page", 0.8)
  local year = tp.arxiv and ids.arxiv_year(tp.arxiv)
  add("pubdate", year and tostring(year), "arXiv number", 0.75)

  for _, text in ipairs(front) do
    local holder, known = layouts.copyright_holder(text)
    if holder and known then
      add("publisher", holder, "copyright line", 0.7)
      break
    end
  end

  -- per field, the surest reading, and the others that say something else
  local out = {}
  for field, list in pairs(readings) do
    table.sort(list, function(a, z) return a.sure > z.sure end)
    local first, seen = list[1], { [list[1].value] = true }
    for i = 2, #list do
      if not seen[list[i].value] then
        seen[list[i].value] = true
        first.also = first.also or {}
        table.insert(first.also, list[i])
      end
    end
    out[field] = first
  end
  return out
end

exprman.add("pages", M.read, nil, 2)

return M
