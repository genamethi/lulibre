-- Look books up by their identifiers and propose what the record says.
-- Nothing is changed; :review decides.
--   :run enrich                 the selection
--   :run enrich FILTER          the books a filter matches
--   :run enrich --offline ...   only from what was fetched before: nothing is asked
--   :run enrich --titles ...    also search CrossRef by title for books with no identifier
--   :run enrich --plan ...      say what would be asked of whom, and ask nothing
--
-- Who is asked what (the option enrich_services says which of them):
--   arXiv         by arXiv number: title, authors, the day of submission, the subject its class stands for
--   CrossRef      by DOI: title, authors, year, publisher (of a book), ISBN
--   zbMATH Open   by DOI or arXiv number: the subject, from the MSC codes it is classified under
--   Open Library  by ISBN: title, authors, publisher, year, series, the subject its shelf class stands for
--   OpenAlex      by DOI, when CrossRef has nothing
-- With the option arxiv_snapshot set to arXiv's metadata snapshot (the file
-- it publishes on Kaggle), papers are read from that file and arXiv is asked
-- only about those newer than it.
-- An identifier may be in calibre already or be found in the file. Every
-- answer is kept, so each work is asked about once, and a run that is stopped
-- loses nothing. Each service is asked one thing at a time and no faster
-- than it allows, many works to a request where it takes them (arXiv forty,
-- five seconds apart; CrossRef and Open Library twenty), and one that says
-- it is being asked too much is left alone for a while: the books it was
-- wanted for are picked up by the next run.
local edit = require "lulibre.edit"
local extract = require "lulibre.extract"
local junk = require "lulibre.junk"
local layouts = require "lulibre.layouts"
local net = require "lulibre.net"
local proposals = require "lulibre.proposals"
local propose = require "lulibre.propose"

