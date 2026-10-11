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

return M
