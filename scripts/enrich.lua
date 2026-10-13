-- Look books up by their identifiers and propose what the record says.
-- Nothing is changed; :review decides.
--   :run enrich                 the selection
--   :run enrich FILTER          the books a filter matches
--   :run enrich --offline ...   only from what was fetched before: nothing is asked
--   :run enrich --titles ...    also search CrossRef by title for books with no identifier
--
-- Who is asked what (the option enrich_services says which of them):
--   arXiv         by arXiv number: title, authors, the day of submission, the subject its class stands for
--   CrossRef      by DOI: title, authors, year, publisher (of a book), ISBN
--   zbMATH Open   by DOI or arXiv number: the subject, from the MSC codes it is classified under
--   Open Library  by ISBN: title, authors, publisher, year, series, the subject its shelf class stands for
--   OpenAlex      by DOI, when CrossRef has nothing
-- An identifier may be in calibre already or be found in the file. Every
-- answer is kept, so each work is asked about once, each service is asked no
-- faster than it wishes, and a run that is stopped loses nothing.
local edit = require "lulibre.edit"
local extract = require "lulibre.extract"
local net = require "lulibre.net"
local proposals = require "lulibre.proposals"
local propose = require "lulibre.propose"

local words, by_title = {}, false
for _, a in ipairs({ ... }) do
  if a == "--titles" then by_title = true
  elseif a == "--offline" then net.offline = true
  else words[#words + 1] = a end
end
local filter = table.concat(words, " ")
local ids = (lulibre.headless or filter ~= "") and lulibre.ids(filter) or lulibre.selection()

local use = {}
for name in (lulibre.o.enrich_services or ""):gmatch("[^,%s]+") do use[name:lower()] = true end

-- what each book goes by
local books = {}
for n, id in ipairs(ids) do
  local book = lulibre.book(id)
  if book then
    local known = { arxiv = book.idents.arxiv, doi = book.idents.doi, isbn = book.idents.isbn }
    if not (known.arxiv and known.doi and known.isbn) then
      for _, c in ipairs(extract.candidates(id)) do
        if c.field == "identifiers" then
          for kind in pairs { arxiv = 1, doi = 1, isbn = 1 } do
            known[kind] = known[kind] or c.value:match("^" .. kind .. ":(.+)")
          end
        end
      end
    end
    books[#books + 1] = { id = id, book = book, known = known }
  end
  if n % 50 == 0 then lulibre.progress(("reading identifiers %d/%d"):format(n, #ids)) end
end

-- arXiv answers for forty numbers at a time, and wants three seconds between
-- requests: ask for them all first
if use.arxiv then
  local numbers = {}
  for _, b in ipairs(books) do
    if b.known.arxiv then numbers[#numbers + 1] = b.known.arxiv end
  end
  if #numbers > 0 then
    lulibre.progress(("asking arXiv about %d papers"):format(#numbers))
    net.arxiv_prefetch(numbers)
  end
end

-- How far each service's word is taken for title, authors and the like. The
-- publisher's own record (CrossRef) and the author's (arXiv) come first;
-- zbMATH writes titles its own way (in sentence case) and is asked for the
-- subject, which it classifies by hand and nobody else does.
local TRUST = { arxiv = 0.95, crossref = 0.95, openlibrary = 0.9, zbmath = 0.85, openalex = 0.85 }

local added, found, replacing = 0, 0, 0
local by_service = {}
for n, b in ipairs(books) do
  lulibre.progress(("looking up %d/%d"):format(n, #books))
  local records = {}
  local function ask(service, fn, ...)
    if not use[service] then return nil end
    local rec = fn(...)
    if rec then
      rec.service = service
      records[#records + 1] = rec
      by_service[service] = (by_service[service] or 0) + 1
    end
    return rec
  end
  local k = b.known
  local ax = k.arxiv and ask("arxiv", net.arxiv, k.arxiv)
  local doi = k.doi or (ax and ax.ids.doi)
  local cr = doi and ask("crossref", net.crossref, doi)
  if doi and not cr then ask("openalex", net.openalex, doi) end
  if doi or k.arxiv then ask("zbmath", net.zbmath, doi and { doi = doi } or { arxiv = k.arxiv }) end
  local isbn = k.isbn or (cr and cr.ids.isbn)
  if isbn then ask("openlibrary", net.openlibrary, isbn) end
  if #records == 0 and by_title and use.crossref and b.book.title and #b.book.title >= 20 then
    ask("crossref", net.crossref_search, b.book.title)
  end

  -- what the records say, as candidates, the surest first within a field
  if #records > 0 then
    found = found + 1
    local cands = {}
    local function offer(field, value, source, confidence)
      if value ~= nil and tostring(value) ~= "" then
        cands[#cands + 1] = { field = field, value = tostring(value), source = source, confidence = confidence }
      end
    end
    for _, r in ipairs(records) do
      local trust = TRUST[r.service] or 0.85
      offer("title", r.title, r.source, trust)
      if #r.authors > 0 then offer("authors", table.concat(r.authors, " & "), r.source, trust) end
      offer("pubdate", r.date or r.year, r.source, r.date and trust or trust - 0.05)
      offer("publisher", r.publisher, r.source, trust - 0.05)
      offer("series", r.series, r.source, 0.85)
      offer("series_index", r.series_index, r.source, 0.85)
      for _, s in ipairs(r.subjects) do offer("tags", s.tag, ("%s (%s)"):format(r.source, s.why), s.confidence) end
      for kind, value in pairs(r.ids) do offer("identifiers", kind .. ":" .. value, r.source, 0.95) end
    end
    table.sort(cands, function(x, y)
      if x.field ~= y.field then return x.field < y.field end
      return (x.confidence or 0) > (y.confidence or 0)
    end)
    for _, w in ipairs(propose.wanted(b.book, cands)) do
      if proposals.add(b.id, w.field, w.value, { op = w.op, source = w.source, confidence = w.confidence }) then
        added = added + 1
        if w.over then replacing = replacing + 1 end
      end
    end
  end
end
lulibre.progress(nil)

local said = {}
for _, name in ipairs { "arxiv", "crossref", "zbmath", "openlibrary", "openalex" } do
  if by_service[name] then said[#said + 1] = ("%s %d"):format(name, by_service[name]) end
end
print(("%d book%s: a record for %d (%s); %d request%s made, %d answers already kept; %d proposal%s%s; %s goes through them"):format(
  #books, #books == 1 and "" or "s", found, #said > 0 and table.concat(said, ", ") or "none",
  net.stats.asked, net.stats.asked == 1 and "" or "s", net.stats.kept, added, added == 1 and "" or "s",
  replacing > 0 and (", %d for a field that has a value"):format(replacing) or "", lulibre.hint("review")))
