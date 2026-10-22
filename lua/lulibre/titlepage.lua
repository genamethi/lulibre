--- Reads a title page the way a person does: by the role of each line.
-- titlepage works on the tagged lines the index keeps (text, font size,
-- superscript, rotation).
--
-- - `subject`: the arXiv class in the margin stamp, or else the MSC footnote
-- - `title`: the largest-font lines above the authors. `title_math` is the
--   same, with its mathematics marked up, if it has any.
-- - `authors`: the lines under the title that are names, up to the abstract
--   or the first affiliation
--
-- @reading lulibre.titlepage
-- @usage
-- local titlepage = require "lulibre.titlepage"
-- local got = titlepage.classify(lulibre.lines(12, 1))
-- print(got.title, table.concat(got.authors, " & "))
-- titlepage.byline("by A. Name")   --> "A. Name"
local ids = require "lulibre.ids"
local names = require "lulibre.names"
local taxonomy = require "lulibre.taxonomy"

local M = {}

local PUBLISHER = {
  "springer", "elsevier", "cambridge", "wiley", "world scientific", "de ?gruyter", "birkh",
  "american mathematical", "princeton", "oxford", "academic press", "%f[%a]crc%f[%A]",
  "chapman", "editorial board", "series editors?", "managing editor", "graduate texts",
  "undergraduate texts", "universitext", "lecture notes", "grundlehren", "pure and applied",
  "proceedings of symposia",
}
local EDITORS = { "editorial board", "series editors?", "managing editor", "edited by", "^editors?%f[%A]" }
-- where the front matter ends: a heading that stands alone ("Introduction",
-- "1. Introduction", "Contents"), not a title that begins with the word
-- ("Introduction to Commutative Algebra")
local STOP = { "^abstract", "^contents%s*$", "^table of contents", "^introduction%s*$", "^%d+%.?%s+introduction%s*$",
  "^keywords", "^r[e\195]\169?sum" }
local JUNK = {}
for w in ([[preface content contents index introduction bibliography references appendix
  abstract title chapter part note notes editorial copyright]]):gmatch("%S+") do JUNK[w] = true end

local function any(low, patterns)
  for _, p in ipairs(patterns) do
    if low:find(p) then return true end
  end
  return false
end

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- The title with its mathematics marked up (lulibre.notation), from the
-- lines it was read from, or nil when none of them has any. parts: the
-- title's lines as text, in order.
local function with_math(parts, lines)
  local marked = {}
  for _, l in ipairs(lines) do
    if l.math then marked[trim(l.text)] = l.math end
  end
  if not next(marked) then return nil end
  local out, found = {}, false
  for i, t in ipairs(parts) do
    if marked[t] then found = true end
    out[i] = marked[t] or t:gsub("[\\$]", "\\%0")
  end
  if not found then return nil end
  return (table.concat(out, " "):gsub("%s+", " "):gsub("^[ .,]+", ""):gsub("[ .,]+$", ""))
end

-- words that may stand in lower case inside a name
-- The series a line names, if it is nothing but a series' name: one of the
-- series lulibre knows (lulibre.layouts), or one the library already uses.
-- The library's series are read once, built in a local and put in place in
-- one step (tasks may share the module).
local library_series
local function series_of(t)
  local low = t:lower():gsub("%s+", " "):gsub("[ .,:;]+$", "")
  if #low < 6 then return nil end
  for _, known in ipairs(require("lulibre.layouts").series) do
    if known[1]:lower() == low then return known[1] end
  end
  if not library_series then
    local seen = {}
    local ok, rows = pcall(lulibre.sql, "SELECT DISTINCT series FROM books WHERE series IS NOT NULL AND series != ''")
    for _, row in ipairs(ok and rows or {}) do seen[row.series:lower()] = row.series end
    library_series = seen
  end
  return library_series[low]
end

-- A line with its bullets (• and ·, which are several bytes each in UTF-8,
-- so no character class can name them) turned into "|".
local function bullets(t)
  return (t:gsub("%s*\u{2022}%s*", "|"):gsub("%s*\u{00B7}%s*", "|"))
end

local PARTICLE = {}
for w in ("and de del della der den di da dos du la le van von zu y e"):gmatch("%S+") do PARTICLE[w] = true end

