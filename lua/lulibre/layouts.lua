-- Layouts: kinds of page that say their facts in known places.
--
-- A book's cataloguing block, a publisher's series page, the stamp arXiv
-- prints down a margin: where one of these is recognised, what it says can
-- be read by rule and with more confidence than a title page read by the
-- size of its type. A layout is a description of such a page:
--
--   local layouts = require "lulibre.layouts"
--   layouts.add {
--     name = "ams-memoirs",                          -- shown as where a value came from
--     marks = { "memoirs of the", "american mathematical society" },
--     fields = {
--       series = "Memoirs of the American Mathematical Society",      -- a value as it stands
--       series_index = "Number%s+(%d+)",                              -- a pattern with a capture
--       pubdate = "(%d%d%d%d)%s*%S*%s*Volume",
--       publisher = function(text, doc) return "AMS" end,             -- or a function
--     },
--     confidence = 0.85,
--   }
--
-- marks: Lua patterns, matched without regard to case, that must all stand
-- on one of the file's first pages for the layout to apply; that page's text
-- is what the fields are read from. (Or `find = function(doc)`, returning
-- the text to read, for a test that patterns cannot make.)
-- fields: for each field (title authors tags series series_index publisher
-- pubdate identifiers), a constant, a pattern whose first capture is the
-- value, or a function(text, doc) returning it. A layout may instead give
-- `read = function(text, doc)` returning a table of fields.
-- confidence: how far its word is taken (default 0.8).
--
-- Put your own in ~/.config/lulibre/init.lua or a module it requires. :run
-- candidates shows what every layout reads from the book under the cursor.
local ids = require "lulibre.ids"
local names = require "lulibre.names"
local taxonomy = require "lulibre.taxonomy"

local M = {}

M.list = {}

