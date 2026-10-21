--- The file decides: does a book's own text bear a value out?
--
-- A catalogue's record, a title search's hit, an identifier read off a page:
-- each is somebody's word that this file is a certain work. The file itself
-- is the one witness that cannot be about another work. So a title is
-- believed when its words stand in the opening pages, authors when their
-- family names do, an identifier when it stands there as the book's own
-- (not in a reference list), and a record when the book's pages show its
-- title or its people, and the file is about as long as the work the record
-- describes (a 30-page file is not a 900-page handbook, but may be a
-- chapter of it).
--
-- Only a file whose text could be read can decide. Where it cannot (no
-- text, too little, or garbled) every verdict is "unknown", and callers
-- treat the value as unconfirmed rather than as wrong.
--
-- @module lulibre.verify
-- @usage
-- local verify = require "lulibre.verify"
-- local ev = verify.evidence(id)            -- what the pages say, or nil and why not
-- verify.title(ev, "Algebraic Geometry")    --> "shown", 1.0
-- verify.authors(ev, { "Robin Hartshorne" }) --> "shown", 1, 1
-- verify.ident(ev, "doi:10.1007/...")       --> "front"
-- verify.judge(pr)                          --> { level = "better", says = "..." }

local ids = require "lulibre.ids"

local M = {}

--- How many pages from the start count as the opening.
M.FRONT = 6
--- A share of words at or above this is "shown".
M.SHOWN = 0.8
--- A share of words at or above this (and below SHOWN) is "partly".
M.PARTLY = 0.5
--- A text with more unreadable characters than this is garbled
-- (mathematics set in fonts with symbols in the private-use area comes to
-- 2-3 per cent).
M.GARBLED = 0.04
--- A file this much shorter than the edition a record describes is a part of it.
M.PART = 0.4

local STOP = {}
for w in ("a an the of and in on for to with by from at as is are its into via or der die das und von zur zum le la les des du de et en"):gmatch("%S+") do
  STOP[w] = true
end

-- Text as words: folded (case and accents gone); the accents TeX leaves
-- standing beside their letter ("Universit´e", "Sepp¨al¨ainen") dropped so
-- the word holds together; punctuation and symbols (U+2000 on: daggers,
-- dashes, arrows) and figures glued to a name ("Chamseddine1,3") apart.
local LOOSE_ACCENTS = { "\194\180", "\194\168", "\194\184", "\203\134", "\203\156", "\203\153", "`" }
local function each_word(text, fn)
  local t = lulibre.fold(text or "")
  for _, a in ipairs(LOOSE_ACCENTS) do t = t:gsub(a, "") end
  t = t:gsub("\226[\128-\191][\128-\191]", " "):gsub("\194[\128-\191]", " ")
  for w in t:gmatch("[%a\128-\255]+") do fn(w) end
  for w in t:gmatch("%d+") do fn(w) end
end

--- The words of a text, folded (case and accents gone), as a set.
-- @tparam string text
-- @treturn {[string]=true,...} each word once
function M.words(text)
  local set = {}
  each_word(text, function(w) set[w] = true end)
  return set
end

