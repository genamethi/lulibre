--- Reads pages that state their facts in known places.
--
-- Examples are a book's cataloguing block, a publisher's series page and
-- the stamp arXiv prints down a margin. If lulibre recognises such a page,
-- it reads the page by rule, with more confidence than a title page read
-- by font size. A layout describes one kind of page:
--
--    local layouts = require "lulib._layouts"
--    layouts.add {
--      name = "ams-memoirs",                          -- shown as where a value came from
--      marks = { "memoirs of the", "american mathematical society" },
--      fields = {
--        series = "Memoirs of the American Mathematical Society",      -- a value as it stands
--        series_index = "Number%s+(%d+)",                              -- a pattern with a capture
--        pubdate = "(%d%d%d%d)%s*%S*%s*Volume",
--        publisher = function(text, doc) return "AMS" end,             -- or a function
--      },
--      confidence = 0.85,
--    }
--
-- - `marks`: Lua patterns, matched ignoring case. All of them must appear
--   on one of the file's first pages for the layout to apply, and the
--   fields are read from that page. For a test patterns can't express, give
--   `find = function(doc)` instead, returning the text to read.
-- - `fields`: for each field (title authors tags series series_index
--   publisher pubdate identifiers), a constant, a pattern whose first
--   capture is the value, or a function(text, doc) returning the value. A
--   layout may instead give `read = function(text, doc)` returning a table
--   of fields.
-- - `confidence`: how far the layout is trusted (0.8 by default).
--
-- Add your own layouts in ~/.config/lulibre/init.lua or a module it
-- requires. `lulib._layouts.read` shows what every layout reads from the book
-- under the cursor.
--
-- @library lulib._layouts
-- @usage
-- local layouts = require "lulib._layouts"
-- layouts.add { name = "my-series", marks = { "my series" }, fields = { series = "My Series" } }
-- layouts.read(doc)              --> { {field=, value=, source=, confidence=}, ... }
-- layouts.house("Springer-Verlag New York, Inc.")   --> "Springer"
local expr = require "expr"
local names = require "lulib._names"
local taxonomy = require "lulib._taxonomy"

local M = {}

--- The layouts, in the order they are tried.
M.list = {}

--- Adds a layout, or replaces the layout with the same name.
-- @tparam table layout
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

--- Removes a layout.
-- @tparam string name
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

--- Returns what the layouts read from a document.
-- @tparam table doc `doc.texts` is the text of each of the first pages
-- @treturn {table,...} `{ {field=, value=, source=, confidence=}, ... }`
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
  -- (the full stop that ends the entry goes; the one after an initial stays)
  entry = entry:gsub(",?%s*%d%d%d%d%s*%-%s*%d*%s*%.?$", "") -- the comma before the dates may be lost in a scan:gsub(",%s*$", ""):gsub("(%l)%.%s*$", "%1"):gsub(",%s*$", "")
  local family, given = entry:match("^([^,]+),%s*(.+)$")
  if not family then return nil end
  given = given:gsub(",.*$", "")
  local name = trim(given) .. " " .. trim(family)
  return names.clean(name) and name or nil
end