-- "Surname, Given; Surname, Given" and "SURNAME, G. H." the right way round
local function uninvert(s)
  local pieces, n = {}, 0
  for piece in s:gmatch("[^;]+") do
    n = n + 1
    pieces[n] = trim(piece)
  end
  local out = {}
  for i, piece in ipairs(pieces) do
    local family, given = piece:match("^([^,]+),%s*([^,]+)$")
    if family and (n > 1 or given:match("^[%u%.%s%-]+$")) then out[i] = trim(given) .. " " .. trim(family)
    else out[i] = piece end
  end
  return table.concat(out, "; ")
end

--- Reads a by-line. Returns the names on it ("by A. Name" gives "A. Name"),
-- "" for "by" alone on a line above the names, or nil if the line is not a
-- by-line. A sentence that happens to begin with "by" is recognised by its
-- length, its lower-case words, and brackets or digits in it.
-- @tparam string text
-- @treturn string|nil
function M.byline(text)
  local t = trim(text or "")
  if t:lower() == "by" then return "" end
  local rest = t:match("^[Bb][Yy]%s+(.+)$")
  if not rest then return nil end
  rest = rest:gsub("%s+[-–—]+%s+.*$", "")         -- "by U. K. Le Guin - from The Wind's Twelve Quarters"
  rest = rest:gsub("%s+and the%s+.*$", "")          -- "by T. Granlund and the GMP development team"
  rest = rest:gsub("[%*†‡§¶]", ""):gsub("[:,;.%s]+$", function(tail) return tail:find("%.") and "." or "" end)
  if not rest:match("%u%.$") then rest = rest:gsub("%.$", "") end -- keep the dot of a final initial only
  if #rest < 3 or #rest > 80 or rest:find("[%(%)%[%]%d]") or not rest:find("^[%u\128-\255]") then return nil end
  local words, small = 0, 0
  for w in rest:gmatch("%S+") do
    words = words + 1
    if w:find("^%l") and not PARTICLE[w:lower()] then small = small + 1 end
  end
  if words < 2 or words > 10 or small > 0 then return nil end
  return uninvert(rest)
end

