-- Look books up online and propose what the record says: arXiv for books
-- with an arXiv id, CrossRef for books with a DOI. The id may already be in
-- calibre or be found in the file. Nothing is changed; :review decides.
--   :run enrich                the selection
--   :run enrich FILTER         books matching a filter
--   :run enrich --titles ...   also search CrossRef by title when there is no id
local edit = require "lulibre.edit"
local extract = require "lulibre.extract"
local net = require "lulibre.net"
local proposals = require "lulibre.proposals"
local taxonomy = require "lulibre.taxonomy"

local words, by_title = {}, false
for _, a in ipairs({ ... }) do
  if a == "--titles" then by_title = true else words[#words + 1] = a end
end
local filter = table.concat(words, " ")
local ids = (lulibre.headless or filter ~= "") and lulibre.ids(filter) or lulibre.selection()

local added, looked, found = 0, 0, 0
local function propose(id, field, value, source, op)
  if value and value ~= "" and proposals.add(id, field, value, { op = op, source = source, confidence = 0.95 }) then
    added = added + 1
  end
end

for n, id in ipairs(ids) do
  local book = lulibre.book(id)
  local arxiv, doi = book.idents.arxiv, book.idents.doi
  if not arxiv or not doi then
    for _, c in ipairs(extract.candidates(id)) do
      if c.field == "identifiers" then
        arxiv = arxiv or c.value:match("^arxiv:(.+)")
        doi = doi or c.value:match("^doi:(.+)")
      end
    end
  end
  lulibre.progress(("looking up %d/%d"):format(n, #ids))
  local rec, source
  if arxiv then
    looked = looked + 1
    rec, source = net.arxiv(arxiv), "arXiv " .. arxiv
    lulibre.sleep(350) -- arXiv asks for no more than a few requests a second
    if rec then
      propose(id, "identifiers", "arxiv:" .. arxiv, source, "add")
      propose(id, "tags", taxonomy.from_arxiv(rec.class), source, "add")
    end
  end
  if not rec and doi then
    looked = looked + 1
    rec, source = net.crossref(doi), "CrossRef " .. doi
    lulibre.sleep(100)
    if rec then propose(id, "identifiers", "doi:" .. doi, source, "add") end
  end
  if not rec and by_title and book.title and #book.title >= 20 then
    looked = looked + 1
    rec, source = net.crossref_search(book.title), "CrossRef title search"
    lulibre.sleep(200)
    if rec and rec.doi then propose(id, "identifiers", "doi:" .. rec.doi, source, "add") end
  end
  if rec then
    found = found + 1
    propose(id, "title", rec.title, source)
    if #rec.authors > 0 then propose(id, "authors", table.concat(rec.authors, " & "), source) end
    if rec.year and edit.current(book, "pubdate") == "" then propose(id, "pubdate", tostring(rec.year), source) end
    if rec.publisher and edit.current(book, "publisher") == "" then propose(id, "publisher", rec.publisher, source) end
  end
end
lulibre.progress(nil)
print(("%d books: %d looked up, %d found, %d proposals; :review goes through them"):format(#ids, looked, found, added))
