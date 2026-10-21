--- Decides what to propose for a book from the book's file.
--
-- A gap is a field that is empty or holds something that is clearly not a
-- value, such as a file name as a title. lulibre proposes the file's best
-- candidate for every gap. A field with a value is different: the value may
-- be right and the title page misread, or the value may be a typo and the
-- file right. The option `propose_over` sets when lulibre proposes the
-- file's value over the book's:
--
-- - "gaps": never. lulibre proposes only for gaps.
-- - "sure": when the file's evidence is strong (confidence 0.8 or more,
--   such as a stated identifier, a labelled cover sheet or a clear title
--   page) and differs from the book's value.
-- - "any": whenever the file's best candidate differs.
--
-- lulibre never trusts the book's value more than the file's just because
-- someone typed it. Review shows both values side by side, and you decide
-- there.
--
-- @module lulibre.propose
-- @usage
-- local propose = require "lulibre.propose"
-- propose.wanted(book, candidates, "sure")   --> { {field=, value=, op=, source=, confidence=, over=}, ... }
-- propose.book(id, { over = "any", again = true })   --> proposals added, how many replace a value
local edit = require "lulibre.edit"
local extract = require "lulibre.extract"
local junk = require "lulibre.junk"
local names = require "lulibre.names"
local proposals = require "lulibre.proposals"
local quality = require "lulibre.quality"

local M = {}

--- The confidence a candidate needs to be proposed over a value, if `propose_over` is "sure".
M.SURE = 0.8

-- a value reduced to what matters when asking "do these say the same?":
-- case, accents, the shape of quotes and dashes, punctuation and spacing do not
local SHAPES = { ["‘"] = "'", ["’"] = "'", ["´"] = "'", ["`"] = "'", ["“"] = '"', ["”"] = '"', ["„"] = '"',
  ["–"] = "-", ["—"] = "-", ["‐"] = "-", ["‑"] = "-", ["−"] = "-" }
local function plain(s)
  -- (one character at a time: these are sequences of bytes, which a set of
  -- characters in a pattern would take apart)
  s = (s or ""):gsub("[\194\226][\128-\191][\128-\191]?", SHAPES):gsub("`", "'")
  s = lulibre.fold(s):gsub("%p", " "):gsub("%s+", " ")
  return (s:gsub("^ ", ""):gsub(" $", ""))
end