-- Series known by one spelling, and who publishes each (nil where more than
-- one house has a series of the name).
local AMS, CUP, PUP = "American Mathematical Society", "Cambridge University Press", "Princeton University Press"
--- Series with one known spelling, and the publisher of each: `{ { name, house }, ... }`.
M.series = {
  { "Graduate Texts in Mathematics", "Springer" }, { "Undergraduate Texts in Mathematics", "Springer" },
  { "Lecture Notes in Mathematics", "Springer" }, { "Lecture Notes in Computer Science", "Springer" },
  { "Lecture Notes in Physics", "Springer" }, { "Universitext", "Springer" },
  { "Springer Monographs in Mathematics", "Springer" }, { "Grundlehren der mathematischen Wissenschaften", "Springer" },
  { "Ergebnisse der Mathematik und ihrer Grenzgebiete", "Springer" },
  { "Springer Undergraduate Mathematics Series", "Springer" }, { "Applied Mathematical Sciences", "Springer" },
  { "Texts in Applied Mathematics", "Springer" }, { "Graduate Texts in Physics", "Springer" },
  { "Springer Series in Statistics", "Springer" }, { "Classics in Mathematics", "Springer" },
  { "Progress in Mathematics", "Birkhäuser" },
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

--- Returns a series' name as the series writes it: a known series in its
-- usual spelling, any other in title case.
-- @tparam string s
-- @treturn string
function M.series_name(s)
  local low = s:lower()
  for _, known in ipairs(M.series) do
    if known[1]:lower() == low then return known[1] end
  end
  return require("lulib._titlecase").apply(s)
end

-- The block as the Library of Congress has set it out since 2015, each part
-- under a label and the parts of a part between bars:
--   Names: Miyagawa, Shigeru, author.
--   Title: Agreement beyond Phi / Shigeru Miyagawa.
--   Description: Cambridge, MA : The MIT Press, [2017] | Series: Linguistic inquiry monographs ; 75 | Includes ...
--   Identifiers: LCCN 2016030743 | ISBN 9780262035880 (hardcover : alk. paper)
--   Subjects: LCSH: Grammar, Comparative and general--Agreement. | ...
--   Classification: LCC P299.A35 M59 2017 | DDC 415--dc23
local LABELS = { "Names", "Title", "Other titles", "Description", "Series", "Identifiers", "Subjects", "Classification", "LC record", "LC ebook record" }
local function labelled_cip(block, text)
  -- one line, so that a part broken over lines is whole; then cut at the labels
  local flat = " " .. block:gsub("%s+", " ") .. " "
  local found = {}
  for _, label in ipairs(LABELS) do
    local a, b = flat:find("[ |]" .. label .. ":%s", 1)
    if a then found[#found + 1] = { label = label, at = a, from = b + 1 } end
  end
  table.sort(found, function(x, y) return x.at < y.at end)
  local part = {}
  for k, f in ipairs(found) do
    local to = found[k + 1] and found[k + 1].at - 1 or math.min(#flat, f.from + 600)
    part[f.label] = part[f.label] or trim(flat:sub(f.from, to)):gsub("%s*|%s*$", "")
  end
  if not part.Title then return nil end
  local out = {}
  local title = part.Title:match("^(.-)%s+/%s") or part.Title
  title = trim(title):gsub("%s*[.:]$", ""):gsub("%s+:%s+", ": ")
  if #title >= 3 and title:find("%a") then out.title = title end
  -- who it is filed under: the people named as authors, else as editors
  local people, editors = {}, {}
  for entry in ((part.Names or "") .. "|"):gmatch("%s*(.-)%s*|") do
    -- "Friederici, Angela D., author." : the last part says what they did, when it is one of these words
    local last = entry:match(",%s*([%a ]-)%.?$") or ""
    local role
    for _, word in ipairs { "author", "editor", "translator", "writer", "illustrator", "compiler", "contributor", "photographer" } do
      if last:find(word, 1, true) then role = role or word end
    end
    local bare = entry:gsub(",%s*%d%d%d%d%s*%-%s*%d*", "")
    if role then bare = bare:gsub(",%s*[%a ]-%.?$", "") end
    local who = person(bare)
    if who then
      if role == nil or role == "author" then people[#people + 1] = who
      elseif role == "editor" or role == "translator" or role == "compiler" then editors[#editors + 1] = who end
    end
  end
  if #people == 0 then people = editors end
  if #people > 0 then out.authors = table.concat(people, " & ") end
  local desc = part.Description or ""
  out.pubdate = desc:match("%[?([12]%d%d%d)%]?")
  local house = desc:match("^[^:|]-:%s*([^,|%[]-)%s*,") -- "Place : House, [year]"
  if house and #trim(house) >= 3 then out.publisher = trim(house) end
  local series = part.Series or desc:match("|%s*Series:%s*([^|]+)")
  if series then
    local name, number = trim(series):match("^(.-)%s*;%s*[vVnNoO. ]*(%d+)")
    name = name or trim(series):gsub("%s*|.*$", "")
    if #name > 6 then
      out.series = M.series_name(name)
      out.series_index = number
    end
  end
  local class = part.Classification or ""
  local lcc = class:match("LCC%s+([%u][%w.]+)")
  if lcc then out.tags = taxonomy.from_lcc(lcc) end
  if not out.tags then
    local dewey = class:match("DDC%s+(%d%d%d[%d./']*)")
    if dewey then out.tags = taxonomy.from_dewey(dewey) end
  end
  return out
end

-- dashes a scan or a font gives the block for its hyphens: the middle dot
-- (·), the hyphen and non-breaking hyphen (U+2010, U+2011), the en and em
-- dashes; read as "-", so "Steen, Lynn A 1941·" is a main entry with its dates
local DASHES = { "\194\183", "\226\128\144", "\226\128\145", "\226\128\147", "\226\128\148" }

--- Reads the cataloguing block that the Library of Congress (or the
-- British or German national library) supplies for the back of a title page:
--
--   Library of Congress Cataloging in Publication Data
--   Lang, Serge                               the main entry: who it is filed under
--   SL2(R).                                   the title [ / who wrote it ]
--   (Graduate texts in mathematics; 105)      the series and the number in it
--   1. Lie groups. 2. Representations of groups. I. Title. II. Series.
--   QA387.L35 1985                            the class it is shelved in, and the year
--   512'.55                                   its Dewey number
--
-- Returns a table of fields, leaving out what can't be read. The labelled
-- form used since 2015 is read too.
-- @tparam string text a page's text
-- @treturn table
function M.cip(text)
  for _, d in ipairs(DASHES) do text = text:gsub(d, "-") end
  local at = text:lower():find("cataloging%s*%-?%s*in%s*%-?%s*publication") or text:find("CIP%-?%s*Einheitsaufnahme")
  if not at then return {} end
  at = text:sub(1, at):match(".*()\n") or at -- from the start of the line the words stand on
  local lines = {}
  for raw in text:sub(at):gmatch("[^\n]+") do -- (a loop variable cannot be assigned to in Lua 5.5)
    local line = trim(raw)
    if line ~= "" then lines[#lines + 1] = line end
    if #lines >= 22 then break end
  end
  -- the labelled form of the block is read by its labels
  if text:sub(at, at + 1500):find("\n%s*Title:%s") then
    local read = labelled_cip(text:sub(at, at + 2400):gsub("^[^\n]*\n", "", 1), text)
    if read then return read end
  end
  local out, i = {}, 2
  -- "A catalog record for this book is available from ..." is a block that holds no record
  if lines[i] and lines[i]:lower():find("catalog%a* record for this") then return {} end
  -- the German national library heads its own: "Die Deutsche Bibliothek - CIP-Einheitsaufnahme",
  -- then "Surname, Given: Title / ..." on one line
  if lines[i] and lines[i]:find("CIP%-?%s*Einheits") then i = i + 1 end
  local german = lines[i - 1] and lines[i - 1]:find("Einheits") and lines[i] and { lines[i]:match("^([%a%-' ]+,%s*[%a%-.' ]+):%s+(.+)$") }
  if german and german[1] then
    out.authors = person(german[1])
    lines[i] = german[2]
  end
  -- "Main entry under title:" says the book is filed under its title: the title follows
  if lines[i] and lines[i]:lower():find("^main entry under title") then i = i + 1 end
  -- the main entry, when the book is filed under a person
  local who = lines[i] and person(lines[i])
  if who then
    out.authors = who
    i = i + 1
  elseif lines[i] and (lines[i]:find("^[^,]+,[^,]+,%s*%d%d%d%d%s*%-") or lines[i]:find("^[^,]+,[^,]+,%s*date%s*$")
      or lines[i]:find("^[%a%-' ]+,%s*[%a%-.' ]+%(.-%)%s*$")) and lines[i + 1] then
    i = i + 1 -- a main entry (with its dates, or its name in full in brackets) that did not read as a name: not the title, at least
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
  -- (a line that is a label, a copyright notice or an imprint is no title)
  local label = title:match("^(%a[%a ]-):%s") or (title:lower():find("^main entry") and "Names")
  for _, known in ipairs(LABELS) do
    if label == known then title = "" end
  end
  -- (nor is an address, which is what follows where the words stand in a preface)
  if title:find("Department") or title:find("University") or title:find("College") or title:lower():find("catalog%a* record") then title = "" end
  if #title >= 3 and title:find("%a") and #title <= 200 and not title:find("©") then out.title = title end
  -- A block printed in a book is often a scan read by machine: its word is
  -- taken for less than that of a block that came as text.
  out.confidence = { title = 0.8, authors = 0.85 }
  local rest = table.concat(lines, "\n", math.min(i, #lines))
  -- "(Graduate texts in mathematics; 105)" or "(... ; v. 27)"; not what an
  -- ISBN is followed by, the binding and the paper: "(pbk. : alk. paper)",
  -- "(paperback : alkaline paper)", "(hardcover)", "(e-book)"
  local function binding(s)
    local low = s:lower()
    for _, w in ipairs { "paper", "pbk", "hbk", "hardcover", "hardback", "softcover", "cloth", "acid", "alk%.",
        "e%-?book", "electronic", "print", "online", "pdf", "epub", "spiral", "set%f[%A]" } do
      if low:find(w) then return true end
    end
    return false
  end
  -- (and not in the subject headings, "1. Python (Computer program language)":
  -- the series stands in the description, before them)
  local desc = rest:sub(1, (rest:find("%f[%w]1%.%s+%u") or (#rest + 1)) - 1)
  local series, number = desc:match("%(([%a][^();]-)%s*;%s*[vVnNoO. ]*(%d+)%s*%)")
  if not series then series = desc:match("%(([%a][^();]-)%)") end
  if series and #series > 6 and not binding(series) then
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
  return out
end

M.add {
  name = "cataloguing data",
  find = function(doc)
    for _, text in ipairs(doc.texts or {}) do
      if text:lower():find("cataloging%s*%-?%s*in%s*%-?%s*publication") or text:find("CIP%-?%s*Einheitsaufnahme") then return text end
    end
  end,
  read = M.cip,
  confidence = 0.9,
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

-- where a line of a page begins with a name, or a bracket or label before it: not
-- inside a longer name ("Communications on Pure and Applied Mathematics")
local function starts_a_line(low, name)
  local from = 1
  while true do
    local a, b = low:find(name, from, true)
    if not a then return nil end
    local before = low:sub(1, a - 1):match("([^\n]*)$")
    if before:match("^[%s%(%[]*$") or before:match("series[%s:]*$") then return a, b end
    from = b + 1
  end
end

-- A book's series page or title-page verso: the series' name with the
-- volume's number after it, and the year in the copyright line. Any series
-- in M.series is known (add to it for more: { name, publisher }).
M.add {
  name = "series page",
  find = function(doc)
    for _, text in ipairs(doc.texts or {}) do
      local low = text:lower()
      for _, s in ipairs(M.series) do
        if starts_a_line(low, s[1]:lower()) then return text end
      end
    end
  end,
  read = function(text)
    local out, low = {}, text:lower()
    -- the series the page is headed with: the one named first on it (others
    -- may be advertised further down)
    local first
    for _, s in ipairs(M.series) do
      local a, b = starts_a_line(low, s[1]:lower())
      if a and (not first or a < first) then
        first = a
        out.series, out.publisher = s[1], s[2]
        local after = text:sub(b + 1, b + 48)
        out.series_index = after:match("^[%s,;:]*[Vv]ol%a*%.?%s*(%d+)%f[%D]") or after:match("^[%s,;:]*[Nn]umber%s*(%d+)%f[%D]")
          or after:match("^[%s,;:]*[Nn]o%.%s*(%d+)%f[%D]") or after:match("^[%s,;:]*(%d+)%f[%D]")
      end
    end
    -- the year of the edition in hand: a reprint names the edition it reprints
    -- (of the years a copyright line gives, the latest: copyright_year)
    local year = copyright_year(text)
    out.pubdate = text:match("[Rr]eprint of the %a+ %d*%a* ?edition (%d%d%d%d)") or (year and tostring(year)) or nil
    return out
  end,
  confidence = 0.85,
}

-- The stamp arXiv prints down the left margin of a paper's first page:
-- "arXiv:1012.6008v1 [math.CO] 29 Dec 2010". Its date is the day THAT
-- VERSION was put up. On a first version that is the day the paper was
-- submitted, which is what a date of publication means for a preprint; on
-- a later one it is the day of a revision, months or years on, and says
-- nothing of when the paper appeared (half the stamped papers of the
-- library this was written against carry a later version). So only a
-- first version's stamp gives a date; for the others the paper's number
-- gives the year, and arXiv's own record (:enrich) the day.
local MONTH = { jan = 1, feb = 2, mar = 3, apr = 4, may = 5, jun = 6, jul = 7, aug = 8, sep = 9, oct = 10, nov = 11, dec = 12 }
M.add {
  name = "arXiv stamp",
  marks = { "arxiv:%d%d%d%d%.%d+" },
  read = function(text)
    local version, day, month, year = text:match("arXiv:%d%d%d%d%.%d+v?(%d*)%s*%[[%a.%-]+%]%s*(%d%d?)%s+(%a%a%a)%a*%s+(%d%d%d%d)")
    local m = month and MONTH[month:lower()]
    if not m or (version ~= "" and version ~= "1") then return {} end
    return { pubdate = ("%s-%02d-%02d"):format(year, m, tonumber(day)) }
  end,
  -- under arXiv's own record of the same paper (0.95), which is the one to take when both speak
  confidence = 0.9,
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

--- Words before "Series" when the series is a mathematical sum, not a set of books.
M.not_series = words [[fourier power dirichlet taylor laurent maclaurin random time eisenstein poincaré poincare hilbert
  puiseux formal infinite trigonometric divergent convergent composition central derived hypergeometric asymptotic theta
  farey singular geometric harmonic complementary discrete principal volterra neumann binomial orthogonal double multiple
  lambert fibonacci numerical alternating telescoping generating zeta chief normal subnormal upper lower new second third
  first fourth this the a each in of and]]

--- Publishers and societies whose name starts a series' name.
M.series_houses = words [[springer cambridge oxford princeton wiley mit chapman academic elsevier north-holland birkhäuser
  birkhauser ams ias london gruyter world dover pearson mcgraw-hill addison-wesley prentice crc siam ems clay fields cbms nato
  schaum's schaum university chicago harvard yale stanford american european society international carus pitman van
  wadsworth brooks/cole benjamin interscience kluwer reidel plenum teubner vieweg hermann masson dunod]]

local MINOR = words "in of the and on for to a an und der die das de des du et la le von zur für per il e y & - – /"

local function minor(word)
  return MINOR[expr.lower((word or ""):gsub("^%p+", ""):gsub("[%p]+$", ""))] ~= nil
end

-- is the line set like a name: its words capitalised, but for the small ones
local function titled(line)
  local n = 0
  for w in line:gmatch("%S+") do
    n = n + 1
    local bare = w:gsub("^[%p]+", ""):gsub("[%p]+$", "")
    if bare ~= "" and not MINOR[expr.lower(bare)] and not bare:match("^[%u%d\128-\255]") then return false end
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
  if letters > 0 and lower == 0 then name = require("lulib._titlecase").apply(expr.upper(name)) end
  return name
end

--- Returns the series a page names, if any: its name, the volume's number
-- (or nil), and the evidence.
-- @tparam string text
-- @treturn[1] string the name
-- @treturn[1] string|nil the number
-- @treturn[1] string the evidence
-- @treturn[2] nil
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
        local sum = before and M.not_series[expr.lower(before:gsub("^%p+", ""):gsub("%p+$", ""))]
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
      local before = expr.lower(name:match("(%S+)%s+[Ss][Ee][Rr][Ii][Ee][Ss]%f[%A]") or "the")
      local after = name:match("[Ss][Ee][Rr][Ii][Ee][Ss]%s+(%S+)")
      before = before:gsub("^%p+", ""):gsub("%p+$", "")
      if titled(name) and not M.not_series[before] and after ~= "of" and not name:find("^Series") then
        number = number or below(i)
        local house = M.series_houses[expr.lower(name:match("^[%a\128-\255/%-']+") or "")]
          or M.series_houses[expr.lower(name:match("^[Tt][Hh][Ee]%s+([%a\128-\255/%-']+)") or "")]
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
  confidence = 0.8,
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
  return MONTHS[expr.lower(word)]
end

--- Returns the date a text starts with, as YYYY-MM-DD, and where the date
-- ends. Reads "8 February 1972", "Feb. 8, 1972", "March 2004" (the first of
-- the month) and "2004-03-12". Returns nil if the text does not start with
-- a date. Dates in digits only (3/12/2004) are not read, since the month is
-- ambiguous.
-- @tparam string s
-- @treturn[1] string YYYY-MM-DD
-- @treturn[1] integer where the date ends
-- @treturn[2] nil
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
  confidence = 0.75,
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
  confidence = 0.75,
}

local DASH = "[%-\226]" -- a hyphen, or the first byte of an en or em dash

--- Returns where an article was published, from the heading a journal
-- puts over it: "Physica 63 (1973) 1-32", "Journal of Algebra 320 (2008)
-- 1234–1256", "Invent. math. 123, 1–40 (1996)", "Ann. of Math. (2) 141
-- (1995), 443–551".
-- @tparam string text a page's text
-- @treturn table|nil `{ journal=, volume=, year=, pages= }`, for the first such line
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
      house = M.known_house(require("bookman").get(doc.id, "publisher"))
    end
    return { pubdate = tostring(j.year), publisher = M.with_journal(house, j.journal), confidence = { publisher = 0.87 } }
  end,
  confidence = 0.8,
}

--- Known publishers, as `{ pattern, name }`. On a book or a journal
-- article, the copyright holder is the publisher. A publisher is
-- recognised by a word of its name (the pattern, matched against the
-- holder in lower case) and written one way (the name). Add entries for
-- more publishers.
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

--- Returns a publisher's name in the one form `houses` gives it, or
-- unchanged if the publisher is not known. "Springer-Verlag New York, Inc."
-- and "Springer Science and Business Media LLC" both become "Springer".
-- @tparam string name
-- @treturn string
function M.house(name)
  if type(name) ~= "string" or trim(name) == "" then return nil end
  local low = expr.lower(name)
  for _, house in ipairs(M.houses) do
    if low:find(house[1]) then return house[2] end
  end
  -- "American Institute of Mathematical Sciences (AIMS)"
  return (trim(name):gsub("%s*%([%u&]+%)$", ""))
end

--- Returns the known publisher a name belongs to, as `houses` writes it,
-- or nil.
-- @tparam string name
-- @treturn string|nil
function M.known_house(name)
  if type(name) ~= "string" then return nil end
  local low = expr.lower(name)
  for _, house in ipairs(M.houses) do
    if low:find(house[1]) then return house[2] end
  end
  return nil
end

--- Archives that register a journal's articles without publishing the
-- journal, so they are never named as the publisher.
M.archives = { "jstor", "project euclid", "project muse", "crossref" }

--- The text between a publisher and its journal.
M.journal_join = ": "

--- Returns the publisher of an article: the journal, after the journal's
-- publisher if there is one ("Elsevier: Journal of Algebra"). If one is
-- missing, returns the other; if both are missing, nil.
-- @tparam string|nil publisher
-- @tparam string|nil journal
-- @treturn string|nil
function M.with_journal(publisher, journal)
  publisher, journal = M.house(publisher), type(journal) == "string" and trim(journal) ~= "" and trim(journal) or nil
  if publisher then
    local low = expr.lower(publisher)
    for _, archive in ipairs(M.archives) do
      if low:find(archive, 1, true) then publisher = nil end
    end
  end
  if not journal then return publisher end
  -- a society's own journal already says whose it is
  if not publisher or expr.lower(journal):find(expr.lower(publisher), 1, true) then return journal end
  return publisher .. M.journal_join .. journal
end

-- what else a holder that is a publisher, not a person, is called
local ORG = { "press", "publish", "verlag", "society", "university", "books", "media", "institute", "association", "& sons",
  "company", "%f[%a]inc%f[%A]", "%f[%a]ltd%f[%A]", "%f[%a]llc%f[%A]", "gmbh", "éditions", "editions", "foundation", "académie", "academy" }

-- (the sign is two bytes: "©?" in a pattern would ask for the first of them)
local SIGNS = { "©%s*", "[Cc]opyright%s*%(?[cC]?%)?%s*\194?\169?%s*", "COPYRIGHT%s*%(?[cC]?%)?%s*\194?\169?%s*", "%(c%)%s*" }
local YEARS = "[%d,%s%-\226\128\147\148]*%d%d%d%d"

--- Returns the holder a copyright line names, if the holder is a
-- publisher: the name (as `houses` writes it, or as the line does), and
-- whether the publisher is known.
-- @tparam string text
-- @treturn[1] string the name
-- @treturn[1] boolean true if the publisher is known
-- @treturn[2] nil
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
          local low = expr.lower(holder)
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
    return { pubdate = year and tostring(year) or nil, publisher = holder, confidence = { publisher = known and 0.85 or 0.7 } }
  end,
  confidence = 0.75,
}

return M