local words, by_title, plan = {}, false, false
for _, a in ipairs({ ... }) do
  if a == "--titles" then by_title = true
  elseif a == "--plan" then plan = true
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
    -- an identifier read from the file may be that of a work it cites: which
    -- were, and what the file's own title seems to be, to tell by
    local in_file, titles = {}, {}
    if not (known.arxiv and known.doi and known.isbn) then
      for _, c in ipairs(extract.candidates(id)) do
        if c.field == "identifiers" then
          for kind in pairs { arxiv = 1, doi = 1, isbn = 1 } do
            local value = c.value:match("^" .. kind .. ":(.+)")
            if value and not known[kind] then known[kind], in_file[kind] = value, true end
          end
        elseif c.field == "title" then
          titles[#titles + 1] = c.value
        end
      end
    end
    if book.title and not junk.title(book.title) then titles[#titles + 1] = book.title end
    known.arxiv = known.arxiv and net.arxiv_id(known.arxiv)
    books[#books + 1] = { id = id, book = book, known = known, in_file = in_file, titles = titles }
  end
  if n % 50 == 0 then lulibre.progress(("reading identifiers %d/%d"):format(n, #ids)) end
end

-- arXiv's own snapshot of its records, if there is one here, is read before
-- arXiv is asked anything: what it holds costs no request
local snapshot = net.arxiv_snapshot_path()
local from_snapshot
if use.arxiv and snapshot then
  local numbers = {}
  for _, b in ipairs(books) do
    if b.known.arxiv then numbers[#numbers + 1] = b.known.arxiv end
  end
  lulibre.progress("reading arXiv's records from " .. snapshot)
  local found, lines = net.arxiv_snapshot(snapshot, numbers, function(far)
    lulibre.progress(("reading arXiv's records from the file: %s"):format(far))
  end)
  if found then
    from_snapshot = found
  else
    print(("arXiv's snapshot was not read: %s"):format(lines))
  end
end

-- --plan: what a run would ask, from what is known before anything is asked
-- (a DOI that arXiv or an ISBN that CrossRef turns out to know adds to it)
if plan then
  local function count(service, key_of)
    local seen, n = {}, 0
    for _, b in ipairs(books) do
      local key = key_of(b.known)
      if key and not seen[key] and net.kept(service, key) == nil then
        seen[key] = true
        n = n + 1
      end
    end
    return n
  end
  local papers = count("arxiv", function(k) return k.arxiv end)
  local dois = count("crossref", function(k) return k.doi and k.doi:lower() end)
  local isbns = count("openlibrary", function(k) return k.isbn and k.isbn:gsub("[^%dXx]", ""):upper() end)
  local rows = {
    { "arxiv", papers, math.ceil(papers / net.ARXIV_BATCH) },
    { "crossref", dois, math.ceil(dois / net.CROSSREF_BATCH) },
    { "zbmath", count("zbmath", function(k)
      return k.doi and "doi:" .. k.doi:lower() or k.arxiv and "arxiv:" .. k.arxiv
    end) },
    { "openlibrary", isbns, math.ceil(isbns / net.OPENLIBRARY_BATCH) },
  }
  local seconds = 0
  if from_snapshot then
    print(("%d paper%s read from arXiv's snapshot (%s)"):format(from_snapshot, from_snapshot == 1 and "" or "s", snapshot))
  end
  print(("%d book%s; nothing has been asked. A run now would ask:"):format(#books, #books == 1 and "" or "s"))
  for _, row in ipairs(rows) do
    local service, works, requests = row[1], row[2], row[3] or row[2]
    if use[service] then
      local till = net.held(service)
      print(("  %-12s %4d work%s not yet asked about, in %d request%s, %g s apart%s"):format(service, works,
        works == 1 and "" or "s", requests, requests == 1 and "" or "s", net.PACE[service],
        till and os.date(" (paused until %H:%M)", till) or ""))
      seconds = seconds + requests * (net.PACE[service] + 1)
    end
  end
  print(("  about %d minute%s in all; :run enrich --offline proposes from what is already kept"):format(
    math.ceil(seconds / 60), math.ceil(seconds / 60) == 1 and "" or "s"))
  return
end

-- arXiv answers for many numbers at a time, and allows one request every
-- three seconds: ask for them all first
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

-- CrossRef and Open Library take many at a time as well. (A DOI that only
-- arXiv knows is among them: its records are kept by now.)
if use.crossref then
  local dois = {}
  for _, b in ipairs(books) do
    local doi = b.known.doi
    if not doi and b.known.arxiv and use.arxiv then
      local rec = net.kept("arxiv", b.known.arxiv) and net.arxiv(b.known.arxiv)
      doi = rec and rec.ids.doi
    end
    if doi then dois[#dois + 1] = doi end
  end
  if #dois > 0 then
    lulibre.progress(("asking CrossRef about %d works"):format(#dois))
    net.crossref_prefetch(dois)
  end
end
if use.openlibrary then
  local isbns = {}
  for _, b in ipairs(books) do
    if b.known.isbn then isbns[#isbns + 1] = b.known.isbn end
  end
  if #isbns > 0 then
    lulibre.progress(("asking Open Library about %d books"):format(#isbns))
    net.openlibrary_prefetch(isbns)
  end
end

-- How far each service's word is taken for title, authors and the like. The
-- publisher's own record (CrossRef) and the author's (arXiv) come first;
-- zbMATH writes titles its own way (in sentence case) and is asked for the
-- subject, which it classifies by hand and nobody else does.
-- kinds of record whose "container" is a journal or a volume of proceedings
-- (a chapter's is the book it is in)
local ARTICLE = { ["journal-article"] = true, ["proceedings-article"] = true, article = true }
local TRUST = { arxiv = 0.95, crossref = 0.95, openlibrary = 0.9, zbmath = 0.85, openalex = 0.85 }

-- Is the record that of the book in hand? A number or DOI that calibre
-- holds is taken at its word; one read from the file's pages is believed
-- only if the record's title is the book's, or the title the file shows.
local function fits(b, kind, rec)
  if not b.in_file[kind] or not rec.title or #b.titles == 0 then return true end
  local theirs = lulibre.fold(rec.title)
  for _, title in ipairs(b.titles) do
    if net.same_title(title, rec.title) then return true end
    -- a title cut short is still the title
    local mine = lulibre.fold(title)
    if #mine >= 12 and theirs:sub(1, #mine) == mine then return true end
  end
  return false
end

local added, found, replacing, cited = 0, 0, 0, 0
local by_service = {}
for n, b in ipairs(books) do
  lulibre.progress(("looking up %d/%d"):format(n, #books))
  local records = {}
  local other = {} -- kinds of identifier that turned out to be another work's
  local function ask(service, kind, fn, ...)
    if not use[service] or other[kind] then return nil end
    local rec = fn(...)
    if rec and not fits(b, kind, rec) then
      other[kind], rec = true, nil
      cited = cited + 1
    end
    if rec then
      rec.service = service
      records[#records + 1] = rec
      by_service[service] = (by_service[service] or 0) + 1
    end
    return rec
  end
  local k = b.known
  local ax = k.arxiv and ask("arxiv", "arxiv", net.arxiv, k.arxiv)
  local doi, doi_kind = k.doi, "doi"
  if not doi and ax and ax.ids.doi then doi, doi_kind = ax.ids.doi, "arxiv" end
  local cr = doi and ask("crossref", doi_kind, net.crossref, doi)
  if doi and not cr then ask("openalex", doi_kind, net.openalex, doi) end
  if doi and not other[doi_kind] then
    ask("zbmath", doi_kind, net.zbmath, { doi = doi })
  elseif k.arxiv and not doi then
    ask("zbmath", "arxiv", net.zbmath, { arxiv = k.arxiv })
  end
  local isbn = k.isbn or (cr and cr.ids.isbn)
  if isbn then ask("openlibrary", "isbn-record", net.openlibrary, isbn) end
  if #records == 0 and by_title and use.crossref and b.book.title and #b.book.title >= 20 then
    ask("crossref", "title", net.crossref_search, b.book.title)
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
      -- a title with TeX left in it fills a gap, but is not put over a title that reads well
      offer("title", r.title, r.title_tex and r.source .. " (with TeX in it)" or r.source, r.title_tex and 0.75 or trust)
      if #r.authors > 0 then
        local authors, source, sure = r.authors, r.source, trust
        if r.authors_unordered then
          -- a file of arXiv's that does not say who comes first: the paper's own first page does
          local ordered, all = net.in_order_of(authors, lulibre.text(b.id))
          authors = ordered
          if all then
            source = source .. ", in the order of the first page"
          else
            source, sure = source .. " (in no order: the file gives none)", 0.75
          end
        end
        offer("authors", table.concat(authors, " & "), source, sure)
      end
      offer("pubdate", r.date or r.year, r.source, r.date and trust or trust - 0.05)
      -- An article's publisher is its journal, after the house behind the
      -- journal when the record names one; a book's is its house, written
      -- the one way that house is.
      local publisher = layouts.house(r.publisher)
      if r.container and ARTICLE[r.type or ""] then
        publisher = layouts.with_journal(r.member, r.container)
        -- the record names no house, but the book has one already: the journal goes after it
        if publisher == r.container then publisher = layouts.with_journal(layouts.known_house(b.book.publisher), r.container) end
      end
      offer("publisher", publisher, r.source, trust - 0.05)
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
if from_snapshot and from_snapshot > 0 then
  print(("%d paper%s read from arXiv's snapshot, without asking arXiv"):format(from_snapshot, from_snapshot == 1 and "" or "s"))
end
print(("%d book%s: a record for %d (%s); %d request%s made, %d answers already kept; %d proposal%s%s; %s goes through them"):format(
  #books, #books == 1 and "" or "s", found, #said > 0 and table.concat(said, ", ") or "none",
  net.stats.asked, net.stats.asked == 1 and "" or "s", net.stats.kept, added, added == 1 and "" or "s",
  replacing > 0 and (", %d for a field that has a value"):format(replacing) or "", lulibre.hint("review")))
if cited > 0 then
  print(("%d record%s left out: the identifier is in the file's pages, but the record's title is not the book's (a work it cites)"):format(
    cited, cited == 1 and "" or "s"))
end
for _, name in ipairs { "arxiv", "crossref", "zbmath", "openlibrary", "openalex" } do
  local till = use[name] and net.held(name)
  if till then
    print(("%s asked for a pause and was left alone: it is not asked again before %s. Run this again after that for the books it was wanted for."):format(
      name, os.date("%H:%M", till)))
  end
end
