-- Propose metadata for books that lack it, from what their files say.
-- Changes nothing by itself: go through the proposals with :review.
--   :run propose                  the selection
--   :run propose author:unknown   every book matching a filter
--   lulibre run propose 'tag:none fmt:pdf'
local edit = require "lulibre.edit"
local extract = require "lulibre.extract"
local junk = require "lulibre.junk"
local proposals = require "lulibre.proposals"

local filter = table.concat({ ... }, " ")
local ids = (lulibre.headless or filter ~= "") and lulibre.ids(filter) or lulibre.selection()

local added, books = 0, 0
for n, id in ipairs(ids) do
  local book = lulibre.book(id)
  local before = added
  local best = {} -- one value per single-valued field: candidates come strongest first
  for _, c in ipairs(extract.candidates(id)) do
    local cur = edit.current(book, c.field)
    local op, want = "set", false
    if c.field == "authors" then
      want = cur == "" and not best.authors
    elseif c.field == "title" then
      want = (junk.title(cur) or not cur:find("%s")) and not best.title
    elseif c.field == "pubdate" then
      want = cur == "" and not best.pubdate
    elseif c.field == "tags" then
      -- a stated subject (arXiv class, MSC) is worth adding; vocabulary only fills a gap
      want = cur == "" and (c.confidence >= 0.9 or not best.tags)
      op = "add"
    elseif c.field == "identifiers" then
      want, op = true, "add"
    end
    if want then
      best[c.field] = true
      if proposals.add(id, c.field, c.value, { op = op, source = c.source, confidence = c.confidence }) then
        added = added + 1
      end
    end
  end
  if added > before then books = books + 1 end
  if n % 25 == 0 then lulibre.progress(("proposing %d/%d"):format(n, #ids)) end
end
lulibre.progress(nil)
print(("%d proposals for %d of %d books; :review goes through them"):format(added, books, #ids))