--- Add a layout, or replace the one of the same name.
function M.add(layout)
  assert(type(layout) == "table" and type(layout.name) == "string", "a layout is a table with a name")
  assert(layout.marks or layout.find, "a layout needs marks or find to say which pages it is for")
  assert(layout.fields or layout.read, "a layout needs fields or read to say what to take from them")
  for i, l in ipairs(M.list) do
    if l.name == layout.name then
      M.list[i] = layout
      return layout
    end
  end
  M.list[#M.list + 1] = layout
  return layout
end

--- Take a layout out.
function M.remove(name)
  for i, l in ipairs(M.list) do
    if l.name == name then return table.remove(M.list, i) end
  end
end

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- the page of doc.texts (the leading pages' text, one string each) that a layout is for
local function find(layout, doc)
  if layout.find then return layout.find(doc) end
  for _, text in ipairs(doc.texts or {}) do
    local low, all = text:lower(), true
    for _, mark in ipairs(layout.marks) do
      if not low:find(mark:lower()) then
        all = false
        break
      end
    end
    if all then return text end
  end
  return nil
end

--- What the layouts read from a document: { {field=, value=, source=, confidence=}, ... }.
-- doc.texts: the text of each leading page.
function M.read(doc)
  local out = {}
  for _, layout in ipairs(M.list) do
    local ok, text = pcall(find, layout, doc)
    if ok and text then
      local fields = {}
      if layout.read then
        local good, got = pcall(layout.read, text, doc)
        if good and type(got) == "table" then fields = got end
      else
        for field, how in pairs(layout.fields) do
          local value
          if type(how) == "function" then
            local good, got = pcall(how, text, doc)
            value = good and got or nil
          elseif type(how) == "string" and how:find("%b()") then
            value = text:match(how)
          else
            value = how
          end
          fields[field] = value
        end
      end
      for field, value in pairs(fields) do
        if type(value) == "table" then value = table.concat(value, field == "authors" and " & " or ", ") end
        value = value ~= nil and trim(tostring(value)):gsub("%s+", " ") or ""
        if value ~= "" then
          out[#out + 1] = { field = field, value = value, source = layout.name, confidence = layout.confidence or 0.8 }
        end
      end
    end
  end
  return out
end

-- ---- the layouts that come with lulibre ----

-- "Lang, Serge" or "Lyndon, Roger C., 1917-" the right way round
local function person(entry)
  entry = entry:gsub("%s*%d%d%d%d%s*%-%s*%d*%s*%.?$", ""):gsub("[,.]%s*$", "")
  local family, given = entry:match("^([^,]+),%s*(.+)$")
  if not family then return nil end
  given = given:gsub(",.*$", "")
  local name = trim(given) .. " " .. trim(family)
  return names.clean(name) and name or nil
end

-- series that are known by one spelling
local KNOWN_SERIES = { "Graduate Texts in Mathematics", "Undergraduate Texts in Mathematics", "Lecture Notes in Mathematics",
  "Lecture Notes in Computer Science", "Lecture Notes in Physics", "Universitext", "Springer Monographs in Mathematics",
  "Grundlehren der mathematischen Wissenschaften", "Ergebnisse der Mathematik und ihrer Grenzgebiete",
  "Springer Undergraduate Mathematics Series", "Progress in Mathematics", "Applied Mathematical Sciences",
  "Texts in Applied Mathematics", "Graduate Texts in Physics", "Springer Series in Statistics",
  "Cambridge Studies in Advanced Mathematics", "London Mathematical Society Lecture Note Series",
  "Graduate Studies in Mathematics", "Mathematical Surveys and Monographs", "Annals of Mathematics Studies",
  "Pure and Applied Mathematics", "Mathematical Sciences Research Institute Publications" }

--- A series' name as the series writes it: a known one by its usual
-- spelling, any other in title case.
function M.series_name(s)
  local low = s:lower()
  for _, known in ipairs(KNOWN_SERIES) do
    if known:lower() == low then return known end
  end
  return require("lulibre.titlecase").apply(s)
end

--- The cataloguing block the Library of Congress (or the British or German
-- national library) supplies for the back of a title page:
--
--   Library of Congress Cataloging in Publication Data
--   Lang, Serge                               the main entry: who it is filed under
--   SL2(R).                                   the title [ / who wrote it ]
--   (Graduate texts in mathematics; 105)      the series and the number in it
--   1. Lie groups. 2. Representations of groups. I. Title. II. Series.
--   QA387.L35 1985                            the class it is shelved in, and the year
--   512'.55                                   its Dewey number
--
-- Returns a table of fields; what cannot be made out is left out.
function M.cip(text)
  local at = text:lower():find("cataloging%s*%-?%s*in%s*%-?%s*publication")
  if not at then return {} end
  local lines = {}
  for raw in text:sub(at):gmatch("[^\n]+") do -- (a loop variable cannot be assigned to in Lua 5.5)
    local line = trim(raw)
    if line ~= "" then lines[#lines + 1] = line end
    if #lines >= 22 then break end
  end
  local out, i = {}, 2
  -- the main entry, when the book is filed under a person
  local who = lines[i] and person(lines[i])
  if who then
    out.authors = who
    i = i + 1
  elseif lines[i] and lines[i]:find("^[^,]+,[^,]+,%s*%d%d%d%d%s*%-") then
    i = i + 1 -- a main entry with its dates that did not read as a name (a poor scan): not the title, at least
  end
  -- the title: up to the statement of responsibility, the full stop that ends
  -- it, or the line that begins the description
  local parts = {}
  while lines[i] and #parts < 3 do
    local line = lines[i]
    if line:find("^%(") or line:find("^p%. ?cm") or line:lower():find("^includes ") or line:lower():find("^bibliography")
      or line:find("^%d+%. ") or line:find("^ISBN") then
      break
    end
    local head, rest = line:match("^(.-)%s*/%s*(.*)$")
    parts[#parts + 1] = head or line
    i = i + 1
    if head then
      if not out.authors then
        local by = rest:gsub("%.$", ""):gsub(",?%s*editors?$", ""):gsub("^by%s+", ""):gsub("^edited by%s+", "")
        local people = names.validate { by }
        if #people > 0 then out.authors = table.concat(people, " & ") end
      end
      break
    end
    if line:find("%.$") then break end
  end
  local title = table.concat(parts, " "):gsub("%s+", " "):gsub("%s*[.:]$", ""):gsub("%s+:%s+", ": ")
  if #title >= 3 and title:find("%a") then out.title = title end
  local rest = table.concat(lines, "\n", math.min(i, #lines))
  -- "(Graduate texts in mathematics; 105)" or "(... ; v. 27)"
  local series, number = rest:match("%(([%a][^();]-)%s*;%s*[vVnNoO. ]*(%d+)%s*%)")
  if not series then series = rest:match("%(([%a][^();]-)%)") end
  if series and #series > 6 and not series:lower():find("ebook") and not series:lower():find("alk%. paper") then
    -- the block writes a series in sentence case; give it as the series writes itself
    out.series = M.series_name(series:gsub("%s+", " "))
    out.series_index = number
  end
  -- the class it is shelved in carries the subject; the year follows it
  for line in rest:gmatch("[^\n]+") do
    local class = line:match("^(%u%u?%d+%.?%d*%s*%.?%u?[%w.]*)")
    if class and not out.tags then
      out.tags = taxonomy.from_lcc(class)
      out.pubdate = out.pubdate or line:match("%f[%d]([12]%d%d%d)%f[%D]")
    end
    local dewey = line:match("^(%d%d%d['./]?%.?['/]?%d*)%s*%-*%s*d?c?%d*$")
    if dewey and not out.tags then out.tags = taxonomy.from_dewey(dewey) end
  end
  local isbn = ids.isbn(text)
  if isbn then out.identifiers = "isbn:" .. isbn end
  return out
end

M.add {
  name = "cataloguing data",
  marks = { "cataloging%s*%-?%s*in%s*%-?%s*publication" },
  read = M.cip,
  confidence = 0.9,
}

-- A Springer book's series page: the series' name with the volume's number
-- under or after it, and the year in the copyright line.
local SPRINGER_SERIES = { "Graduate Texts in Mathematics", "Undergraduate Texts in Mathematics", "Lecture Notes in Mathematics",
  "Lecture Notes in Computer Science", "Lecture Notes in Physics", "Universitext", "Springer Monographs in Mathematics",
  "Grundlehren der mathematischen Wissenschaften", "Ergebnisse der Mathematik und ihrer Grenzgebiete",
  "Springer Undergraduate Mathematics Series", "Progress in Mathematics", "Applied Mathematical Sciences",
  "Texts in Applied Mathematics", "Graduate Texts in Physics", "Springer Series in Statistics" }

M.add {
  name = "Springer series page",
  find = function(doc)
    for _, text in ipairs(doc.texts or {}) do
      local low = text:lower()
      if low:find("springer") or low:find("birkh") then
        for _, s in ipairs(SPRINGER_SERIES) do
          if low:find(s:lower(), 1, true) then return text end
        end
      end
    end
  end,
  read = function(text)
    local out, low = { publisher = "Springer" }, text:lower()
    -- the series the page is headed with: the one named first on it (others
    -- may be advertised further down)
    local first
    for _, s in ipairs(SPRINGER_SERIES) do
      local a, b = low:find(s:lower(), 1, true)
      if a and (not first or a < first) then
        first = a
        out.series = s
        out.series_index = text:sub(b + 1, b + 40):match("^[%s,]*[Vv]?o?l?u?m?e?%.?%s*(%d+)%f[%D]")
      end
    end
    out.pubdate = text:match("©%s*(%d%d%d%d)") or text:match("[Cc]opyright%s*%(?[cC]?%)?%s*(%d%d%d%d)")
    return out
  end,
  confidence = 0.85,
}

-- The stamp arXiv prints down the left margin of a paper's first page gives
-- the day it was submitted: "arXiv:1012.6008v1 [math.CO] 29 Dec 2010".
local MONTH = { jan = 1, feb = 2, mar = 3, apr = 4, may = 5, jun = 6, jul = 7, aug = 8, sep = 9, oct = 10, nov = 11, dec = 12 }
M.add {
  name = "arXiv stamp",
  marks = { "arxiv:%d%d%d%d%.%d+" },
  read = function(text)
    local day, month, year = text:match("arXiv:%d%d%d%d%.%d+v?%d*%s*%[[%a.%-]+%]%s*(%d%d?)%s+(%a%a%a)%a*%s+(%d%d%d%d)")
    local m = month and MONTH[month:lower()]
    if not m then return {} end
    return { pubdate = ("%s-%02d-%02d"):format(year, m, tonumber(day)) }
  end,
  confidence = 0.95,
}

return M
