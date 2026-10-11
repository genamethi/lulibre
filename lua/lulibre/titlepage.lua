-- Read a title page the way a person does: by the role of each line. Works on
-- the tagged lines the index keeps (text, font size, superscript, rotation).
--
--   subject   the arXiv class in the margin stamp, else the MSC footnote
--   title     the run of largest-font lines above the authors
--   authors   the lines under the title that read as names, up to the
--             abstract or the first affiliation
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
local STOP = { "^abstract", "^contents", "^introduction", "^keywords", "^r[e\195]\169?sum" }
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

-- words that may stand in lower case inside a name
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

--- Is the line a by-line? Returns the names on it ("by A. Name" gives
-- "A. Name"), "" for "by" standing alone above the names, or nil. A
-- sentence that happens to begin with "by" is told apart by its length, its
-- lower-case words, and brackets or figures in it.
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

--- lines: as from lulibre.lines(id). Returns
-- { arxiv=, class=, subject=, title=, authors={...}, subject_source=,
--   byline=, name_first= } (byline: the authors were named by a "by" line,
-- which is the page's own word for it; name_first: the page opens with the
-- author's name and has its title further down).
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

  local max = 0
  for _, l in ipairs(body) do max = math.max(max, l.size) end
  local title, last = {}, 0
  for i, l in ipairs(body) do
    -- a by-line set as large as the title ends the title; it is not part of it
    if M.byline(l.text) then
      if #title > 0 then break end
    elseif l.size >= max - 0.5 then
      title[#title + 1] = trim(l.text)
      last = i
    elseif #title > 0 then
      break
    end
  end
  local cand = table.concat(title, " "):gsub("%s+", " "):gsub("^[ .,]+", ""):gsub("[ .,]+$", "")
  local low = cand:lower()
  if cand ~= "" and low:find("%a") and not any(low, PUBLISHER) and not JUNK[low] then r.title = cand end

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

--- The same, trying each of several pages in turn (scanned books often open
-- on a blank or a cover): the first page that yields a title wins, and the
-- subject may come from any of them.
function M.classify_pages(pages)
  local best
  for _, lines in ipairs(pages) do
    local r = M.classify(lines)
    if not best then best = r end
    if not best.subject and r.subject then best.subject, best.subject_source = r.subject, r.subject_source end
    if not best.arxiv and r.arxiv then best.arxiv, best.class = r.arxiv, r.class end
    if not best.title and r.title then
      best.title, best.authors, best.byline, best.name_first = r.title, r.authors, r.byline, r.name_first
    end
    if best.title then break end
  end
  return best or { authors = {} }
end

--- What a cover sheet states outright, in "Label: value" lines, as the
-- sheets JSTOR and other archives put in front of an article do:
--
--   What is an Answer?
--   Author(s): Herbert S. Wilf
--   Source: The American Mathematical Monthly, Vol. 89, No. 5 (May, 1982), pp. 289-292
--   Published by: Mathematical Association of America
--   Stable URL: http://www.jstor.org/stable/2321713
--
-- Returns nil when the page has no author label, else { title=, authors=,
-- year=, source=, publisher=, url=, jstor=, labels= } with whatever was
-- found; labels counts the labelled lines, which is how sure one can be.
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
  if not at then return nil end
  local out = { authors = names.split(who), labels = 1 }
  -- the title is what stands above the author line, when that is only a line or three
  if at > 1 and at <= 4 then
    local parts = {}
    for i = 1, at - 1 do
      if text[i] ~= "" and not text[i]:find("^%a[%a ()]-:%s") then parts[#parts + 1] = text[i] end
    end
    if #parts > 0 then out.title = table.concat(parts, " ") end
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
  return out
end

--- A thesis or dissertation cover page, read by rule: the approach of
-- Choudhury, Wu, Ingram and Fox, "A Heuristic Baseline Method for Metadata
-- Extraction from Scanned Electronic Theses and Dissertations" (JCDL 2020,
-- doi:10.1145/3383583.3398590). Such covers follow a template, so plain
-- patterns on the text do well, and they need no font sizes, which a page
-- read by OCR does not have:
--
--   title        the lines above "by"
--   author       what follows "by", on that line or the next
--   degree       after "degree of"
--   program      after "department of", or "in" after the degree
--   institution  after "at the" or "faculty of (the)", else the line naming
--                a university, institute or college
--   year         four digits, preferring a line that names a month
--   advisor      after "certified by", "approved", "supervisor", "advisor"
--
-- Returns nil unless the page reads like a thesis cover, else a table with
-- whichever of those were found.
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
