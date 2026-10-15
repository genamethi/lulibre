-- The file decides: does a book's own text bear a value out?
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
--   local verify = require "lulibre.verify"
--   local ev = verify.evidence(id)           -- what the pages say, or nil and why not
--   verify.title(ev, "Algebraic Geometry")   --> "shown" | "partly" | "absent" | "unknown", share of its words shown
--   verify.authors(ev, { "Robin Hartshorne" }) --> verdict, how many shown, how many named
--   verify.ident(ev, "doi:10.1007/...")      --> "own" | "front" | "inside" | "cited" | "absent" | "unknown"
--   verify.phrase(ev, title)                 --> share of the title standing as written (in order)
--   verify.headline(ev, title)               --> the same, in the largest type of the first pages
--   verify.size(ev, rec)                     --> "part" | "whole" | "larger" | nil, why
--   verify.record(ev, rec)                   --> { title=, authors=, size=, another=, part=, unread= }
--   verify.book(id)                          --> the book's own title, authors and identifiers, judged
local ids = require "lulibre.ids"

local M = {}

-- how many pages from the start count as the opening
M.FRONT = 6
-- a share of words at or above this is "shown"; at or above PARTLY, "partly"
M.SHOWN, M.PARTLY = 0.8, 0.5
-- a text with more unreadable characters than this is garbled (mathematics
-- set in fonts with symbols in the private-use area comes to 2-3 per cent)
M.GARBLED = 0.04
-- a file this much shorter than the edition a record describes is a part of it
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
function M.words(text)
  local set = {}
  each_word(text, function(w) set[w] = true end)
  return set
end

-- the telling words of a title: no little words, no single letters
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
M.garbled = garbled

local cache, whys = {}, {}

--- What a book's file says: { id=, text= (the opening pages), words=, pages=
-- (the file's length), all= (every page the index holds), refs= (its
-- reference list, if read) }. nil and why not when there is nothing that
-- can be read.
function M.evidence(id)
  if cache[id] ~= nil then return cache[id] or nil, whys[id] end
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

--- Do the opening pages show a title? Returns the verdict and the share of
-- its telling words that stand there.
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
function M.phrase(ev, title)
  if not ev then return nil end
  local want = {}
  each_word(title, function(w)
    if not STOP[w] then want[#want + 1] = w end
  end)
  if #want == 0 then return nil end
  if not ev.seq then
    ev.seq, ev.at = {}, {}
    each_word(ev.text, function(w)
      if not STOP[w] and not w:match("^%d+$") then
        ev.seq[#ev.seq + 1] = w
        ev.at[w] = ev.at[w] or {}
        table.insert(ev.at[w], #ev.seq)
      end
    end)
    -- (each_word gives the figures after the words: they are left out of the order)
  end
  local best = 0
  for i = 1, #want do
    for _, pos in ipairs(ev.at[want[i]] or {}) do
      local k = 1
      while i + k <= #want and ev.seq[pos + k] == want[i + k] do k = k + 1 end
      if k > best then best = k end
    end
    if best >= #want - i + 1 then break end
  end
  return best / #want
end

--- How much of a title stands in the largest type of the opening pages
-- (the lines set at least four fifths as large as the largest on each of
-- the first three), as M.phrase reckons it. A title page sets the title so;
-- a section heading inside ("Motivation and Background") is smaller than
-- the title above it, and a file name is in no type at all.
M.HEADLINE_PAGES = 3
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

-- a person's family name, folded: "Given Family", "Family, Given", "G. Family"
local function family(name)
  local fam = name:match("^([^,]+),") or name
  local last
  each_word(fam:gsub("%d", " "), function(w)
    if #w > 1 then last = w end
  end)
  return last
end
M.family = family

--- Do the opening pages name these people? names: a list, or a string with
-- " & " between them. Returns the verdict ("shown" when every one is,
-- "partly", "absent", "unknown"), how many are shown, and how many named.
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
function M.ident(ev, ident)
  if not ev then return "unknown" end
  local kind, value = ident:match("^([^:]+):(.+)$")
  if not kind then return "unknown" end
  kind = kind:lower()
  -- the file's own metadata names it (lulibre.doc_metadata): its own
  if ev.path and ev.meta == nil then
    ev.meta = {}
    for _, m in ipairs(ids.from_metadata(lulibre.doc_metadata(ev.path))) do ev.meta[m.kind .. ":" .. m.value:lower()] = true end
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

return M
