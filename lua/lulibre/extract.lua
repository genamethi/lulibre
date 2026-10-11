-- Everything lulibre can infer about a book from its file, as candidates:
-- { field=, value=, source=, confidence= }. Nothing here changes the library;
-- candidates are for showing, ranking and (once accepted) applying.
local ids = require "lulibre.ids"
local junk = require "lulibre.junk"
local names = require "lulibre.names"
local subjects = require "lulibre.subjects"
local titlepage = require "lulibre.titlepage"

local titlecase = require "lulibre.titlecase"
local M = {}

local function join(list)
  return table.concat(list, " & ")
end

--- Candidates from what a file contains. doc is
-- { path=, title=, author=, pages={ lines, lines, ... }, text= }: the
-- embedded title and author, the tagged lines of the leading pages (or
-- lines= for page 1 alone), and the text of those pages.
function M.from_doc(doc)
  local out = {}
  local function add(field, value, source, confidence)
    -- a title set in capitals is offered in title case (option title_case)
    if field == "title" and value then value = titlecase.proposed(value) end
    if value and value ~= "" then
      out[#out + 1] = { field = field, value = value, source = source, confidence = confidence }
    end
  end

  -- what the file says about itself
  if doc.title and not junk.title(doc.title) then add("title", doc.title, "embedded", 0.6) end
  if doc.author and not junk.author(doc.author) then
    add("authors", join(names.split(doc.author)), "embedded", 0.6)
  end

  -- a cover sheet that labels its fields is the best witness there is
  local lab = titlepage.labelled(doc.pages and doc.pages[1] or doc.lines)
  if lab then
    local sure, less = 0.85, 0.8
    if lab.labels >= 2 then sure, less = 0.95, 0.9 end
    local people = {}
    for i, a in ipairs(lab.authors) do people[i] = names.titlecase(a) end
    add("authors", join(people), "cover sheet", sure)
    if lab.title and not junk.title(lab.title) then add("title", lab.title, "cover sheet", sure) end
    if lab.year then add("pubdate", lab.year, "cover sheet", less) end
    if lab.publisher then add("publisher", lab.publisher, "cover sheet", less) end
    if lab.jstor then add("identifiers", "jstor:" .. lab.jstor, "cover sheet", sure) end
  end

  -- a thesis cover follows a template, which also survives OCR
  local th = titlepage.thesis(doc.pages and doc.pages[1] or doc.lines)
  if th then
    if th.authors and #th.authors > 0 then
      local people = {}
      for i, a in ipairs(th.authors) do people[i] = names.titlecase(a) end
      add("authors", join(people), "thesis cover", 0.8)
    end
    if th.title and not junk.title(th.title) then add("title", names.title_caps(th.title), "thesis cover", 0.75) end
    if th.year then add("pubdate", th.year, "thesis cover", 0.75) end
    if th.institution then add("publisher", th.institution, "thesis cover", 0.7) end
  end

  -- the title page
  local tp = doc.pages and titlepage.classify_pages(doc.pages) or titlepage.classify(doc.lines or {})
  local conf = tp.arxiv and 0.85 or 0.55
  if tp.title and not junk.title(tp.title) then
    add("title", names.title_caps(tp.title), "title page", conf)
  end
  if #tp.authors > 0 then
    local people = {}
    for i, a in ipairs(tp.authors) do people[i] = names.titlecase(a) end
    add("authors", join(people), "title page", conf)
  end
  if tp.subject then add("tags", tp.subject, tp.subject_source, 0.9) end

  -- identifiers anywhere in the leading pages
  local text = doc.text or ""
  local arxiv = tp.arxiv or ids.arxiv(text, doc.path)
  if arxiv then
    add("identifiers", "arxiv:" .. arxiv, "arXiv id", 0.95)
    local year = ids.arxiv_year(arxiv)
    if year then add("pubdate", tostring(year), "arXiv id", 0.9) end
  end
  local doi = ids.doi(text)
  if doi then add("identifiers", "doi:" .. doi, "page text", 0.8) end
  local isbn = ids.isbn(text)
  if isbn then add("identifiers", "isbn:" .. isbn, "page text", 0.85) end

  -- subject from vocabulary, when the page did not state one
  local ranked = subjects.score((tp.title or "") .. "\n" .. text)
  for i = 1, math.min(2, #ranked) do
    local s = ranked[i]
    if s.score >= 4 then
      add("tags", s.subject, ("vocabulary (%d)"):format(s.score), math.min(0.75, 0.3 + s.score / 60))
    end
  end

  table.sort(out, function(a, b)
    if a.field ~= b.field then return a.field < b.field end
    return a.confidence > b.confidence
  end)
  return out
end

--- Candidates for a book in the library, from the index.
function M.candidates(id)
  local file = lulibre.files(id)[1]
  if not file then return {} end
  local pages = {}
  for n = 1, 4 do
    local lines = lulibre.lines(id, n)
    if #lines == 0 and n > 1 then break end
    pages[#pages + 1] = lines
  end
  return M.from_doc {
    path = file.path, title = file.title, author = file.author, pages = pages, text = lulibre.text(id),
  }
end

return M
