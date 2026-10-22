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
local noncatalog = require "lulibre.noncatalog"
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
local books, uncatalogued = {}, 0
for n, id in ipairs(ids) do
  local book = lulibre.book(id)
  if book then
    -- A work no catalogue has a record of (:noncatalog) is not looked up by
    -- DOI or ISBN, whoever put one on it, nor searched for by title: an
    -- arXiv number is all it goes by.
    local outside = noncatalog.is(id)
    local known = { arxiv = book.idents.arxiv, doi = not outside and book.idents.doi or nil,
      isbn = not outside and book.idents.isbn or nil }
    if outside then uncatalogued = uncatalogued + 1 end
    -- an identifier read from the file may be that of a work it cites: which
    -- were, and what the file's own title seems to be, to tell by
    local in_file, titles = {}, {}
    if not (known.arxiv and known.doi and known.isbn) then
      for _, c in ipairs(extract.candidates(id)) do
        if c.field == "identifiers" then
          for kind in pairs { arxiv = 1, doi = 1, isbn = 1 } do
            local value = c.value:match("^" .. kind .. ":(.+)")
            if value and not known[kind] and (kind == "arxiv" or not outside) then known[kind], in_file[kind] = value, true end
          end
        elseif c.field == "title" then
          titles[#titles + 1] = c.value
        end
      end
    end
    if book.title and not junk.title(book.title) then titles[#titles + 1] = book.title end
    known.arxiv = known.arxiv and net.arxiv_id(known.arxiv)
    books[#books + 1] = { id = id, book = book, known = known, in_file = in_file, titles = titles, outside = outside,
      -- the authors the book has, when they are worth the name; and how its file opens
      people = function(b)
        if not b.authors then
          local has = edit.current(b.book, "authors")
          b.authors = propose.is_gap("authors", has, b.id) and {} or edit.split("authors", has)
          b.head = (lulibre.text(b.id) or ""):sub(1, 3000)
        end
        return b.authors
      end }
  end
  if n % 50 == 0 then lulibre.progress(("reading identifiers %d/%d"):format(n, #ids)) end
end

-- a run of its own, unless this is a step of one (the propose-and-review
-- dialog) or only a plan is asked for
local step = net.offline and "records" or "records and services"
local run <close> = not plan and require("lulibre.runs").join { ids = ids, steps = { step } } or nil
if run then run:step(step) end

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

-- Open Library's dumps, if they are here, likewise: a book found in them by
-- its ISBN costs no request
local from_dump
if use.openlibrary then
  local isbns = {}
  for _, b in ipairs(books) do
    if b.known.isbn then isbns[#isbns + 1] = b.known.isbn end
  end
  if #isbns > 0 and require("lulibre.datasets").path("ol_dump_editions_latest.txt.gz") then
    lulibre.progress(("looking for %d books in Open Library's dump (some minutes, once)"):format(#isbns))
    local found, whole = net.openlibrary_dump(isbns)
    if found then
      from_dump = found
      if whole == false then print("Open Library's dump is not whole (still being fetched?): what it holds so far was read") end
    else
      print(("Open Library's dump was not read: %s"):format(tostring(whole)))
    end
  end
end

-- zbMATH's table of links says which arXiv papers it has, and under what number
local zb_numbers = {}
if use.zbmath then
  local numbers = {}
  for _, b in ipairs(books) do
    if b.known.arxiv then numbers[#numbers + 1] = b.known.arxiv end
  end
  if #numbers > 0 then zb_numbers = net.zbmath_links(numbers) end
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
  if from_dump then
    print(("%d book%s read from Open Library's dump"):format(from_dump, from_dump == 1 and "" or "s"))
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

-- Is the record that of the book in hand? An identifier read from the
-- file's pages may be a cited work's: its record is believed only if the
-- record's title is the book's, or the title the file shows. One the
-- library holds is not taken at its word either (it may have come from such
-- a page, or from an earlier mistake): net.fits says how it is judged.
-- Returns whether it fits, and when it does not, whether title and authors
-- both speak against it.
local verify = require "lulibre.verify"

-- What the book's own pages state of its date and publisher, read by rule:
-- the readers of known layouts and grammars (lulibre.layouts, .grammars)
-- and a cover sheet that labels its fields; not a title page's guesses.
local STATED = { ["cataloguing data"] = true, ["copyright line"] = true, ["series page"] = true, ["cover sheet"] = true,
  ["journal header"] = true, ["arXiv stamp"] = true }
local function stated(b)
  if b.stated then return b.stated end
  b.stated = { years = {}, publishers = {} }
  local ok, cands = pcall(extract.candidates, b.id)
  for _, c in ipairs(ok and cands or {}) do
    local source = c.source or ""
    if (STATED[source] or source:find("^grammar: ")) and (c.confidence or 0) >= 0.75 then
      local year = c.field == "pubdate" and tonumber(tostring(c.value):match("^(%d%d%d%d)"))
      if year then b.stated.years[#b.stated.years + 1] = { year = year, source = source } end
      if c.field == "publisher" then b.stated.publishers[#b.stated.publishers + 1] = { name = c.value, source = source } end
    end
  end
  return b.stated
end

-- one house's imprints are the house
local PARENT = { ["North-Holland"] = "Elsevier", ["Academic Press"] = "Elsevier", ["Birkhäuser"] = "Springer",
  ["Kluwer"] = "Springer", ["Addison-Wesley"] = "Pearson", ["Prentice Hall"] = "Pearson", ["Interscience"] = "Wiley",
  ["CRC Press"] = "Taylor & Francis", ["Chapman & Hall"] = "Taylor & Francis", ["Routledge"] = "Taylor & Francis" }
local function same_house(a, b)
  if not a or not b or a == "" or b == "" then return true end
  local fa, fb = lulibre.fold(a), lulibre.fold(b)
  if fa:find(fb, 1, true) or fb:find(fa, 1, true) then return true end
  local ha, hb = layouts.known_house(a), layouts.known_house(b)
  return ha ~= nil and hb ~= nil and (PARENT[ha] or ha) == (PARENT[hb] or hb)
end

-- Does the record say what the pages, so read, contradict? A year earlier
-- than one the pages print for the book (a copyright line gives the latest
-- of its years: the edition in hand) is another edition's; a publisher that
-- is not the one the pages name, nor its imprint, nor its journal, is
-- another's. Returns why, or nil. Where the pages state nothing, nothing is
-- contradicted.
local function contradicts(b, rec)
  local st = stated(b)
  local year = tonumber(tostring(rec.date or rec.year or ""):match("^(%d%d%d%d)"))
  for _, s in ipairs(st.years) do
    if year and year < s.year then
      return ("the pages print %d (%s), the record %d"):format(s.year, s.source, year)
    end
  end
  if rec.publisher or rec.container then
    for _, s in ipairs(st.publishers) do
      if not same_house(s.name, rec.publisher or rec.container) and not (rec.container and same_house(s.name, rec.container)) then
        return ("the pages name %s (%s), the record %s"):format(s.name, s.source, rec.publisher or rec.container)
      end
    end
  end
  return nil
end

local function fits(b, kind, rec)
  if b.in_file[kind == "isbn-record" and "isbn" or kind] then
    if not rec.title or #b.titles == 0 then return true end
    local theirs = lulibre.fold(rec.title)
    for _, title in ipairs(b.titles) do
      if net.same_title(title, rec.title) then return true end
      -- a title cut short is still the title
      local mine = lulibre.fold(title)
      if #mine >= 12 and theirs:sub(1, #mine) == mine then return true end
    end
    return false, false
  end
  local people = b:people()
  return net.fits(rec, b.titles, people, b.head)
end

local added, found, replacing, cited, others, removals = 0, 0, 0, 0, 0, 0
local by_service = {}
for n, b in ipairs(books) do
  lulibre.progress(("looking up %d/%d"):format(n, #books))
  local records = {}
  local other = {} -- kinds of identifier that turned out to be another work's
  local wrong = {} -- kind of identifier the library holds -> the title of the other work its record is of
  local fitting = {} -- kind of identifier -> a record it led to has been found to be the book's
  local function ask(service, kind, fn, ...)
    if not use[service] or other[kind] then return nil end
    local rec = fn(...)
    if rec then
      -- once one record an identifier led to is the book's, so are the others it leads to
      local ok, plain, how = true, false, nil
      if not fitting[kind] then
        ok, plain, how = fits(b, kind, rec)
        fitting[kind] = ok and (how or true)
      end
      -- the file decides (lulibre.verify): a record whose title and people
      -- are both missing from the book's own pages is another work's, and
      -- one found by searching for a title must have its title there
      local judged = verify.record(b.ev, rec)
      rec.judged = judged
      if ok and judged.another then ok, plain = false, true end
      -- a record whose date or publisher the pages contradict is another edition's or another work's
      local clash = ok and contradicts(b, rec)
      if clash then ok, plain, rec.clash = false, true, clash end
      if ok and kind == "title" and not judged.unread and judged.title ~= "shown" then ok, plain = false, false end
      -- a record of the whole the file is a part of (a handbook, for one of its chapters)
      if ok and judged.part then rec.part_of = judged.size_why end
      -- known for the book's by its people alone: its title may be another work's, or the whole this is a part of
      if fitting[kind] == "people" then rec.by_people = true end
      if not ok then
        local in_file = b.in_file[kind == "isbn-record" and "isbn" or kind]
        if in_file then cited = cited + 1 else others = others + 1 end
        -- which, and why: in the log (:messages), and on the terminal when there is no interface
        local line = ("book %d (%s): the record %s is left out, it is of \"%s\"%s%s"):format(b.id, b.book.title or "", rec.source or service,
          rec.title or "", #rec.authors > 0 and (" by " .. table.concat(rec.authors, ", ")) or "",
          rec.clash and ("; " .. rec.clash) or "")
        if lulibre.headless then print("  " .. line) else lulibre.log("enrich: " .. line) end
        -- what an earlier run proposed from this record is withdrawn with it
        if rec.source then
          lulibre.store("DELETE FROM proposals WHERE book = ? AND status = 'pending' AND (source = ? OR instr(source, ? || ' (') = 1)", b.id, rec.source, rec.source)
        end
        if plain and not in_file and ((service == "arxiv" and kind == "arxiv") or (kind == "doi" and (service == "crossref" or service == "openalex"))) then
          wrong[kind] = rec.title
        end
        -- an ISBN the book's pages do not print, whose record they contradict
        -- (one they print is the book's: only its record is wrong)
        if rec.clash and kind == "isbn-record" and b.book.idents.isbn
            and verify.ident(b.ev, "isbn:" .. b.book.idents.isbn) == "absent" then
          wrong.isbn = rec.title
        end
        other[kind], rec = true, nil
      end
    end
    if rec then
      rec.service = service
      records[#records + 1] = rec
      by_service[service] = (by_service[service] or 0) + 1
    end
    return rec
  end
  b.ev = verify.evidence(b.id)
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
  if #records == 0 and by_title and not b.outside and use.crossref and b.book.title and #b.book.title >= 20 then
    -- the book's authors help tell the work from another of the same name, when it has any
    local who = {}
    local has = require("lulibre.edit").current(b.book, "authors")
    if not propose.is_gap("authors", has, b.id) then who = require("lulibre.edit").split("authors", has) end
    ask("crossref", "title", net.crossref_search, b.book.title, who)
  end
  -- An identifier the library holds whose record is plainly another work's
  -- (neither its title nor its authors are the book's): taking it off is proposed.
  for kind, title in pairs(wrong) do
    local value = b.book.idents[kind]
    if value and proposals.add(b.id, "identifiers", kind .. ":" .. value, { op = "remove", confidence = 0.6,
        source = ("its record is another work: %s"):format(#title > 60 and title:sub(1, 57) .. "..." or title) }) then
      removals = removals + 1
    end
  end
  -- the number zbMATH knows the paper by, from its table of links: no request, and not a record of its own
  local zb = k.arxiv and not other.arxiv and zb_numbers[k.arxiv]
  if zb then
    records[#records + 1] = { service = "zbmath", authors = {}, subjects = {}, ids = { zbmath = zb }, source = "zbMATH's links to arXiv" }
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
      -- a record found by its title is believed as far as the titles and authors bear it out
      local trust = math.min(TRUST[r.service] or 0.85, r.trust or 1)
      -- a title with TeX left in it fills a gap, but is not put over a title that reads well
      -- A record does not get to put a shorter title, or other people, over
      -- what a book has as if it were sure: those are offered low, so they
      -- fill a gap or answer --over, and are not pressed on a good value.
      local has_title = b.book.title and not propose.is_gap("title", b.book.title, b.id)
      local short = r.title and has_title and net.shorter_title(b.book.title, r.title)
      local elsewhere = has_title and r.by_people
      -- what the book's own pages say of the record's title and people
      local judged = r.judged or {}
      if judged.unread then
        -- nothing could be checked: what the record says is offered, but less sure
        -- (by a step, so the sources keep their order)
        trust = trust - 0.2
      end
      local function skip(field, why)
        local line = ("book %d: %s's %s is not offered: %s"):format(b.id, r.source or r.service, field, why)
        if lulibre.headless then print("  " .. line) else lulibre.log("enrich: " .. line) end
      end
      if r.part_of then
        -- the record is of the whole: its title, people and numbers are not the file's
        skip("title, authors and identifiers", "the record is of the whole this file is a part of (" .. r.part_of .. ")")
      elseif r.title and judged.title == "absent" then
        skip("title", "its words are not on the book's opening pages")
      else
        local partly = judged.title == "partly"
        -- a catalogue's spelling of the title gives way to the book's own
        -- pages, where they show it, and is otherwise put in title case
        -- (title case only for a book in English, or of no stated language:
        -- its rules are English)
        local title = r.title
        if title and not r.title_tex then
          local lang = (b.book.lang or ""):lower()
          local english = lang == "" or lang:find("^en") ~= nil
          title = require("lulibre.titlecase").as_on_page(title, b.ev and b.ev.text, { case = english })
        end
        offer("title", title, r.title_tex and r.source .. " (with TeX in it)" or short and r.source .. " (the title with words left out)"
          or elsewhere and r.source .. " (another title, the same people: the whole this is part of?)"
          or partly and r.source .. " (not all its words are on the book's pages)"
          or judged.unread and r.source .. " (the file could not be read to check it)" or r.source,
          math.min(r.title_tex and 0.75 or trust, short and 0.6 or 1, elsewhere and 0.5 or 1, partly and 0.6 or 1))
      end
      if #r.authors > 0 and not r.part_of and judged.authors == "absent" then
        skip("authors", "none of them is named on the book's opening pages")
      elseif #r.authors > 0 and not r.part_of then
        local authors, source, sure = r.authors, r.source, trust
        if judged.authors == "partly" then source, sure = source .. " (not all named on the book's pages)", math.min(sure, 0.6)
        elseif net.other_people(b:people(), r.authors) then source, sure = source .. " (none of the names the book has)", math.min(sure, 0.6)
        elseif net.fewer_people(b:people(), r.authors) then source, sure = source .. " (fewer names than the book has)", math.min(sure, 0.6) end
        if r.authors_unordered then
          -- a file of arXiv's that does not say who comes first: the paper's own first page does
          local ordered, all = net.in_order_of(authors, lulibre.text(b.id))
          authors = ordered
          if all then
            source = source .. ", in the order of the first page"
          else
            source, sure = source .. " (in no order: the file gives none)", math.min(sure, 0.75)
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
      offer("series", r.series, r.source, math.min(0.85, trust))
      offer("series_index", r.series_index, r.source, math.min(0.85, trust))
      for _, s in ipairs(r.subjects) do offer("tags", s.tag, ("%s (%s)"):format(r.source, s.why), s.confidence) end
      if not r.part_of then
        for kind, value in pairs(r.ids) do offer("identifiers", kind .. ":" .. value, r.source, math.min(0.95, r.trust or 1, trust)) end
      end
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
      -- A record's day of publication settles what the file could only read
      -- off its arXiv number or stamp: those proposals are not left to be
      -- chosen between.
      if w.field == "pubdate" and #w.value > 4 then
        lulibre.store([[DELETE FROM proposals WHERE book = ? AND field = 'pubdate' AND status = 'pending'
          AND (source = 'arXiv id' OR source LIKE 'arXiv stamp%')]], b.id)
      end
    end
  end
end
lulibre.progress(nil)
if run then run:done() end

local said = {}
for _, name in ipairs { "arxiv", "crossref", "zbmath", "openlibrary", "openalex" } do
  if by_service[name] then said[#said + 1] = ("%s %d"):format(name, by_service[name]) end
end
if from_dump and from_dump > 0 then
  print(("%d book%s read from Open Library's dump, without asking Open Library"):format(from_dump, from_dump == 1 and "" or "s"))
end
if from_snapshot and from_snapshot > 0 then
  print(("%d paper%s read from arXiv's snapshot, without asking arXiv"):format(from_snapshot, from_snapshot == 1 and "" or "s"))
end
print(("%d book%s: a record for %d (%s); %d request%s made, %d answers already kept; %d new proposal%s%s.%s"):format(
  #books, #books == 1 and "" or "s", found, #said > 0 and table.concat(said, ", ") or "none",
  net.stats.asked, net.stats.asked == 1 and "" or "s", net.stats.kept, added, added == 1 and "" or "s",
  replacing > 0 and (", %d would replace a value the book has"):format(replacing) or "",
  require("lulibre.proposals").to_review(" ")))
if cited > 0 then
  print(("%d record%s left out: the identifier is in the file's pages, but the record's title is not the book's (a work it cites)"):format(
    cited, cited == 1 and "" or "s"))
end
if others > 0 then
  print(("%d record%s left out: the book has the identifier, but the record is not the book's by its title and authors, or by the date or publisher its pages print%s"):format(
    others, others == 1 and "" or "s", removals > 0 and ("; taking the identifier off is proposed for %d"):format(removals) or ""))
end
if uncatalogued > 0 then
  print(("%d marked as non-catalog: not looked up by DOI or ISBN, nor searched for by title"):format(uncatalogued))
end
for _, name in ipairs { "arxiv", "crossref", "zbmath", "openlibrary", "openalex" } do
  local till = use[name] and net.held(name)
  if till then
    print(("%s asked for a pause and was left alone: it is not asked again before %s. Run this again after that for the books it was wanted for."):format(
      name, os.date("%H:%M", till)))
  end
end
