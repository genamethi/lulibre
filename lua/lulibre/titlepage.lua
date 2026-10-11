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

--- lines: as from lulibre.lines(id). Returns
-- { arxiv=, class=, subject=, title=, authors={...}, subject_source= }.
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
    if l.size >= max - 0.5 then
      title[#title + 1] = trim(l.text)
      last = i
    elseif #title > 0 then
      break
    end
  end
  local cand = table.concat(title, " "):gsub("%s+", " "):gsub("^[ .,]+", ""):gsub("[ .,]+$", "")
  local low = cand:lower()
  if cand ~= "" and low:find("%a") and not any(low, PUBLISHER) and not JUNK[low] then r.title = cand end

  local author_lines = {}
  for i = last + 1, #body do
    local t = trim(body[i].text)
    if any(t:lower(), PUBLISHER) then break end
    if names.looks_like_authors(t) or body[i].super then
      author_lines[#author_lines + 1] = t
    elseif #author_lines > 0 then
      break
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
      best.title, best.authors = r.title, r.authors
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

return M
