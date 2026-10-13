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
      -- a layout that is surer of one field than of another says so: confidence = { field = n }
      local sure = type(fields.confidence) == "table" and fields.confidence or {}
      fields.confidence = nil
      for field, value in pairs(fields) do
        if type(value) == "table" then value = table.concat(value, field == "authors" and " & " or ", ") end
        value = value ~= nil and trim(tostring(value)):gsub("%s+", " ") or ""
        if value ~= "" then
          out[#out + 1] = { field = field, value = value, source = layout.name, confidence = sure[field] or layout.confidence or 0.8 }
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

-- Series known by one spelling, and who publishes each (nil where more than
-- one house has a series of the name).
local AMS, CUP, PUP = "American Mathematical Society", "Cambridge University Press", "Princeton University Press"
M.series = {
  { "Graduate Texts in Mathematics", "Springer" }, { "Undergraduate Texts in Mathematics", "Springer" },
  { "Lecture Notes in Mathematics", "Springer" }, { "Lecture Notes in Computer Science", "Springer" },
  { "Lecture Notes in Physics", "Springer" }, { "Universitext", "Springer" },
  { "Springer Monographs in Mathematics", "Springer" }, { "Grundlehren der mathematischen Wissenschaften", "Springer" },
  { "Ergebnisse der Mathematik und ihrer Grenzgebiete", "Springer" },
  { "Springer Undergraduate Mathematics Series", "Springer" }, { "Applied Mathematical Sciences", "Springer" },
  { "Texts in Applied Mathematics", "Springer" }, { "Graduate Texts in Physics", "Springer" },
  { "Springer Series in Statistics", "Springer" }, { "Progress in Mathematics", "Birkhäuser" },
  { "Graduate Studies in Mathematics", AMS }, { "Mathematical Surveys and Monographs", AMS },
  { "Memoirs of the American Mathematical Society", AMS }, { "Contemporary Mathematics", AMS },
  { "Student Mathematical Library", AMS }, { "University Lecture Series", AMS },
  { "Proceedings of Symposia in Pure Mathematics", AMS }, { "Translations of Mathematical Monographs", AMS },
  { "Cambridge Studies in Advanced Mathematics", CUP }, { "London Mathematical Society Lecture Note Series", CUP },
  { "London Mathematical Society Student Texts", CUP }, { "Cambridge Tracts in Mathematics", CUP },
  { "Annals of Mathematics Studies", PUP }, { "Princeton Mathematical Series", PUP },
  { "Oxford Graduate Texts in Mathematics", "Oxford University Press" },
  { "North-Holland Mathematical Library", "North-Holland" }, { "Pure and Applied Mathematics" },
  { "Mathematical Sciences Research Institute Publications" },
}

--- A series' name as the series writes it: a known one by its usual
-- spelling, any other in title case.
function M.series_name(s)
  local low = s:lower()
  for _, known in ipairs(M.series) do
    if known[1]:lower() == low then return known[1] end
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

-- A book's series page or title-page verso: the series' name with the
-- volume's number after it, and the year in the copyright line. Any series
-- in M.series is known (add to it for more: { name, publisher }).
M.add {
  name = "series page",
  find = function(doc)
    for _, text in ipairs(doc.texts or {}) do
      local low = text:lower()
      for _, s in ipairs(M.series) do
        if low:find(s[1]:lower(), 1, true) then return text end
      end
    end
  end,
  read = function(text)
    local out, low = {}, text:lower()
    -- the series the page is headed with: the one named first on it (others
    -- may be advertised further down)
    local first
    for _, s in ipairs(M.series) do
      local a, b = low:find(s[1]:lower(), 1, true)
      if a and (not first or a < first) then
        first = a
        out.series, out.publisher = s[1], s[2]
        local after = text:sub(b + 1, b + 48)
        out.series_index = after:match("^[%s,;:]*[Vv]ol%a*%.?%s*(%d+)%f[%D]") or after:match("^[%s,;:]*[Nn]umber%s*(%d+)%f[%D]")
          or after:match("^[%s,;:]*[Nn]o%.%s*(%d+)%f[%D]") or after:match("^[%s,;:]*(%d+)%f[%D]")
      end
    end
    -- the year of the edition in hand: a reprint names the edition it reprints
    out.pubdate = text:match("[Rr]eprint of the %a+ %d*%a* ?edition (%d%d%d%d)") or text:match("©%s*(%d%d%d%d)")
      or text:match("[Cc]opyright%s*%(?[cC]?%)?%s*(%d%d%d%d)")
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

-- ---- a series named in so many words ----
--
-- A book usually says which series it belongs to: a line that is the
-- series' name ("Springer Undergraduate Mathematics Series", "IAS/Park City
-- Mathematics Series, Volume 12"), a label ("Series: Lecture Notes in
-- Physics"), or the line above "Series Editors". The word alone proves
-- nothing ("Fourier Series", "a series of lectures given at ..."), so a line
-- is taken for a series' name only when it is set like a name, is not a
-- piece of mathematics (M.not_series), and something beside it bears it
-- out: a volume number, the editors, an ISSN, or a publishing house's name.

local function words(list)
  local out = {}
  for w in list:gmatch("%S+") do out[w] = true end
  return out
end

-- what stands before "Series" when the series is a sum, not a set of books
M.not_series = words [[fourier power dirichlet taylor laurent maclaurin random time eisenstein poincaré poincare hilbert
  puiseux formal infinite trigonometric divergent convergent composition central derived hypergeometric asymptotic theta
  farey singular geometric harmonic complementary discrete principal volterra neumann binomial orthogonal double multiple
  lambert fibonacci numerical alternating telescoping generating zeta chief normal subnormal upper lower new second third
  first fourth this the a each in of and]]

-- houses and societies whose name opens the name of a series
M.series_houses = words [[springer cambridge oxford princeton wiley mit chapman academic elsevier north-holland birkhäuser
  birkhauser ams ias london gruyter world dover pearson mcgraw-hill addison-wesley prentice crc siam ems clay fields cbms nato
  schaum's schaum university chicago harvard yale stanford american european society international carus pitman van
  wadsworth brooks/cole benjamin interscience kluwer reidel plenum teubner vieweg hermann masson dunod]]

local MINOR = words "in of the and on for to a an und der die das de des du et la le von zur für per il e y & - – /"

local function minor(word)
  return MINOR[lulibre.lower((word or ""):gsub("^%p+", ""):gsub("[%p]+$", ""))] ~= nil
end

-- is the line set like a name: its words capitalised, but for the small ones
local function titled(line)
  local n = 0
  for w in line:gmatch("%S+") do
    n = n + 1
    local bare = w:gsub("^[%p]+", ""):gsub("[%p]+$", "")
    if bare ~= "" and not MINOR[lulibre.lower(bare)] and not bare:match("^[%u%d\128-\255]") then return false end
  end
  return n >= 2 and n <= 14
end

-- "Name, Volume 12" -> "Name", "12"
local function with_number(line)
  line = line:gsub("%s*ISSN%s*:?%s*[%dXx%-]+", ""):gsub("[%s|,;:]+$", "")
  for _, pattern in ipairs { "^(.-)[,;:]?%s*[Vv][Oo][Ll]%a*%.?%s*(%d+)$", "^(.-)[,;:]?%s*[Nn]o%.?%s*(%d+)$", "^(.-)[,;:]?%s*[Nn]umber%s*(%d+)$",
    "^(.-)%s*#%s*(%d+)$", "^(.-)[,;]?%s+(%d+)$" } do
    local name, number = line:match(pattern)
    if name and #name >= 6 and tonumber(number) < 3000 then return name:gsub("[|,;:%s]+$", ""), number end
  end
  return line, nil
end

-- a line of a table of contents, a cataloguing entry, a sentence, a credit: not a name
local function not_a_name(line)
  return #line > 80 or line:find("^%d+[%.%d]*%s") or line:find("%.%s?%.%s?%.") or line:find("[Cc][Hh][Aa][Pp][Tt][Ee][Rr]") or line:find("Title%.")
    or line:find("[%.;:!?]$") or line:find("[Ee]ditor") or line:find("EDITOR") or line:find("%(New Series%)") or line:find("^Source")
    or line:find("published") or line:find("@") or line:find("http") or line:find("ISBN") or line:find("^A Series of")
    or line:find("[Ii]mage") or line:find("[Cc]over") or line:find("©") or line:find("[Pp]hoto") or line:find("[Dd]esign")
    or line:find("[Pp]ublication") or line:find("Commenced")
end

-- the heading of a list of a series' editors, or of its board
local function editors_heading(line)
  return #line <= 40 and not line:find(",") and (line:find("^[%a%-%s]*[Ee]ditors?[%a%-%s]*:?$") or line:find("^[%a%-%s]*EDITORS?[%a%-%s]*:?$")
    or line:find("^[%a%s]*Board:?$")) ~= nil
end

local function volume_line(line)
  return line:match("^[Vv][Oo][Ll]%a*%.?%s*(%d+)$") or line:match("^[Nn]umber%s*(%d+)$") or line:match("^[Nn]o%.%s*(%d+)$")
end

-- a name as it is proposed: one found in capitals in title case, without "Subseries of"
local function dressed(name)
  name = name:gsub("^[%p%s]+", ""):gsub("^Subseries of%s+", ""):gsub("[|,;:%s]+$", "")
  local lower, letters = 0, 0
  for w in name:gmatch("%S+") do
    if not minor(w) then
      for c in w:gmatch("%a") do
        letters = letters + 1
        if c:match("%l") then lower = lower + 1 end
      end
    end
  end
  if letters > 0 and lower == 0 then name = require("lulibre.titlecase").apply(lulibre.upper(name)) end
  return name
end

--- The series a page names, if it names one: its name, the volume's number
-- (or nil), and what bears it out.
function M.series_line(text)
  local lines = {}
  for raw in (text .. "\n"):gmatch("(.-)\n") do
    local line = trim(raw):gsub("%s+", " ")
    if line ~= "" then lines[#lines + 1] = line end
  end
  -- a number on the line below: "Volume 12"
  local function below(i)
    for k = i + 1, math.min(i + 2, #lines) do
      local n = volume_line(lines[k])
      if n then return n end
    end
  end
  local function near(i, pattern)
    for k = math.max(1, i - 3), math.min(#lines, i + 3) do
      if k ~= i and lines[k]:find(pattern) then return true end
    end
  end
  -- A name set over two lines: the second begins, or the first ends, with a
  -- small word or a hyphen ("Studies in Neuroscience, Psychology / and
  -- Behavioral Economics", "CAMBRIDGE TEXTS IN THE / HISTORY OF ..."). k: the
  -- line found; returns the whole name and the line it begins on.
  local function whole(k)
    local name, first = lines[k], k
    local prev = lines[k - 1]
    if prev and not not_a_name(prev) and not editors_heading(prev) and not volume_line(prev)
      and (minor(name:match("^%S+")) or minor(prev:match("%S+$")) or prev:find("%-$")) and titled(prev .. " X") then
      name, first = (prev:find("%a%-$") and prev:sub(1, -2) .. name or prev .. " " .. name), k - 1
    end
    local nxt = lines[k + 1]
    if nxt and not not_a_name(nxt) and not editors_heading(nxt) and not volume_line(nxt)
      and (minor(nxt:match("^%S+")) or minor(name:match("%S+$")) or name:find("%a%-$")) and titled("X " .. nxt) then
      name = name:find("%a%-$") and name:sub(1, -2) .. nxt or name .. " " .. nxt
    end
    return name, first
  end
  local has_series_editors = text:find("[Ss]eries%s+[Ee]ditors?") or text:find("SERIES%s+EDITORS?")
  for i, line in ipairs(lines) do
    -- a label says it outright
    local labelled = line:match("^Series%s*:%s*(.+)$") or line:match("^Series%s+[Tt]itle%s*:%s*(.+)$")
    if labelled and not labelled:find("[Ee]ditor") then
      local name, number = with_number(labelled)
      if titled(name) then return dressed(name), number or below(i), "labelled" end
    end
    -- The first heading of the series' editors: the name stands above it,
    -- with the volume's number perhaps between ("UNITEXT ... / Volume 109 /
    -- Editor-in-chief / ... / Series editors").
    if has_series_editors and editors_heading(line) then
      local k, number = i - 1, nil
      if lines[k] and volume_line(lines[k]) then number, k = volume_line(lines[k]), k - 1 end
      -- a line about the series may stand between: "Commenced Publication in 1973"
      if lines[k] and lines[k - 1] and (lines[k]:find("[Pp]ublication") or lines[k]:find("ISSN")) then k = k - 1 end
      if lines[k] and not not_a_name(lines[k]) and not editors_heading(lines[k]) then
        local full = whole(k)
        local name, n = with_number(full)
        local before = name:match("(%S+)%s+[Ss][Ee][Rr][Ii][Ee][Ss]%f[%A]")
        local sum = before and M.not_series[lulibre.lower(before:gsub("^%p+", ""):gsub("%p+$", ""))]
        if titled(name) and not sum and not names.is_person(name) and not name:find("^Series") then
          return dressed(name), number or n, "above the series' editors"
        end
      end
      has_series_editors = nil -- only the first heading on the page has the name above it
    end
    -- a line that is the name of one
    if (line:find("%f[%a]Series%f[%A]") or line:find("%f[%a]SERIES%f[%A]")) and not not_a_name(line) then
      local full, first = whole(i)
      local name, number = with_number(full)
      local before = lulibre.lower(name:match("(%S+)%s+[Ss][Ee][Rr][Ii][Ee][Ss]%f[%A]") or "the")
      local after = name:match("[Ss][Ee][Rr][Ii][Ee][Ss]%s+(%S+)")
      before = before:gsub("^%p+", ""):gsub("%p+$", "")
      if titled(name) and not M.not_series[before] and after ~= "of" and not name:find("^Series") then
        number = number or below(i)
        local house = M.series_houses[lulibre.lower(name:match("^[%a\128-\255/%-']+") or "")]
          or M.series_houses[lulibre.lower(name:match("^[Tt][Hh][Ee]%s+([%a\128-\255/%-']+)") or "")]
        local why = number and "with its volume" or (near(i, "[Ee]ditor") or near(first, "[Ee]ditor") or near(i, "EDITOR")) and "beside its editors"
          or near(i, "ISSN") and "beside its ISSN" or house and "a house's series"
        if why then return dressed(name), number, why end
      end
    end
  end
  return nil
end

M.add {
  name = "series line",
  find = function(doc)
    for i = 1, math.min(6, #(doc.texts or {})) do
      if M.series_line(doc.texts[i]) then return doc.texts[i] end
    end
  end,
  read = function(text)
    local name, number = M.series_line(text)
    return { series = name, series_index = number }
  end,
  confidence = 0.75,
}

-- ---- dates ----

local MONTHS = {
  january = 1, february = 2, march = 3, april = 4, may = 5, june = 6, july = 7, august = 8, september = 9, october = 10,
  november = 11, december = 12, jan = 1, feb = 2, mar = 3, apr = 4, jun = 6, jul = 7, aug = 8, sep = 9, sept = 9, oct = 10,
  nov = 11, dec = 12,
  janvier = 1, ["février"] = 2, fevrier = 2, mars = 3, avril = 4, mai = 5, juin = 6, juillet = 7, ["août"] = 8, aout = 8,
  septembre = 9, octobre = 10, novembre = 11, ["décembre"] = 12, decembre = 12,
  januar = 1, februar = 2, ["märz"] = 3, juni = 6, juli = 7, oktober = 10, dezember = 12,
}
local WORD = "[%a\128-\255]+"

local function ymd(year, month, day)
  year, month, day = tonumber(year), tonumber(month), tonumber(day)
  if not year or year < 1600 or year > tonumber(os.date("%Y")) + 1 then return nil end
  if not month or month < 1 or month > 12 then return nil end
  if day and (day < 1 or day > 31) then return nil end
  return ("%04d-%02d-%02d"):format(year, month, day or 1)
end

local function month_of(word)
  return MONTHS[lulibre.lower(word)]
end

--- The date a piece of text opens with, as YYYY-MM-DD, and where it ends:
-- "8 February 1972", "Feb. 8, 1972", "March 2004" (the first of the month),
-- "2004-03-12". nil when it does not open with one. Dates written in
-- figures alone (3/12/2004) are not read: which is the month?
function M.date(s)
  s = s:gsub("^%s+", "")
  local d, m, y, e = s:match("^(%d%d?)%.?%s+(" .. WORD .. ")%.?,?%s+(%d%d%d%d)()")
  if d and month_of(m) then return ymd(y, month_of(m), d), e end
  m, d, y, e = s:match("^(" .. WORD .. ")%.?%s+(%d%d?)%a?%a?,?%s+(%d%d%d%d)()")
  if m and month_of(m) then return ymd(y, month_of(m), d), e end
  m, y, e = s:match("^(" .. WORD .. ")%.?,?%s+(%d%d%d%d)()")
  if m and month_of(m) then return ymd(y, month_of(m)), e end
  y, m, d, e = s:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)()")
  if y then return ymd(y, m, d), e end
  return nil
end

-- An article says when the journal received it: "Received 8 February 1972",
-- "Received by the editors May 3, 1999", "Manuscript received March 2004",
-- "Reçu le 12 mars 1985", "Eingegangen am 3. Mai 1962". That is the day the
-- work was handed in, as the arXiv stamp is for a preprint.
local RECEIVED = { "[Rr]eceived", "RECEIVED", "[Ss]ubmitted", "Reçu", "Recu", "Eingegangen" }
local BETWEEN = { "^[%s:.]*", "^%s*by%s+the%s+[Ee]ditors?%s*:?%s*", "^%s*on%s+", "^%s*le%s+", "^%s*am%s+", "^%s*[Dd]ate%s*:?%s*",
  "^%s*for%s+publication%s+", "^%s*in%s+" }
M.add {
  name = "received date",
  find = function(doc)
    for i = 1, math.min(2, #(doc.texts or {})) do
      for _, word in ipairs(RECEIVED) do
        if doc.texts[i]:find(word) then return doc.texts[i] end
      end
    end
  end,
  read = function(text)
    for line in text:gmatch("[^\n]+") do
      for _, word in ipairs(RECEIVED) do
        local from = 1
        while true do
          local _, b = line:find(word, from)
          if not b then break end
          local rest = line:sub(b + 1)
          for _, between in ipairs(BETWEEN) do
            local _, e = rest:find(between)
            local date = e and M.date(rest:sub(e + 1))
            if date then return { pubdate = date } end
          end
          from = b + 1
        end
      end
    end
    return {}
  end,
  confidence = 0.7,
}

-- A paper, a set of notes or a magazine article with its date on a line of
-- its own on the first page: "March 12, 2015", "Date: October 2009.",
-- "Version of 3 January 2020", "SEPTEMBER 2002".
local LABEL = { "^[Dd]ated?%s*:?%s*", "^DATE%s*:?%s*", "^[Tt]his%s+[Vv]ersion%s*:?%s*", "^[Vv]ersion%s+of%s*:?%s*", "^[Vv]ersion%s*:%s*",
  "^[Dd]raft%s+of%s*:?%s*", "^[Dd]raft%s*:%s*", "^[Ll]ast%s+%a+%s*:?%s*", "^[Rr]evised%s*:?%s*", "^[Cc]ompiled%s+o?n?%s*:?%s*",
  "^[Pp]reliminary%s+[Vv]ersion%s*,?%s*", "^" }
M.add {
  name = "dated page",
  find = function(doc) return doc.texts and doc.texts[1] end,
  read = function(text)
    local before = "" -- the line above, when there is no gap between
    for raw in (text .. "\n"):gmatch("(.-)\n") do
      local line = trim(raw):gsub("^%((.*)%)$", "%1")
      if #line > 0 and #line <= 48 then
        for _, label in ipairs(LABEL) do
          local _, e = line:find(label)
          if e then
            local date, stop = M.date(line:sub(e + 1))
            -- The date is all there is on the line; and a bare date is not the
            -- end of a sentence that began on the line above ("... in a
            -- letter to Gauss dated / February 8, 1827.").
            local prose = label == "^" and #before >= 60 and not before:find("[.:;]$")
            if date and not prose and line:sub(e + stop):match("^%s*[.,;]?%s*$") then return { pubdate = date } end
          end
        end
      end
      before = trim(raw)
    end
    return {}
  end,
  confidence = 0.7,
}

-- A journal heads an article with where it stands: "Physica 63 (1973) 1-32",
-- "Journal of Algebra 320 (2008) 1234–1256", "Invent. math. 123, 1–40
-- (1996)", "Ann. of Math. (2) 141 (1995), 443–551". M.journal(text) gives
-- { journal=, volume=, year=, pages= } for the first such line of a page.
local DASH = "[%-\226]" -- a hyphen, or the first byte of an en or em dash
function M.journal(text)
  local n = 0
  for raw in text:gmatch("[^\n]+") do
    n = n + 1
    if n > 40 then break end
    -- without the number of a journal's series: "Ann. of Math. (2) 141"
    local line = trim(raw):gsub("%s%(%d%)%s", " ", 1)
    if #line <= 110 then
      -- Name 63 (1973) 1-32
      local name, vol, year, first = line:match("^(%u[%a\128-\255%.&,' %-]-)%s+(%d+)%s*%((%d%d%d%d)%)%s*,?%s*p?p?%.?%s*([%dlI]+)%s*" .. DASH)
      if not name then
        -- Name 123, 1–40 (1996)
        name, vol, first, year = line:match("^(%u[%a\128-\255%.&,' %-]-)%s+(%d+)%s*,%s*([%dlI]+)%s*" .. DASH .. "[\128-\191]*%s*%d+%s*%((%d%d%d%d)%)")
      end
      year = tonumber(year)
      -- "Milan J. Math. Vol. 78 (2010)", "Physics, volume 209 (1984)"
      name = name and trim(name):gsub("[,%s]*[Vv][Oo][Ll]%a*%.?$", ""):gsub("[,%s]*[Ss][Yy][Mm][Pp]%a*%.?%s*[Nn][Oo]%.?$", ""):gsub("[,%s]*[Nn][Oo]%.$", "")
        :gsub("[,%s]+$", "")
      if name and #name >= 4 and year and year >= 1700 and year <= tonumber(os.date("%Y")) + 1 then
        return { journal = dressed(name), volume = tonumber(vol), year = year, pages = first }
      end
    end
  end
  return nil
end

-- An article's publisher is its journal, with the house that puts the
-- journal out before it when the page names that too (on its copyright
-- line): "Elsevier: Journal of Algebra".
M.add {
  name = "journal header",
  find = function(doc)
    local text = doc.texts and doc.texts[1]
    return text and M.journal(text) and text or nil
  end,
  read = function(text, doc)
    local j = M.journal(text)
    local house
    for i = 1, math.min(3, #(doc.texts or {})) do
      local holder, known = M.copyright_holder(doc.texts[i])
      if holder and known then
        house = holder
        break
      end
    end
    -- the page names no house, but the book has one already: the journal goes after it
    if not house and doc.id then
      local book = lulibre.book(doc.id)
      house = book and M.known_house(book.publisher)
    end
    return { pubdate = tostring(j.year), publisher = M.with_journal(house, j.journal), confidence = { publisher = 0.82 } }
  end,
  confidence = 0.8,
}

-- The copyright line of a book or an article gives the year it came out:
-- "© 2008 Elsevier Inc.", "Copyright (c) 1965, 1984 by ...". Where several
-- years stand together the latest is the edition in hand.
local function copyright_year(text)
  -- the years after the sign: "1965, 1984", "1994–2023"
  local YEARS = "([%d,%s%-\226\128\147\148]+)"
  for _, pattern in ipairs { "©%s*" .. YEARS, "[Cc]opyright%s*%(?[cC]?%)?%s*\194?\169?%s*" .. YEARS, "COPYRIGHT%s*%(?[cC]?%)?%s*\194?\169?%s*" .. YEARS,
    "%(c%)%s*" .. YEARS } do
    for run in text:gmatch(pattern) do
      local best
      for digits in run:gmatch("%f[%d]%d%d%d%d%f[%D]") do
        local year = tonumber(digits)
        if year >= 1700 and year <= tonumber(os.date("%Y")) + 1 and (not best or year > best) then best = year end
      end
      if best then return best end
    end
  end
  return nil
end

-- Whose copyright it is: on a book or a journal's article, the publisher.
-- Houses are known by a word of their name and written one way (M.houses:
-- { pattern, name }, the pattern matched against the holder in lower case);
-- add to it for more.
M.houses = {
  { "springer", "Springer" }, { "birkh.-user", "Birkhäuser" }, { "elsevier", "Elsevier" }, { "north%-holland", "North-Holland" },
  { "academic press", "Academic Press" }, { "cambridge university press", "Cambridge University Press" },
  { "oxford university press", "Oxford University Press" }, { "princeton university press", "Princeton University Press" },
  { "university of chicago", "University of Chicago Press" }, { "harvard university press", "Harvard University Press" },
  { "yale university press", "Yale University Press" }, { "massachusetts institute of technology", "MIT Press" },
  { "mit press", "MIT Press" }, { "american mathematical society", "American Mathematical Society" },
  { "mathematical association of america", "Mathematical Association of America" },
  { "society for industrial and applied", "SIAM" }, { "european mathematical society", "European Mathematical Society" },
  { "london mathematical society", "London Mathematical Society" }, { "american physical society", "American Physical Society" },
  { "institute of physics", "IOP Publishing" }, { "iop publishing", "IOP Publishing" }, { "ieee", "IEEE" },
  { "association for computing machinery", "ACM" }, { "%f[%a]acm%f[%A]", "ACM" }, { "mcgraw%-hill", "McGraw-Hill" },
  { "wiley", "Wiley" }, { "addison%-wesley", "Addison-Wesley" }, { "pearson", "Pearson" }, { "prentice", "Prentice Hall" },
  { "crc press", "CRC Press" }, { "chapman", "Chapman & Hall" }, { "taylor & francis", "Taylor & Francis" },
  { "informa uk", "Taylor & Francis" }, { "duke university press", "Duke University Press" },
  { "mathematical sciences publishers", "Mathematical Sciences Publishers" }, { "institute of mathematical statistics", "Institute of Mathematical Statistics" },
  { "routledge", "Routledge" }, { "de gruyter", "De Gruyter" }, { "kluwer", "Kluwer" }, { "world scientific", "World Scientific" },
  { "dover publications", "Dover" }, { "o'reilly", "O'Reilly" }, { "no starch", "No Starch Press" }, { "manning", "Manning" },
  { "apress", "Apress" }, { "packt", "Packt" }, { "nature publishing", "Nature Publishing Group" }, { "annual reviews", "Annual Reviews" },
  { "hindawi", "Hindawi" }, { "john benjamins", "John Benjamins" }, { "sage publications", "SAGE" }, { "w%. ?h%. ?freeman", "W. H. Freeman" },
  { "benjamin", "W. A. Benjamin" }, { "van nostrand", "Van Nostrand" }, { "hermann", "Hermann" }, { "interscience", "Interscience" },
}

--- A publisher's name written the one way its house is (M.houses), or as it
-- is when the house is not known: "Springer-Verlag New York, Inc." and
-- "Springer Science and Business Media LLC" are "Springer".
function M.house(name)
  if type(name) ~= "string" or trim(name) == "" then return nil end
  local low = lulibre.lower(name)
  for _, house in ipairs(M.houses) do
    if low:find(house[1]) then return house[2] end
  end
  -- "American Institute of Mathematical Sciences (AIMS)"
  return (trim(name):gsub("%s*%([%u&]+%)$", ""))
end

--- The house a name is one of (as M.houses writes it), or nil when it is
-- none that is known.
function M.known_house(name)
  if type(name) ~= "string" then return nil end
  local low = lulibre.lower(name)
  for _, house in ipairs(M.houses) do
    if low:find(house[1]) then return house[2] end
  end
  return nil
end

-- Who registers a journal's articles without publishing the journal: not
-- named as its publisher.
M.archives = { "jstor", "project euclid", "project muse", "crossref" }

-- what stands between a house and its journal
M.journal_join = ": "

--- The publisher of an article: its journal, after the house that puts the
-- journal out when there is one ("Elsevier: Journal of Algebra"). Either
-- alone when the other is missing; nil when both are.
function M.with_journal(publisher, journal)
  publisher, journal = M.house(publisher), type(journal) == "string" and trim(journal) ~= "" and trim(journal) or nil
  if publisher then
    local low = lulibre.lower(publisher)
    for _, archive in ipairs(M.archives) do
      if low:find(archive, 1, true) then publisher = nil end
    end
  end
  if not journal then return publisher end
  -- a society's own journal already says whose it is
  if not publisher or lulibre.lower(journal):find(lulibre.lower(publisher), 1, true) then return journal end
  return publisher .. M.journal_join .. journal
end

-- what else a holder that is a publisher, not a person, is called
local ORG = { "press", "publish", "verlag", "society", "university", "books", "media", "institute", "association", "& sons",
  "company", "%f[%a]inc%f[%A]", "%f[%a]ltd%f[%A]", "%f[%a]llc%f[%A]", "gmbh", "éditions", "editions", "foundation", "académie", "academy" }

-- (the sign is two bytes: "©?" in a pattern would ask for the first of them)
local SIGNS = { "©%s*", "[Cc]opyright%s*%(?[cC]?%)?%s*\194?\169?%s*", "COPYRIGHT%s*%(?[cC]?%)?%s*\194?\169?%s*", "%(c%)%s*" }
local YEARS = "[%d,%s%-\226\128\147\148]*%d%d%d%d"

--- The holder a copyright line names, if it is a publisher: its name (as
-- M.houses writes it, or as the line does), and whether the house is known.
function M.copyright_holder(text)
  for raw in text:gmatch("[^\n]+") do
    local line = trim(raw)
    if #line <= 140 then
      for _, sign in ipairs(SIGNS) do
        -- "© 2008 by Elsevier Inc. All rights reserved"  or  "© Springer-Verlag Berlin Heidelberg 1999"
        local holder = line:match(sign .. YEARS .. "%s*,?%s*[Bb]?[Yy]?%s+(.+)$") or line:match(sign .. "(%u.-)%s*,?%s*" .. YEARS)
        if holder then
          holder = holder:gsub("^[Bb]y%s+", ""):gsub("^[Tt]he%s+", ""):gsub("%s*[.,]?%s*[Aa]ll [Rr]ights.*$", ""):gsub("%s*[.,]?%s*Printed in.*$", "")
            :gsub(",%s*part of.*$", ""):gsub(",%s*corrected.*$", ""):gsub("[%s.,;:]+$", ""):gsub("%.?%s+All$", "")
          local low = lulibre.lower(holder)
          local org = false
          for _, word in ipairs(ORG) do
            if low:find(word) then org = true end
          end
          -- a house's name may be a person's too (Hermann, Benjamin, Wiley): a
          -- holder who reads as a person is one
          local person = not org and names.is_person(holder)
          for _, house in ipairs(M.houses) do
            if low:find(house[1]) and not person then return house[2], true end
          end
          if org and #holder >= 4 and #holder <= 60 and not low:find("author") and not low:find("owner") and not names.is_person(holder) then
            return holder, false
          end
        end
      end
    end
  end
  return nil
end

M.add {
  name = "copyright line",
  find = function(doc)
    for i = 1, math.min(5, #(doc.texts or {})) do
      if copyright_year(doc.texts[i]) or M.copyright_holder(doc.texts[i]) then return doc.texts[i] end
    end
  end,
  read = function(text)
    local year = copyright_year(text)
    local holder, known = M.copyright_holder(text)
    return { pubdate = year and tostring(year) or nil, publisher = holder, confidence = { publisher = known and 0.8 or 0.65 } }
  end,
  confidence = 0.75,
}

return M