-- (M.telling)
local function telling(title)
  local list, seen = {}, {}
  each_word(title, function(w)
    if not STOP[w] and (#w > 2 or w:match("^%d+$")) and not seen[w] then
      seen[w] = true
      list[#list + 1] = w
    end
  end)
  return list
end
--- The telling words of a title: no little words, no single letters.
-- @function telling
-- @tparam string title
-- @treturn {string,...} folded, each once, in order
M.telling = telling

-- a share of the text that is no text: the replacement character, private
-- use and control characters left by a font that could not be read. A long
-- run of them (eight or more: the dots leading to a page number in a table
-- of contents, a rule) counts as one.
local BAD = { "\239\191\189", "\238[\128-\191][\128-\191]", "\239[\128-\163][\128-\191]", "[\1-\8\14-\31]" }
local function garbled(text)
  if #text == 0 then return 1 end
  local marked = text
  for _, b in ipairs(BAD) do marked = marked:gsub(b, "\0") end
  local bad = 0
  for run in marked:gmatch("%z+") do bad = bad + (#run >= 8 and 1 or #run) end
  local len = utf8.len(text) or #text
  return bad / math.max(1, len)
end
--- The share of a text that is no text: the replacement character,
-- private use and control characters left by a font that could not be
-- read; a run of eight or more counts as one.
-- @function garbled
-- @tparam string text
-- @treturn number between 0 and 1 (1 for an empty text)
M.garbled = garbled

local cache, whys = {}, {}

--- What a book's file says.
-- The book's file read best (a PDF first), as the index holds it.
-- @tparam integer id the book
-- @treturn[1] table `{ id=, path=, text=, words=, pages=, all=, refs= }`:
-- `text` the opening pages, `words` their words as a set, `pages` the
-- file's length, `all` every page the index holds, `refs` its reference
-- list if read
-- @treturn[2] nil when there is nothing that can be read
-- @treturn[2] string why not
function M.evidence(id)
  if cache[id] ~= nil then return cache[id] or nil, whys[id] end
  -- the book's file, as lulibre.text and lulibre.lines take it (db.h's
  -- DB_BOOK_FILE_ORDER), when it has been read
  local f = lulibre.sql([[SELECT id, path, npages, nchars, quality FROM files WHERE book = ? AND status = 1
    ORDER BY (format = 'PDF') DESC, id LIMIT 1]], id)[1]
  local why
  if not f then why = "no file has been read"
  elseif (f.nchars or 0) < 200 then why = "the file has almost no text (a scan?)"
  elseif (f.quality or 0) < 0.4 then why = "the file's text is mostly not words" end
  local ev
  if not why then
    local opening, all = {}, {}
    for i, r in ipairs(lulibre.sql("SELECT page, text FROM pages WHERE file = ? ORDER BY page", f.id)) do
      if i <= M.FRONT then opening[#opening + 1] = r.text end
      all[#all + 1] = r.text
    end
    local text = table.concat(opening, "\n")
    if garbled(text) > M.GARBLED then why = "the file's text is garbled (unreadable characters)"
    else
      local refs = {}
      for _, r in ipairs(lulibre.sql("SELECT raw FROM refs WHERE book = ?", id)) do refs[#refs + 1] = r.raw or "" end
      ev = { id = id, path = f.path, text = text, words = M.words(text), pages = f.npages, all = table.concat(all, "\n"),
        refs = table.concat(refs, "\n") }
    end
  end
  cache[id], whys[id] = ev or false, why
  return ev, why
end

--- Forget what was read (after the index has changed).
function M.forget() cache, whys = {}, {} end

--- Do the opening pages show a title?
-- @tparam table ev evidence (`evidence`)
-- @tparam string title
-- @treturn string "shown", "partly", "absent" or "unknown"
-- @treturn number|nil the share of its telling words that stand there
function M.title(ev, title)
  if not ev then return "unknown", nil end
  local words = telling(title)
  if #words == 0 then return "unknown", nil end
  local n = 0
  for _, w in ipairs(words) do
    if ev.words[w] then n = n + 1 end
  end
  local share = n / #words
  return share >= M.SHOWN and "shown" or share >= M.PARTLY and "partly" or "absent", share
end

--- How much of a title stands on the opening pages as it is written: the
-- longest run of its telling words that follows the same run in the text
-- (little words between are passed over), as a share of its words. "On
-- Predicate Logic as Modal Logic" over a book whose pages say "Modal
-- Predicate Logic" shares every word, but its longest run is two of four.
-- @tparam table ev evidence, or any table with `text`
-- @tparam string title
-- @treturn number|nil the share, nil when the title has no words
function M.phrase(ev, title)
  if not ev then return nil end
  local want = {}
  each_word(title, function(w)
    if not STOP[w] then want[#want + 1] = w end
  end)
  if #want == 0 then return nil end
  -- the text's words in order, built once and kept with the evidence: made
  -- whole in locals and put in place with one assignment, since another
  -- task may ask while this one is interrupted (a table filled in place
  -- would show it half made)
  local order = ev.order
  if not order then
    local seq, at = {}, {}
    each_word(ev.text, function(w)
      if not STOP[w] and not w:match("^%d+$") then
        seq[#seq + 1] = w
        at[w] = at[w] or {}
        table.insert(at[w], #seq)
      end
    end)
    -- (each_word gives the figures after the words: they are left out of the order)
    order = { seq = seq, at = at }
    ev.order = order
  end
  local seq, at = order.seq, order.at
  local best = 0
  for i = 1, #want do
    for _, pos in ipairs(at[want[i]] or {}) do
      local k = 1
      while i + k <= #want and seq[pos + k] == want[i + k] do k = k + 1 end
      if k > best then best = k end
    end
    if best >= #want - i + 1 then break end
  end
  return best / #want
end

--- How many pages from the start `headline` reads type sizes from.
M.HEADLINE_PAGES = 3

--- How much of a title stands in the largest type of the opening pages
-- (the lines set at least four fifths as large as the largest on each of
-- the first three), as M.phrase reckons it. A title page sets the title so;
-- a section heading inside ("Motivation and Background") is smaller than
-- the title above it, and a file name is in no type at all.
-- @tparam table ev evidence (`evidence`)
-- @tparam string title
-- @treturn number|nil the share, as `phrase`; nil when no type was read
function M.headline(ev, title)
  if not ev then return nil end
  if not ev.head then
    local parts = {}
    for page = 1, M.HEADLINE_PAGES do
      -- (a line set sideways is arXiv's stamp in the margin, not the title)
      local lines = lulibre.lines(ev.id, page)
      local top = 0
      for _, l in ipairs(lines) do
        if not l.rotated and (l.size or 0) > top then top = l.size end
      end
      for _, l in ipairs(lines) do
        if not l.rotated and top > 0 and (l.size or 0) >= top * 0.8 then parts[#parts + 1] = l.text end
      end
    end
    ev.head = { text = table.concat(parts, "\n") }
  end
  if ev.head.text == "" then return nil end
  return M.phrase(ev.head, title)
end

-- (M.family)
local function family(name)
  local fam = name:match("^([^,]+),") or name
  local last
  each_word(fam:gsub("%d", " "), function(w)
    if #w > 1 then last = w end
  end)
  return last
end
--- A person's family name, folded: "Given Family", "Family, Given", "G. Family".
-- @function family
-- @tparam string name
-- @treturn string|nil
M.family = family

--- Do the opening pages name these people? names: a list, or a string with
-- " & " between them. Returns the verdict ("shown" when every one is,
-- "partly", "absent", "unknown"), how many are shown, and how many named.
-- @tparam table ev evidence (`evidence`)
-- @tparam {string,...}|string names
-- @treturn string the verdict
-- @treturn integer how many are shown
-- @treturn integer how many are named
function M.authors(ev, names)
  if type(names) == "string" then names = require("lulibre.edit").split("authors", names) end
  if not ev then return "unknown", 0, #(names or {}) end
  local named, shown = 0, 0
  for _, name in ipairs(names or {}) do
    local fam = family(name)
    if fam and not require("lulibre.edit").is_unknown(name) then
      named = named + 1
      if ev.words[fam] then shown = shown + 1 end
    end
  end
  if named == 0 then return "unknown", 0, 0 end
  if shown < named then
    -- a family name in two words is often written as one ("Mac Lane", "MacLane")
    for _, name in ipairs(names or {}) do
      local ws = {}
      each_word((name:match("^([^,]+),") or name):gsub("%d", " "), function(w) ws[#ws + 1] = w end)
      if #ws >= 3 and not ev.words[ws[#ws]] and ev.words[ws[#ws - 1] .. ws[#ws]] then shown = shown + 1 end
    end
  end
  return shown == named and "shown" or shown > 0 and "partly" or "absent", shown, named
end

--- Where an identifier stands in the file: "own" (named in the file's own
-- metadata, or standing as the file's own by ids.doi_in's reading),
-- "front" (in the opening pages), "inside" (further in), "cited" (only in
-- the reference list), "absent", or "unknown".
-- @tparam table ev evidence (`evidence`)
-- @tparam string ident `kind:value`, as `doi:10.1007/...`
-- @treturn string
function M.ident(ev, ident)
  if not ev then return "unknown" end
  local kind, value = ident:match("^([^:]+):(.+)$")
  if not kind then return "unknown" end
  kind = kind:lower()
  -- the file's own metadata names it (lulibre.doc_metadata): its own
  -- read once, made whole, then kept with one assignment (as in M.phrase):
  -- reading the file waits, so another task can ask meanwhile
  if ev.path and ev.meta == nil then
    local meta = {}
    for _, m in ipairs(ids.from_metadata(lulibre.doc_metadata(ev.path))) do meta[m.kind .. ":" .. m.value:lower()] = true end
    ev.meta = meta
  end
  local norm = kind == "isbn" and ids.isbn13(value) or value
  if ev.meta and norm and ev.meta[kind .. ":" .. norm:lower()] then return "own" end
  local function find(text, v)
    if kind == "isbn" then
      local digits = v:gsub("[^%dXx]", ""):upper()
      return #digits >= 10 and text:gsub("[^%dXx]", ""):upper():find(digits, 1, true) ~= nil
    end
    return text:lower():find(v:lower(), 1, true) ~= nil
  end
  if kind == "doi" then
    local doi, own = ids.doi_in(ev.all)
    if doi and doi:lower() == value:lower() and own then return "own" end
  end
  if kind ~= "doi" and kind ~= "isbn" and kind ~= "arxiv" then return "unknown" end
  if find(ev.text, value) then
    if ev.refs ~= "" and find(ev.refs, value) and kind == "doi" then return "cited" end
    return "front"
  end
  if ev.refs ~= "" and find(ev.refs, value) then return "cited" end
  if find(ev.all, value) then return "inside" end
  return "absent"
end

--- Is the file about as long as the work a record describes? rec.pages is
-- the edition's length (Open Library) or the article's page range
-- (CrossRef). Returns "part" (the file is much shorter: a chapter of it, a
-- part of the whole the record is of), "larger" (the file is much longer:
-- the record is of one piece in it), "whole", or nil when there is no
-- telling; and why.
-- @tparam table|number ev evidence, or the file's length in pages
-- @tparam table rec a record: `pages`, `type`
-- @treturn string|nil
-- @treturn string|nil why
function M.size(ev, rec)
  local mine = ev and ev.pages or (type(ev) == "number" and ev) or nil
  if not mine or mine == 0 then return nil end
  local theirs = tonumber(rec.pages)
  if theirs and theirs > 0 then
    if mine < theirs * M.PART and theirs - mine > 30 then
      return "part", ("%d pages, where the record's is %d"):format(mine, theirs)
    end
    if mine > theirs * 3 + 20 then
      return "larger", ("%d pages, where the record's is %d"):format(mine, theirs)
    end
    return "whole"
  end
  local t = rec.type or ""
  if (t == "book" or t == "monograph" or t == "edited-book" or t == "reference-book") and mine < 25 then
    return "part", ("%d pages, where the record is of a whole book"):format(mine)
  end
  return nil
end

--- Judge a record against the book's file. Returns a table:
--   title, authors: the verdicts for the record's title and people
--   size: as M.size
--   another: the pages show neither the record's title nor any of its
--            people: it is another work's record
--   part:    the file is part of the work the record is of; its title,
--            people and identifiers are the whole's, not the file's
--   unread:  the file could not be read; nothing is known either way
-- @tparam table|nil ev evidence (`evidence`)
-- @tparam table rec a record: `title`, `authors`, `pages`, `type`
-- @treturn table
function M.record(ev, rec)
  if not ev then return { title = "unknown", authors = "unknown", unread = true } end
  local out = {}
  out.title = rec.title and M.title(ev, rec.title) or "unknown"
  out.authors = M.authors(ev, rec.authors or {})
  out.size, out.size_why = M.size(ev, rec)
  -- a short file whose record says only "book" (no length) is a chapter of
  -- it unless the file shows the book's title: lecture notes can be short
  if out.size == "part" and not tonumber(rec.pages) and out.title == "shown" then out.size, out.size_why = nil, nil end
  out.another = out.title == "absent" and (out.authors == "absent" or out.authors == "unknown")
  out.part = out.size == "part"
  return out
end

--- A book's own title, authors and identifiers, judged by its file:
-- { unread= why, title = { value=, verdict=, share= }, authors = { value=, verdict=, shown=, named= },
--   idents = { { ident=, where= }, ... } }
-- @tparam integer id the book
-- @treturn table|nil nil when there is no such book
function M.book(id)
  local book = lulibre.book(id)
  if not book then return nil end
  local ev, why = M.evidence(id)
  local edit = require "lulibre.edit"
  local out = { id = id, unread = not ev and why or nil }
  local v, share = M.title(ev, book.title)
  out.title = { value = book.title, verdict = v, share = share }
  local authors = edit.current(book, "authors")
  local av, shown, named = M.authors(ev, authors)
  out.authors = { value = authors, verdict = av, shown = shown, named = named }
  out.idents = {}
  for kind, value in pairs(book.idents) do
    out.idents[#out.idents + 1] = { ident = kind .. ":" .. value, where = M.ident(ev, kind .. ":" .. value) }
  end
  table.sort(out.idents, function(a, b) return a.ident < b.ident end)
  return out
end

-- the words of a line where a book states its date: a copyright or
-- publication line, arXiv's stamp, a "Date:" or "Received" line
local DATED = { "copyright", "(c)", "published", "publication", "edition", "printed", "date:", "dated",
  "received", "submitted", "accepted", "revised", "arxiv", "january", "february", "march", "april", "may",
  "june", "july", "august", "september", "october", "november", "december" }

--- Does a date stand on the opening pages? "stated": its year on a line
-- where a book says when it is from; "mentioned": its year elsewhere on
-- them (a year in a paper's text is often another's); "absent"; "unknown"
-- when there is no year to look for or no text.
-- @tparam table ev evidence (`evidence`)
-- @tparam string value a date, or anything with a year in it
-- @treturn string
function M.date(ev, value)
  if not ev then return "unknown" end
  local year = tostring(value or ""):match("%f[%d](%d%d%d%d)%f[%D]")
  if not year then return "unknown" end
  local seen = false
  for line in ev.text:gmatch("[^\n]+") do
    if line:find("%f[%d]" .. year .. "%f[%D]") then
      seen = true
      if line:find("\194\169") then return "stated" end -- ©
      local l = lulibre.fold(line)
      for _, w in ipairs(DATED) do
        if l:find(w, 1, true) then return "stated" end
      end
    end
  end
  return seen and "mentioned" or "absent"
end

-- words every other publisher has: they tell nothing about which one it is
local TRADE = {}
for w in ("press university publishing publishers publisher verlag books inc ltd llc gmbh company group international house editions editora edition society"):gmatch("%S+") do
  TRADE[w] = true
end

--- Does a publisher's name stand on the opening pages? Its telling words
-- less the trade's own ("Press", "Verlag", "University" ...), unless that
-- is all it has.
-- @tparam table ev evidence (`evidence`)
-- @tparam string value a publisher's name
-- @treturn string "shown", "partly", "absent" or "unknown"
function M.named(ev, value)
  if not ev then return "unknown" end
  local all, own = telling(value), {}
  for _, w in ipairs(all) do
    if not TRADE[w] then own[#own + 1] = w end
  end
  if #own == 0 then own = all end
  if #own == 0 then return "unknown" end
  local n = 0
  for _, w in ipairs(own) do
    if ev.words[w] then n = n + 1 end
  end
  local share = n / #own
  return share >= M.SHOWN and "shown" or share >= M.PARTLY and "partly" or "absent"
end

-- the fields the pages cannot settle: a subject is a reading of the whole,
-- a number in a series, a language, a summary are not written as such
local SILENT = { tags = true, series_index = true, languages = true, comments = true, rating = true }

--- Do the pages show a value of any field?
-- "unknown" when there is no text, or for a field pages cannot settle
-- (tags, series_index, languages, comments, rating).
-- @tparam table ev evidence (`evidence`)
-- @tparam string field
-- @tparam string value
-- @treturn string "shown", "partly", "absent" or "unknown"
function M.shows(ev, field, value)
  if not ev or SILENT[field] or value == nil or value == "" then return "unknown" end
  if field == "title" then return (M.title(ev, value))
  elseif field == "authors" then return (M.authors(ev, value))
  elseif field == "pubdate" then
    local d = M.date(ev, value)
    return d == "stated" and "shown" or d == "mentioned" and "partly" or d
  elseif field == "publisher" then return M.named(ev, value)
  elseif field == "series" then
    local share = M.phrase(ev, value)
    if not share then return "unknown" end
    return share >= M.SHOWN and "shown" or share >= M.PARTLY and "partly" or "absent"
  elseif field == "identifiers" then
    -- every identifier in the value: as the file's own or on its opening pages
    local n, shown, partly = 0, 0, 0
    for item in tostring(value):gsub("^[+-]%s*", ""):gmatch("[^,%s]+") do
      local w = M.ident(ev, item)
      if w ~= "unknown" then
        n = n + 1
        if w == "own" or w == "front" then shown = shown + 1 elseif w == "inside" then partly = partly + 1 end
      end
    end
    if n == 0 then return "unknown" end
    return shown == n and "shown" or shown + partly > 0 and "partly" or "absent"
  end
  return "unknown"
end

--- The levels of `judge`, as numbers to sort by: higher is better borne out.
M.LEVELS = { better = 6, more = 5, both = 4, partly = 3, silent = 2, neither = 1, against = 0 }

--- How far a book's pages bear a proposal out.
-- The level is one of (best first):
--
-- - "better": they show it, and not what the book has now (or it has nothing)
-- - "more": they show it, and it is what the book has now and more
-- - "both": they show it and what the book has now
-- - "partly": they show part of it
-- - "silent": they cannot tell: no text, or a field they cannot settle
-- - "neither": they show neither it nor what the book has now
-- - "against": they show what the book has now, and not it
--
-- For a removal it is the other way about: the pages showing what is
-- taken away is against it.
-- @tparam table pr a proposal: `book`, `field`, `value`, `op`
-- @treturn table `{ level =, says = }`, says being the level in words
function M.judge(pr)
  local edit = require "lulibre.edit"
  local book = lulibre.book(pr.book)
  if not book then return { level = "silent", says = "the book is no longer there" } end
  local ev, why = M.evidence(book.id)
  if not ev then return { level = "silent", says = "the pages cannot say: " .. (why or "no text") } end
  if SILENT[pr.field] then return { level = "silent", says = "the pages cannot settle " .. pr.field } end
  local v = M.shows(ev, pr.field, pr.value)
  if v == "unknown" then return { level = "silent", says = "the pages cannot say" } end
  if pr.op == "remove" then
    if v == "shown" then return { level = "against", says = "the pages show what would be taken away" } end
    if v == "partly" then return { level = "partly", says = "the pages show some of what would be taken away" } end
    return { level = "better", says = "the pages do not show what would be taken away" }
  end
  if pr.op == "add" then
    if v == "shown" then return { level = "better", says = "the pages show it" } end
    if v == "partly" then return { level = "partly", says = "the pages show part of it" } end
    return { level = "neither", says = "the pages do not show it" }
  end
  local now = edit.current(book, pr.field)
  local gap = now == "" or require("lulibre.propose").is_gap(pr.field, now, book.id)
  local was = gap and "absent" or M.shows(ev, pr.field, now)
  if v == "shown" then
    if gap then return { level = "better", says = "the pages show it, and the book has nothing there" } end
    if was ~= "shown" then return { level = "better", says = "the pages show it, not what the book has now" } end
    -- a title that holds the one there and more (a subtitle) is more of the same
    if pr.field == "title" or pr.field == "authors" then
      local mine = {}
      for _, w in ipairs(telling(pr.value)) do mine[w] = true end
      local holds, theirs = true, telling(now)
      for _, w in ipairs(theirs) do
        if not mine[w] then holds = false end
      end
      if holds and #telling(pr.value) > #theirs then
        return { level = "more", says = "the pages show it, and it is what the book has now and more" }
      end
    end
    return { level = "both", says = "the pages show it, and what the book has now" }
  elseif v == "partly" then
    return { level = "partly", says = "the pages show part of it" .. (was == "shown" and ", and all of what the book has now" or "") }
  end
  if was == "shown" then return { level = "against", says = "the pages show what the book has now, not this" } end
  return { level = "neither", says = "the pages show neither this nor what the book has now" }
end

return M
