-- Everything lulibre can infer about a book from its file, as candidates:
-- { field=, value=, source=, confidence= }. Nothing here changes the library;
-- candidates are for showing, ranking and (once accepted) applying.
local ids = require "lulibre.ids"
local junk = require "lulibre.junk"
local names = require "lulibre.names"
local subjects = require "lulibre.subjects"
local titlepage = require "lulibre.titlepage"

local titlecase = require "lulibre.titlecase"
local edit = require "lulibre.edit"
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
  -- How often a person's name stands in the leading pages: in an e-mail
  -- address or a running head as well as on the title line, say. A name the
  -- page gives twice is less likely to be a misreading of one line.
  local flat
  local function times(name)
    if not flat then flat = " " .. lulibre.fold(doc.text or ""):gsub("[^%w]+", " ") .. " " end
    local needle = " " .. lulibre.fold(name):gsub("[^%w]+", " "):gsub("^ ", ""):gsub(" $", "") .. " "
    local n, from = 0, 1
    while true do
      local a, b = flat:find(needle, from, true)
      if not a then break end
      n, from = n + 1, b -- the closing space may open the next match
    end
    return n
  end
  local function add(field, value, source, confidence)
    -- a title set in capitals is offered in title case (option title_case)
    if field == "title" and value then value = titlecase.proposed(value) end
    if field == "authors" and value then
      -- ranks, roles and whatever the option never_authors lists are not people
      local people, twice = {}, true
      for _, a in ipairs(edit.split("authors", value)) do
        if not names.never(a) then
          people[#people + 1] = a
          -- (only for what reads as a person on more than its shape: a title
          -- phrase mistaken for a name repeats through the text too)
          if times(a) < 2 or not names.is_person(a, doc.text) then twice = false end
        end
      end
      value = join(people)
      if #people > 0 and twice and source ~= "embedded" and source ~= "cover sheet" then
        source, confidence = source .. ", named twice", math.min(0.9, confidence + 0.15)
      end
      -- and one who heads entries of the book's own bibliography (people
      -- cite themselves), where the bibliography has been read (:refs)
      if #people > 0 and doc.id and (source:find("title page", 1, true) or source:find("first line", 1, true)) then
        local ok, n = pcall(function() return require("lulibre.refs").cites(doc.id, people[1]) end)
        if ok and n >= 2 then
          source, confidence = ("%s, cited %d times in its references"):format(source, n), math.min(0.9, confidence + 0.1)
        end
      end
    end
    if value and value ~= "" then
      out[#out + 1] = { field = field, value = value, source = source, confidence = confidence }
    end
  end

  -- pages laid out in a known way say their facts outright (layouts.lua)
  if doc.texts then
    for _, c in ipairs(require("lulibre.layouts").read(doc)) do add(c.field, c.value, c.source, c.confidence) end
  end

  -- what the file says about itself (in Latin-1, as old PDFs write it, when it is not UTF-8)
  local function text_of(v)
    if type(v) ~= "string" or utf8.len(v) then return v end
    return (v:gsub("[\128-\255]", function(c) return utf8.char(c:byte()) end))
  end
  local own_title, own_author = text_of(doc.title), text_of(doc.author)
  if own_title and not junk.title(own_title) then add("title", own_title, "embedded", 0.6) end
  if own_author and not junk.author(own_author) then
    add("authors", join(names.split(own_author)), "embedded", 0.6)
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
    add("title", names.title_caps(tp.title), "title page", tp.name_first and math.max(conf, 0.65) or conf)
  end
  if #tp.authors > 0 then
    local people = {}
    for i, a in ipairs(tp.authors) do people[i] = names.titlecase(a) end
    -- "by A. Name" is the page saying who wrote it, not a guess from the layout
    if tp.byline then add("authors", join(people), "by-line", math.max(conf, 0.85))
    elseif tp.name_first then add("authors", join(people), "first line", math.max(conf, 0.7))
    else add("authors", join(people), "title page", conf) end
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
  -- a DOI further down that follows other words on its line, or stands among
  -- the references, is as likely a cited work's: offered, but not vouched for
  local doi, own = ids.doi_in(text)
  if doi then add("identifiers", "doi:" .. doi, own and "page text" or "page text (perhaps a work it cites)", own and 0.8 or 0.5) end
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
  local text, texts = lulibre.text(id), {}
  for page in ((text or "") .. "\f"):gmatch("(.-)\f") do texts[#texts + 1] = page end
  return M.from_doc {
    id = id, path = file.path, title = file.title, author = file.author, pages = pages, text = text, texts = texts,
  }
end

return M