--- Reads a title page's lines by their roles.
-- @tparam {table,...} lines as `lulibre.lines(id)` gives them
-- @treturn table `{ arxiv=, class=, subject=, title=, authors={...}, subject_source=, byline=,
-- name_first= }`. `byline` is true if a "by" line named the authors, which is the page's
-- own statement. `name_first` is true if the page starts with the author's name and has
-- the title further down.
function M.classify(lines)
  local r = { authors = {} }

  for _, l in ipairs(lines) do
    local id, class = ids.arxiv_stamp(l.text)
    if id then
      r.arxiv, r.class = id, class
      r.subject, r.subject_source = taxonomy.from_arxiv(class), "arXiv class"
      break
    end
  end
  if not r.subject then
    -- the footnote's keyword and its code are often on different lines
    local all = {}
    for _, l in ipairs(lines) do all[#all + 1] = l.text end
    local area = ids.msc(table.concat(all, " "))
    if area and taxonomy.msc[area] then
      r.subject, r.subject_source = taxonomy.msc[area], "MSC " .. area
    end
  end

  -- front matter: what comes before the abstract or the first affiliation
  local body = {}
  for _, l in ipairs(lines) do
    local t = trim(l.text)
    -- rotated text is the margin stamp; a bare number is a page number
    if t ~= "" and not l.rotated and not ids.arxiv_stamp(t) and not t:find("^%d+$") then
      local low = t:lower()
      if any(low, STOP) or names.is_affiliation(t) then break end
      body[#body + 1] = l
    end
  end
  if #body == 0 then return r end
  -- a line that is a series' name is the series, not the title: "Classics in
  -- Mathematics" above the author and the title, all set alike
  -- (On a page that also lists the series' editors or titles, the series line
  -- stays where it is and the page is read as before: there it is set apart
  -- from the title by its type, and taking it out would leave the editors.)
  local series_here = false
  do
    -- (every copy of the series line goes, and a line the page repeats is
    -- read once: some pages carry their text twice, over each other)
    local kept, series, seen = {}, nil, {}
    for _, l in ipairs(body) do
      local t = trim(l.text)
      local s = series_of(t)
      if s and (not series or s == series) then series = s
      elseif not seen[t] then seen[t] = true; kept[#kept + 1] = l end
    end
    if series then
      r.series = series
      local listing = #kept > 10
      for _, l in ipairs(kept) do
        if any(l.text:lower(), EDITORS) or l.text:lower():find("advisory board") then listing = true end
      end
      if not listing and #kept > 0 then body, series_here = kept, true end
    end
  end

  local max, smallest = 0, math.huge
  for _, l in ipairs(body) do max, smallest = math.max(max, l.size), math.min(smallest, l.size) end
  -- (a page set in one size, within 1.5 points, as such a series' pages are)
  local one_size = #body >= 2 and max - smallest <= 1.5
  local floor = max - 0.5
  local title, first, last = {}, 0, 0
  for i, l in ipairs(body) do
    -- a by-line set as large as the title ends the title; it is not part of it
    if M.byline(l.text) then
      if #title > 0 then break end
    elseif l.size >= floor then
      title[#title + 1] = trim(l.text)
      if first == 0 then first = i end
      last = i
    elseif #title > 0 then
      break
    end
  end
  -- A page set in one size throughout (typewritten notes, a paper run through
  -- an old converter) does not set its title off by type, and the "largest"
  -- run is the whole page. The title is then the lines at the top, as far
  -- as the first that is somebody's name, a by-line, a numbered paragraph,
  -- or, under a title in capitals, the first line that is not.
  if #title > 3 or #table.concat(title, " ") > 200 then
    local caps = title[1]:find("%u") ~= nil and title[1] == title[1]:upper()
    local keep, ended = { title[1] }, false
    for k = 2, math.min(#title, 5) do
      local t = title[k]
      -- under a title in capitals, a line in capitals goes on with it (and
      -- is not a list of names, though "NEGATIVE AND IMAGINARY NUMBERS" has
      -- the shape of one)
      local goes_on = caps and t == t:upper() and not M.byline(t)
      if not goes_on and ((names.looks_like_authors(t) and #names.validate { t } > 0) or M.byline(t)
        or t:find("^%d+[.)]%s") or caps or #t > 70) then
        ended = true
        break
      end
      keep[#keep + 1] = t
    end
    -- with nothing to end it, there is no telling title from text
    if ended or #title <= 5 then title, last = keep, first + #keep - 1 else title, last = {}, 0 end
  elseif first > 1 and #title > 0 then
    -- The line above a title's largest line is part of the title when it is
    -- set nearly as large and leads into it: "Introduction to" above
    -- "Commutative Algebra".
    local above = body[first - 1]
    local t = trim(above.text)
    if above.size >= 0.6 * max and #t < 60 and not names.is_person(t) and not M.byline(t)
      and (above.size >= 0.75 * max or t:lower():find(" to$")
        or t:lower():find(" of$") or t:lower():find(" in$") or t:lower():find(" on$") or t:lower():find(" the$")
        or t:lower():find(" and$") or t:lower():find(" for$")) then
      table.insert(title, 1, t)
    end
  end
  -- In a run of one size, a line at its start or end that is a person's name
  -- is the author line, and the title is the rest, however many lines it
  -- takes (series, author, title in two lines, all set alike).
  local everything = {}
  for _, l in ipairs(lines) do everything[#everything + 1] = l.text end
  everything = table.concat(everything, "\n")
  -- (a name that opens the run comes off only under a series line, the layout
  -- of a series' title page: "Julia Quick Syntax Reference" is a title)
  -- On a page set in one size, a line with the shape of a name is taken for
  -- one ("Tosio Kato"); where the type sets the title apart, only a line that
  -- reads as a person's name is ("Deep Learning", in 76-point type above
  -- "Techniques", is a title).
  local function one_name(t)
    return names.is_person(t, everything) or (one_size and names.looks_like_authors(t) and #names.validate { t } > 0)
  end
  -- several people on one line, set apart by bullets: "Hans Grauert • Reinhold Remmert"
  local function a_name(t)
    local split = bullets(t)
    if not split:find("|", 1, true) then return one_name(t) end
    local n = 0
    for part in split:gmatch("[^|]+") do
      local name = trim(part)
      if name ~= "" then
        if not one_name(name) then return false end
        n = n + 1
      end
    end
    return n > 0
  end
  -- (one line at the start: the author line under the series line; after it
  -- comes the title, whose words have a name's shape as often as not)
  local named, tail = {}, {}
  if series_here and #title > 1 and a_name(title[1]) then named[1] = table.remove(title, 1) end
  while #title > 1 and names.is_person(title[#title], everything) do table.insert(tail, 1, table.remove(title)) end
  for _, t in ipairs(tail) do named[#named + 1] = t end
  -- Under a series line, a run that is nothing but names is the author line,
  -- and the title is the lines after it, read as one, up to the next name
  -- (series, authors in larger type, title).
  if series_here and #named == 0 and #title == 1 and a_name(title[1]) then
    named[#named + 1], title = title[1], {}
    for i = last + 1, math.min(#body, last + 4) do
      local t = trim(body[i].text)
      if names.is_person(t, everything) or M.byline(t) or any(t:lower(), PUBLISHER) then break end
      title[#title + 1] = t
    end
    if #title > 0 then last = last + #title end
  end
  -- under a series line, "Volume 14" is the book's number in the series
  if series_here and #title == 1 then
    local n = title[1]:match("^[Vv]olume%s+(%d+)$") or title[1]:match("^[Nn]o%.?%s*(%d+)$") or title[1]:match("^(%d+)$")
    if n then r.series_index, title = n, {} end
  end
  local cand = table.concat(title, " "):gsub("%s+", " "):gsub("^[ .,]+", ""):gsub("[ .,]+$", "")
  local low = cand:lower()
  -- (a typesetter's stamp at the top of a page, "FM.qxd 9/29/05 11:18 PM Page i", is no title)
  if cand ~= "" and low:find("%a") and not any(low, PUBLISHER) and not JUNK[low]
    and not low:find("%.qxd") and not low:find("%f[%a]page [ivxlc%d]+$") then
    r.title, r.title_math = cand, with_math(title, body)
  end

  -- A page that opens with its author's name, alone on the first line and set
  -- largest (a home page, a reprint archive, a set of notes), has its title
  -- further down in the next largest type. It is taken for that layout only
  -- when the first line reads as one person's name, the next most prominent
  -- line does not, and no by-line says otherwise.
  local all_text = {}
  for _, l in ipairs(lines) do all_text[#all_text + 1] = l.text end
  -- (a person's name on more than its shape: see names.is_person)
  if #title == 1 and last == 1 and names.is_person(cand, table.concat(all_text, "\n")) then
    -- the whole page counts here: the title stands below the affiliation,
    -- which is where the front matter above was cut off
    local page, sizes = {}, {}
    for _, l in ipairs(lines) do
      local t = trim(l.text)
      if t ~= "" and not l.rotated and not t:find("^%d+$") then
        if any(t:lower(), STOP) then break end
        page[#page + 1] = l
        sizes[#sizes + 1] = l.size
      end
    end
    table.sort(sizes)
    local text_size = sizes[(#sizes + 1) // 2] or 0 -- the median: what the page's prose is set in
    local best, at, by = 0, nil, false
    for i = 2, math.min(#page, 16) do
      if M.byline(page[i].text) then by = true end
      if page[i].size > best then best, at = page[i].size, i end
    end
    if at and not by and best >= text_size + 2 then
      local parts = {}
      for i = at, #page do
        if math.abs(page[i].size - best) > 0.5 then break end
        parts[#parts + 1] = trim(page[i].text)
      end
      local under = table.concat(parts, " "):gsub("%s+", " "):gsub("^[ .,]+", ""):gsub("[ .,]+$", "")
      local ulow = under:lower()
      if ulow:find("%a") and not names.is_person(under) and not names.never(under) and not any(ulow, PUBLISHER)
        and not JUNK[ulow] and not names.is_affiliation(under) and not under:find("^%a+ %d+, %d%d%d%d$") then
        r.title, r.authors, r.name_first = under, { names.clean(cand) }, true
        r.title_math = with_math(parts, page)
        return r
      end
    end
  end

  local author_lines = {}
  -- a by-line under the title says who wrote it outright: "by A. Name", or
  -- "by" alone with the names on the next line
  for i = last + 1, math.min(#body, last + 10) do
    local named = M.byline(body[i].text)
    if named == "" and body[i + 1] then
      local under = trim(body[i + 1].text):gsub("[%*†‡§¶]", "")
      if under:find("^[%u\128-\255]") and #under < 100 and not any(under:lower(), PUBLISHER) then
        author_lines[1] = uninvert(under)
        -- several authors may run over the lines that follow
        for k = i + 2, #body do
          local t = trim(body[k].text)
          if any(t:lower(), PUBLISHER) or not (names.looks_like_authors(t) or body[k].super) then break end
          author_lines[#author_lines + 1] = t
        end
      end
      break
    elseif named and named ~= "" then
      author_lines[1] = named
      break
    end
  end
  if #author_lines > 0 and #names.validate(author_lines) > 0 then
    r.byline = true
  else
    author_lines = {}
    for i = last + 1, #body do
      local t = trim(body[i].text)
      if any(t:lower(), PUBLISHER) then break end
      if names.looks_like_authors(t) or body[i].super then
        author_lines[#author_lines + 1] = t
      elseif #author_lines > 0 then
        break
      end
    end
  end
  r.authors = names.validate(author_lines)
  if #r.authors == 0 and #named > 0 then
    for i, t in ipairs(named) do named[i] = bullets(t):gsub("|", ", ") end
    r.authors = names.validate(named)
  end
  -- Names on a page of series boilerplate with no title of its own are the
  -- series editors, not the authors.
  if not r.title then
    for _, l in ipairs(body) do
      if any(l.text:lower(), EDITORS) then
        r.authors = {}
        break
      end
    end
  end
  return r
end

--- Returns the blocks of a page that could be its title, for choosing
-- between them by hand: runs of consecutive lines set in one size (within
-- half a point), each read as one line, largest type first. A line that is
-- a person's name, a list of people, a series' name or a by-line ends a
-- run and is left out. Left out too: a block longer than a title runs (12
-- words), a sentence, a publisher, a page number, a lone short word.
-- @tparam {table,...} lines a page's lines, as `lulibre.lines` gives them
-- @treturn {string,...}
function M.blocks(lines)
  local everything = {}
  for _, l in ipairs(lines) do everything[#everything + 1] = l.text end
  everything = table.concat(everything, "\n")
  local function people(t)
    return names.is_person(t, everything) or #names.validate { (bullets(t):gsub("|", ", ")) } >= 2
  end
  local runs, run = {}, nil
  for _, l in ipairs(lines) do
    local t = trim(l.text)
    if t ~= "" and not l.rotated and not t:find("^%d+$") then
      if any(t:lower(), STOP) then break end
      if people(t) or series_of(t) or M.byline(t) then
        run = nil
      elseif run and math.abs(run.size - l.size) <= 0.5 and #run.parts < 4 then
        run.parts[#run.parts + 1] = t
      else
        run = { size = l.size, parts = { t }, at = #runs + 1 }
        runs[#runs + 1] = run
      end
    end
  end
  table.sort(runs, function(a, b) if a.size ~= b.size then return a.size > b.size end return a.at < b.at end)
  local out, seen = {}, {}
  for _, r in ipairs(runs) do
    local text = table.concat(r.parts, " "):gsub("%s+", " "):gsub("^[ .,]+", ""):gsub("[ ,]+$", "")
    local low = text:lower()
    local words = select(2, text:gsub("%S+", ""))
    local sentence = words > 6 and text:find("%l%.$") ~= nil
    -- (a fragment of running text starts in lower case; a price or a page
    -- count is mostly figures and stops)
    local letters = select(2, text:gsub("%a", ""))
    local fragment = text:find("^%l") ~= nil or letters < #text / 2
    if words >= 1 and words <= 12 and not sentence and not fragment and low:find("%a") and not seen[low]
      and not (words == 1 and #text <= 3) and not any(low, PUBLISHER) and not JUNK[low]
      and not names.is_affiliation(text) then
      seen[low] = true
      out[#out + 1] = (text:gsub("[ .]+$", ""))
    end
  end
  return out
end

--- Does what `classify` does, trying several pages in turn, since scanned
-- books often start with a blank page or a cover. The first page with a
-- title wins, and the subject may come from any page.
-- @tparam {{table,...},...} pages each page's lines
-- @treturn table as `classify`
function M.classify_pages(pages)
  local best
  for _, lines in ipairs(pages) do
    local r = M.classify(lines)
    if not best then best = r end
    if not best.subject and r.subject then best.subject, best.subject_source = r.subject, r.subject_source end
    if not best.arxiv and r.arxiv then best.arxiv, best.class = r.arxiv, r.class end
    if not best.title and r.title then
      best.title, best.authors, best.byline, best.name_first = r.title, r.authors, r.byline, r.name_first
      best.title_math = r.title_math
    end
    if best.title then break end
  end
  return best or { authors = {} }
end

-- label -> what it gives, and how many lines its value may run to
local STACKED = { ["item type"] = { "type", 1 }, ["authors"] = { "authors", 12 }, ["author"] = { "authors", 12 },
  ["publisher"] = { "publisher", 1 }, ["journal"] = { "journal", 1 }, ["rights"] = { "rights", 1 },
  ["download date"] = { "downloaded", 1 }, ["link to item"] = { "url", 1 }, ["permalink"] = { "url", 1 },
  ["citation"] = { "citation", 1 }, ["title"] = { "title", 3 }, ["item license"] = { "license", 1 },
  ["issn"] = { "issn", 1 }, ["publication date"] = { "date", 1 }, ["doi"] = { "doi", 1 } }

local function stacked(text)
  local got, first, n = {}, nil, 0
  local i = 1
  while i <= #text do
    local label = STACKED[text[i]:lower()]
    if label and text[i + 1] and text[i + 1] ~= "" and not STACKED[text[i + 1]:lower()] then
      local key, most, value = label[1], label[2], {}
      local j = i + 1
      while text[j] and text[j] ~= "" and not STACKED[text[j]:lower()] and #value < most do
        value[#value + 1] = text[j]
        j = j + 1
      end
      got[key] = got[key] or value
      first = first or i
      n = n + 1
      i = j
    else
      i = i + 1
    end
  end
  if not got.authors or n < 3 then return nil end
  -- "Epstein, Samuel D.; Kitahara, Hisatsugu", or one to a line: family name first
  local people = {}
  for _, line in ipairs(got.authors) do
    for who in (line .. ";"):gmatch("%s*([^;]+);") do
      local family, given = who:match("^([^,]+),%s*(.+)$")
      people[#people + 1] = family and (given .. " " .. family) or who
    end
  end
  local one = function(key) return got[key] and got[key][1] or nil end
  local out = { authors = people, labels = n, url = one("url"),
    -- "Physical Review E, 106(4)": the journal, without its volume and issue
    journal = one("journal") and one("journal"):gsub(",?%s*%d+%s*%b()$", ""):gsub(",?%s*[Vv]ol%a*%.?%s*%d+.*$", "") or nil,
    publisher = one("publisher") and one("publisher"):gsub("%s*%b()$", ""):gsub("%s*%.$", "") or nil,
    year = one("date") and one("date"):match("^(%d%d%d%d)") or nil,
    doi = one("doi") and one("doi"):match("^(10%.%d+/%S+)$") or nil }
  if got.title then
    out.title = table.concat(got.title, " ")
  else
    -- the title stands above the labels
    local parts = {}
    for k = 1, (first or 1) - 1 do
      if text[k] ~= "" then parts[#parts + 1] = text[k] end
    end
    if #parts > 0 and #parts <= 3 then out.title = table.concat(parts, " ") end
  end
  return out
end

--- Reads a cover sheet's labelled facts. JSTOR and other archives put
-- "Label: value" lines in front of an article:
--
--    What is an Answer?
--    Author(s): Herbert S. Wilf
--    Source: The American Mathematical Monthly, Vol. 89, No. 5 (May, 1982), pp. 289-292
--    Published by: Mathematical Association of America
--    Stable URL: http://www.jstor.org/stable/2321713
--
-- A university's repository puts each label on its own line, with the
-- value below it:
--
--    Unifying Labeling under Minimal Search ...
--    Item Type
--    Article; text
--    Authors
--    Epstein, Samuel D.; Kitahara, Hisatsugu; Seely, T. Daniel
--    Publisher
--    University of Arizona Linguistics Circle (Tucson, Arizona)
--    Journal
--    Coyote Papers
--
-- @tparam {table|string,...} lines a page's lines, from `lulibre.lines` or as text
-- @treturn table|nil nil if the page has no author label. Otherwise `{ title=, authors=, year=,
-- source=, publisher=, journal=, url=, jstor=, labels= }` with what was found. `labels` counts
-- the labelled lines, which shows how reliable the result is.
function M.labelled(lines)
  local text = {}
  for i, l in ipairs(lines or {}) do
    text[i] = (type(l) == "table" and l.text or l or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if i >= 40 then break end
  end
  local at, who
  for i, t in ipairs(text) do
    who = t:match("^[Aa]uthor%(?s?%)?%s*:%s*(.+)$") or t:match("^AUTHOR%(?S?%)?%s*:%s*(.+)$")
    if who then
      at = i
      break
    end
  end
  if not at then return stacked(text) end
  local out = { authors = names.split(who), labels = 1 }
  -- the title is what stands above the author line, when that is only a line or three
  local above = {}
  if at > 1 and at <= 4 then
    for i = 1, at - 1 do
      if text[i] ~= "" and not text[i]:find("^%a[%a ()]-:%s") then above[#above + 1] = text[i] end
    end
  end
  for i = at + 1, math.min(#text, at + 12) do
    local t = text[i]
    local source = t:match("^Source:%s*(.+)$")
    local publisher = t:match("^Published [Bb]y:%s*(.+)$") or t:match("^Publisher:%s*(.+)$")
    local url = t:match("^Stable URL:%s*(%S+)") or t:match("^URL:%s*(%S+)")
    if source then
      out.source, out.labels = source, out.labels + 1
      for y in source:gmatch("%f[%d](%d%d%d%d)%f[%D]") do
        if tonumber(y) >= 1500 and tonumber(y) <= 2099 then out.year = y end
      end
    elseif publisher then
      out.publisher, out.labels = publisher:gsub("%s*%.$", ""), out.labels + 1
    elseif url then
      out.url, out.labels = url:gsub("[.,]$", ""), out.labels + 1
      out.jstor = url:match("jstor%.org/stable/([%w./-]-)[.,]?$")
    end
  end
  -- (a sheet may be headed with the journal's name, above the title: "Annals of
  -- Mathematics", the source being "Annals of Mathematics, Second Series, ...")
  local journal = out.source and out.source:match("^([^,]+)")
  while #above > 1 do
    local low = lulibre.fold(above[1])
    if (journal and low == lulibre.fold(journal)) or (out.publisher and low == lulibre.fold(out.publisher)) then
      table.remove(above, 1)
    else
      break
    end
  end
  if #above > 0 then out.title = table.concat(above, " ") end
  return out
end

--- Reads a thesis or dissertation cover page by rule, following Choudhury,
-- Wu, Ingram and Fox, "A Heuristic Baseline Method for Metadata Extraction
-- from Scanned Electronic Theses and Dissertations" (JCDL 2020,
-- doi:10.1145/3383583.3398590). Thesis covers follow a template, so plain
-- text patterns work well. The patterns need no font sizes, which a page
-- read by OCR does not have:
--
-- - `title`: the lines above "by"
-- - `author`: what follows "by", on that line or the next
-- - `degree`: after "degree of"
-- - `program`: after "department of", or "in" after the degree
-- - `institution`: after "at the" or "faculty of (the)", or else the line
--   naming a university, institute or college
-- - `year`: four digits, preferring a line that names a month
-- - `advisor`: after "certified by", "approved", "supervisor" or "advisor"
--
-- @tparam {table|string,...} lines
-- @treturn table|nil the fields found, or nil if the page is not a thesis cover
function M.thesis(lines)
  local text, low = {}, {}
  for _, l in ipairs(lines or {}) do
    local t = (type(l) == "table" and l.text or l or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if t ~= "" then
      text[#text + 1] = t
      low[#low + 1] = t:lower()
    end
    if #text >= 45 then break end
  end
  local all = table.concat(low, "\n")
  if not (all:find("thesis") or all:find("dissertation")) then return nil end
  if not (all:find("degree of") or all:find("requirements for") or all:find("submitted to")
      or all:find("submitted in") or all:find("presented to")) then
    return nil
  end
  local out = {}
  local function boilerplate(t)
    return t:find("thesis") or t:find("dissertation") or t:find("submitted") or t:find("presented to")
      or t:find("requirements") or t:find("degree of") or t:find("fulfil")
  end
  local function school(t)
    return t:find("universit") or t:find("institute of") or t:find("college") or t:find("^school of")
      or t:find("polytechnic")
  end

  -- title and author, either side of "by"
  for i, t in ipairs(low) do
    local same = text[i]:match("^[Bb][Yy]%s+(%u.+)$")
    if t == "by" or same then
      local who = same or text[i + 1]
      if who and not boilerplate(who:lower()) and #who < 80 then out.authors = names.split(who) end
      local parts = {}
      for k = 1, i - 1 do
        if not boilerplate(low[k]) and not school(low[k]) and #parts < 5 then parts[#parts + 1] = text[k] end
      end
      if #parts > 0 then out.title = table.concat(parts, " ") end
      break
    end
  end

  for i, t in ipairs(low) do
    local at = t:find("degree of", 1, true)
    if at and not out.degree then
      local rest = text[i]:sub(at + 9):gsub("^%s+", "")
      if rest == "" then rest = text[i + 1] or "" end
      local degree, program = rest:match("^(.-)%s+in%s+(.+)$")
      out.degree = (degree or rest):gsub("[%s.,]+$", "")
      if program and not out.program then out.program = program:gsub("[%s.,]+$", "") end
    end
    local dept = text[i]:match("[Dd][Ee][Pp][Aa][Rr][Tt][Mm][Ee][Nn][Tt] [Oo][Ff]%s+([^,]+)")
    if dept and not out.program then out.program = dept:gsub("[%s.]+$", "") end
    if not out.institution then
      local place = text[i]:match("[Aa]t [Tt]he%s+(%u.+)$") or text[i]:match("[Ff]aculty [Oo]f [Tt]he%s+(%u.+)$")
        or text[i]:match("[Ff]aculty [Oo]f%s+(%u.+)$")
      if not place and (low[i]:find("at the$") or low[i]:find("faculty of the$") or low[i]:find("faculty of$")) then
        place = text[i + 1] -- the name starts the next line
      end
      if place and school(place:lower()) then out.institution = place:gsub("[%s.,]+$", "") end
    end
    local guide = text[i]:match("[Cc]ertified [Bb]y:?%s*(.*)$") or text[i]:match("[Aa]pproved:?%s*[Bb]?y?:?%s*(.*)$")
      or text[i]:match("[Ss]upervisor:?%s*(.*)$") or text[i]:match("[Aa]dvisor:?%s*(.*)$")
    if guide and not out.advisor then
      if guide == "" or not guide:find("%a%a") then guide = text[i + 1] or "" end
      guide = guide:gsub("^[%s._:-]+", ""):gsub("[%s._,-]+$", "")
      if guide:find("%u%l") and #guide < 70 then out.advisor = guide end
    end
  end
  if not out.institution then
    -- the last line that names a school and nothing else: an earlier one is
    -- as likely where the author's first degree came from
    for i, t in ipairs(low) do
      if school(t) and not t:find("department") and not t:find("%d") and #text[i] < 70 then
        out.institution = text[i]:gsub("[%s.,]+$", "")
      end
    end
  end

  local months = { "january", "february", "march", "april", "may", "june", "july", "august", "september",
    "october", "november", "december" }
  local fallback
  for _, t in ipairs(low) do
    for y in t:gmatch("%f[%d](%d%d%d%d)%f[%D]") do
      if tonumber(y) >= 1850 and tonumber(y) <= 2099 then
        fallback = y
        for _, m in ipairs(months) do
          if t:find(m, 1, true) or t:find(m:sub(1, 3) .. "%.") then out.year = out.year or y end
        end
      end
    end
  end
  out.year = out.year or fallback
  return out
end

return M
