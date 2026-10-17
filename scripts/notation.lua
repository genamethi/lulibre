-- Propose the selected books' titles with their mathematics in Unicode:
-- SL2(Z) as SL₂(ℤ), GLn(Qp) as GLₙ(ℚₚ), X3 −5 as X³ − 5 (lulibre.notation).
-- Changes nothing by itself: go through the proposals with :review.
--   :notation                 the selection
--   :notation author:conrad   every book matching a filter
-- A PDF whose title page has the same title is read again for its type:
-- what is set smaller and higher or lower, and in which font, says what
-- the plain text lost. A title the pages do not give is read by the
-- glossary alone, which changes only what reads one way.
local notation = require "lulibre.notation"
local titlecase = require "lulibre.titlecase"
local titlepage = require "lulibre.titlepage"

local filter = table.concat({ ... }, " ")
local ids = (lulibre.headless or filter ~= "") and lulibre.ids(filter) or lulibre.selection()

-- the letters of a title, for telling whether the page has the same one
local function letters(s) return (lulibre.fold(s or ""):gsub("[^%w]", "")) end

-- the title as the book's own pages set it, marked up, when they give this title
local function from_pages(id, title)
  for _, f in ipairs(lulibre.files(id)) do
    if f.format == "PDF" and f.path then
      local d = lulibre.extract(f.path, { pages = 2, layout_pages = 2 })
      if d and d.page then
        local pages = {}
        for i, p in ipairs(d.page) do pages[i] = p.lines end
        local tp = titlepage.classify_pages(pages)
        if tp.title_math and letters(tp.title) == letters(title) then return tp.title_math end
      end
    end
  end
  return nil
end

local proposals = require "lulibre.proposals"
local added, read = 0, 0
for n, id in ipairs(ids) do
  local book = lulibre.book(id)
  local title = book and book.title or ""
  if title ~= "" then
    local marked = from_pages(id, title)
    local value, source, confidence
    if marked then
      read = read + 1
      value, source, confidence = notation.title(marked, titlecase.proposed), "notation, from the title page", 0.8
    else
      value, source, confidence = notation.title(title), "notation", 0.6
    end
    if value ~= title and proposals.add(id, "title", value, { source = source, confidence = confidence, as_is = true }) then
      added = added + 1
    end
  end
  if n % 25 == 0 then lulibre.progress(("notation %d/%d"):format(n, #ids)) end
end
lulibre.progress(nil)
print(("%d title%s proposed with notation in Unicode (%d read from the title page); %s goes through them"):format(
  added, added == 1 and "" or "s", read, lulibre.hint("review")))