-- One person written two ways: the same family name, and given names that
-- agree as far as both go ("P. Selinger" and "Peter Selinger", "Sam" and
-- "Samuel", "Jeffery M. Tucker" and "Jeffery Tucker").
local function same_person(a, b)
  local wa, wb = {}, {}
  for w in a:gmatch("%S+") do wa[#wa + 1] = w end
  for w in b:gmatch("%S+") do wb[#wb + 1] = w end
  if #wa == 0 or #wb == 0 or table.remove(wa) ~= table.remove(wb) then return false end
  for i = 1, math.min(#wa, #wb) do
    local x, y = wa[i], wb[i]
    if #x > #y then x, y = y, x end
    if y:sub(1, #x) ~= x then return false end
  end
  return true
end

-- The same people, name for name? a, b: lists of plain names.
local function same_people(a, b)
  if #a ~= #b then return false end
  local taken = {}
  for _, x in ipairs(a) do
    local hit
    for j, y in ipairs(b) do
      if not taken[j] and same_person(x, y) then
        hit = j
        break
      end
    end
    if not hit then return false end
    taken[hit] = true
  end
  return true
end

--- Returns true if a subject is narrower than one the book has, and the
-- book doesn't have it yet. For example, "cs/ml" refines "cs", but not if
-- the book also has "cs/ml" or "cs/ml/theory".
-- @tparam string tags the book's, as "a, b/c"
-- @tparam string subject
-- @treturn boolean
function M.refines(tags, subject)
  local under = false
  for raw in (tags or ""):gmatch("[^,]+") do
    local tag = raw:gsub("^%s+", ""):gsub("%s+$", "")
    if tag == subject or tag:sub(1, #subject + 1) == subject .. "/" then return false end
    if subject:sub(1, #tag + 1) == tag .. "/" then under = true end
  end
  return under
end

--- Returns true if two values of a field mean the same. Authors are
-- compared as a set of names. Dates are compared by year if either gives
-- only a year. The same people with shorter names ("S. Joffily" for
-- "Sérgio Joffily") count as the same; with fuller names they don't.
-- @tparam string field
-- @tparam string a what the book has
-- @tparam string b what is offered
-- @treturn boolean
function M.same(field, a, b)
  if field == "authors" then
    local function names(s)
      local out = {}
      for _, n in ipairs(edit.split("authors", s)) do out[#out + 1] = plain(n) end
      table.sort(out)
      return out
    end
    local na, nb = names(a), names(b)
    local ta, tb = table.concat(na, "|"), table.concat(nb, "|")
    if ta == tb then return true end
    return same_people(na, nb) and #tb <= #ta
  end
  if field == "pubdate" then
    -- a is what the book has, b what is offered. A bare year (kept as the
    -- first of January) offered against a date in that year adds nothing;
    -- a full date offered against a bare year is news.
    local ya, yb = (a or ""):match("^%d%d%d%d"), (b or ""):match("^%d%d%d%d")
    local offered_bare = (b or ""):match("^%d%d%d%d$") or (b or ""):match("%-01%-01$")
    if ya and yb and offered_bare then return ya == yb end
  end
  return plain(a) == plain(b)
end

--- Returns true if a field's value is a gap: empty, or clearly not a real
-- value. Examples are a title that is a file name, a number or a heading,
-- and an author that is the program that made the file, a web site or a
-- rank. The file's candidate is proposed for a gap. A record confirmed as
-- good (:good) has no gaps of this kind, since its values were checked.
-- @tparam string field
-- @tparam string cur the value
-- @tparam[opt] integer id the book, if known
-- @treturn boolean
function M.is_gap(field, cur, id)
  if cur == "" then return true end
  if id and quality.is_good(id) then return false end
  if field == "title" then return junk.unlikely_title(cur) end
  if field == "authors" then
    for _, a in ipairs(edit.split("authors", cur)) do
      if not (junk.author(a) or names.never(a) or a:find("%.%a%a%a?$") or a:find("%d%d")) then return false end
    end
    return true -- every one of them is junk
  end
  return false
end
local is_gap = M.is_gap

--- The letters and names of the fields, as `only` (propose's fields) and review's filter take them.
M.FIELD = { t = "title", title = "title", a = "authors", author = "authors", authors = "authors", s = "tags",
  subject = "tags", tags = "tags", tag = "tags", i = "identifiers", id = "identifiers", ids = "identifiers",
  identifiers = "identifiers", identifier = "identifiers", d = "pubdate", date = "pubdate", pubdate = "pubdate",
  year = "pubdate", p = "publisher", publisher = "publisher", e = "series", series = "series",
  series_index = "series_index", n = "series_index" }

--- Converts a list such as "title,authors" or "t,a" into a set of field
-- names. Returns nil and the bad word if a word is not a field.
-- @tparam string list
-- @treturn[1] table `{ [field] = true }`
-- @treturn[2] nil
-- @treturn[2] string the word that is not a field
function M.fields(list)
  local set = {}
  for word in (list or ""):gmatch("[^,%s]+") do
    local field = M.FIELD[word:lower()]
    if not field then return nil, word end
    set[field] = true
  end
  return set
end

local SINGLE = { title = true, authors = true, pubdate = true, publisher = true, series = true, series_index = true }

--- Returns the file's candidates that are worth proposing for a book. The
-- candidates are ordered strongest first within each field, as extract
-- gives them. A result has `over = true` if it would replace a value the
-- book has.
-- @tparam table book
-- @tparam {table,...} candidates
-- @tparam[opt] string|table over "gaps", "sure" or "any" (`propose_over` by default),
-- or a table `{ over=, only=, fresh= }`: `only` is a set of fields to limit to, and
-- `fresh` proposes as if the fields were empty
-- @treturn {table,...} `{ field=, value=, op=, source=, confidence=, over= }`
function M.wanted(book, candidates, over)
  local opts = type(over) == "table" and over or { over = over }
  over = opts.over or lulibre.o.propose_over
  local out, settled = {}, {}
  for _, c in ipairs(candidates) do
    local cur = edit.current(book, c.field)
    if opts.only and not opts.only[c.field] then goto continue end
    if opts.fresh then
      -- as if the field were empty: the strongest candidate for a single
      -- value, every stated subject and identifier
      local single = SINGLE[c.field]
      if not (single and settled[c.field]) and (single or c.field ~= "tags" or (c.confidence or 0) >= 0.9 or not settled.tags) then
        settled[c.field] = true
        local replaces = cur ~= "" and not is_gap(c.field, cur, book.id)
        if not (single and M.same(c.field, cur, c.value)) then
          out[#out + 1] = { field = c.field, value = c.value, op = single and "set" or "add", source = c.source,
            confidence = c.confidence, over = replaces }
        end
      end
      goto continue
    end
    do
    local want, op, replaces = false, "set", false
    if SINGLE[c.field] then
      -- only the strongest candidate for the field is heard: if it agrees
      -- with the book, weaker ones that do not are not worth a proposal
      if not settled[c.field] then
        settled[c.field] = true
        if is_gap(c.field, cur, book.id) then
          want = cur == "" or not M.same(c.field, cur, c.value) -- what looks like junk may simply be the title
        elseif over ~= "gaps" and not M.same(c.field, cur, c.value)
          and (over == "any" or (c.confidence or 0) >= M.SURE) then
          want, replaces = true, true
        end
      end
    elseif c.field == "tags" then
      -- a stated subject (arXiv class, MSC) is worth adding; vocabulary only fills a gap
      op = "add"
      if cur == "" then want = (c.confidence or 0) >= 0.9 or not settled.tags
      else
        want = over ~= "gaps" and (c.confidence or 0) >= 0.9
        -- A finer subject under one the book has ("cs/ml" for a book filed
        -- under "cs") is news whoever says it, once: the vocabulary's best.
        if not want and over ~= "gaps" and not settled.tags and (c.confidence or 0) >= 0.4 and M.refines(cur, c.value) then want = true end
      end
      if want then settled.tags = true end
    elseif c.field == "identifiers" then
      want, op = true, "add"
    end
    if want then
      out[#out + 1] = { field = c.field, value = c.value, op = op, source = c.source, confidence = c.confidence,
        over = replaces }
    end
    end
    ::continue::
  end
  return out
end

--- Proposes values for one book from its file.
-- @tparam integer id
-- @tparam[opt] table opts `over`, `only` and `fresh` as for `wanted`; `again`
-- also proposes values that were barred before
-- @treturn integer proposals added
-- @treturn integer how many of them replace a value
function M.book(id, opts)
  opts = opts or {}
  local book = lulibre.book(id)
  if not book then return 0, 0 end
  local added, replacing = 0, 0
  local candidates = extract.candidates(id)
  if lulibre.o.learned_tags == "propose" then
    -- after the file's own, so a stated subject (arXiv, MSC) is heard first
    candidates[#candidates + 1] = require("lulibre.learn").candidate(id)
    candidates[#candidates + 1] = require("lulibre.refs").candidate(id)
  end
  -- How far the book's sources agree about each field goes with the proposal
  -- as a note ("2/3 agree, 0.21 apart"), and with weigh_sources on its
  -- confidence is what the agreeing sources come to, each taken for what it
  -- has been measured to be worth here.
  local consensus = require "lulibre.consensus"
  local weigh = lulibre.o.weigh_sources and consensus.ready()
  local fused = {}
  for _, w in ipairs(M.wanted(book, candidates, opts)) do
    local confidence, note = w.confidence, nil
    if w.field ~= "identifiers" and w.field ~= "series_index" then
      fused[w.field] = fused[w.field] or consensus.fuse(candidates, w.field) or false
      local f = fused[w.field]
      if f and f.sources > 1 then note = ("%d/%d agree, %.2f apart"):format(f.agree, f.sources, f.disagreement) end
      if f and weigh and consensus.distance(w.field, f.value, w.value) <= consensus.NEAR then confidence = f.confidence end
    end
    if proposals.add(id, w.field, w.value, { op = w.op, source = w.source, confidence = confidence, again = opts.again, note = note }) then
      added = added + 1
      if w.over then replacing = replacing + 1 end
    end
  end
  return added, replacing
end

return M
