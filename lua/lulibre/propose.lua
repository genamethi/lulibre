-- Deciding what to propose for a book from what its file says.
--
-- A field that is empty, or holds what is plainly not a value (a file name
-- for a title), is a gap, and the file's best candidate is proposed for it.
-- A field that holds a value is another matter: the value may be right and
-- the file's title page misread, or the value may be a slip of the hand and
-- the file right. How far the file is believed over what the book already
-- says is the option `propose_over`:
--
--   "gaps"   never: only gaps are proposed for
--   "sure"   when the file's evidence is strong (confidence 0.8 or more:
--            a stated identifier, a labelled cover sheet, a clear title
--            page) and says something different
--   "any"    whenever the file's best candidate differs
--
-- Whatever the option, the value the book has is never treated as surer
-- than the file's because someone typed it: review shows both side by side
-- and the decision is made there.
--
--   local propose = require "lulibre.propose"
--   propose.wanted(book, candidates, "sure")   --> { {field=, value=, op=, source=, confidence=, over=}, ... }
--   propose.book(id, { over = "any", again = true })   --> proposals added, how many replace a value
local edit = require "lulibre.edit"
local extract = require "lulibre.extract"
local junk = require "lulibre.junk"
local names = require "lulibre.names"
local proposals = require "lulibre.proposals"

local M = {}

-- how sure the file must be to be proposed over a value, under "sure"
M.SURE = 0.8

-- a value reduced to what matters when asking "do these say the same?":
-- case, accents, the shape of quotes and dashes, punctuation and spacing do not
local function plain(s)
  s = (s or ""):gsub("[‘’`´]", "'"):gsub("[“”„]", '"'):gsub("[–—]", "-")
  s = lulibre.fold(s):gsub("%p", " "):gsub("%s+", " ")
  return (s:gsub("^ ", ""):gsub(" $", ""))
end

--- Do two values of a field say the same thing? Authors are compared as a
-- set of names; dates by year when either gives no more than a year.
function M.same(field, a, b)
  if field == "authors" then
    local function names(s)
      local out = {}
      for _, n in ipairs(edit.split("authors", s)) do out[#out + 1] = plain(n) end
      table.sort(out)
      return table.concat(out, "|")
    end
    return names(a) == names(b)
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

--- Is a field's value no value at all: empty, or something that is plainly
-- not one? A title that is a file name, a number or a heading; an author
-- that is the program that made the file, a web site, a rank. Such a value
-- has no claim to stay, and whatever the file offers is proposed for it.
function M.is_gap(field, cur)
  if cur == "" then return true end
  if field == "title" then
    if junk.title(cur) or not cur:find("%s") then return true end
    local digits, letters = select(2, cur:gsub("%d", "")), select(2, cur:gsub("[%a\128-\255]", ""))
    return digits > 0 and digits * 3 >= letters -- mostly figures
  end
  if field == "authors" then
    for _, a in ipairs(edit.split("authors", cur)) do
      if not (junk.author(a) or names.never(a) or a:find("%.%a%a%a?$") or a:find("%d%d")) then return false end
    end
    return true -- every one of them is junk
  end
  return false
end
local is_gap = M.is_gap

-- the letters and names a field goes by, for --only and for review's filter
M.FIELD = { t = "title", title = "title", a = "authors", author = "authors", authors = "authors", s = "tags",
  subject = "tags", tags = "tags", tag = "tags", i = "identifiers", id = "identifiers", ids = "identifiers",
  identifiers = "identifiers", identifier = "identifiers", d = "pubdate", date = "pubdate", pubdate = "pubdate",
  year = "pubdate", p = "publisher", publisher = "publisher", e = "series", series = "series",
  series_index = "series_index", n = "series_index" }

--- "title,authors" or "t,a" as a set of field names; nil and the offending
-- word when one is not a field.
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

--- Which of a file's candidates (strongest first within a field, as
-- extract gives them) are worth proposing for a book. over: "gaps", "sure"
-- or "any" (default: the option propose_over). Each result carries
-- over = true when it would replace a value the book has.
-- opts (in place of over, a table): over as above; only: a set of fields to
-- keep to; fresh: propose as if the fields were empty, whatever they hold.
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
        local replaces = cur ~= "" and not is_gap(c.field, cur)
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
        if is_gap(c.field, cur) then
          want = cur == "" or not M.same(c.field, cur, c.value) -- a one-word title may simply be the title
        elseif over ~= "gaps" and not M.same(c.field, cur, c.value)
          and (over == "any" or (c.confidence or 0) >= M.SURE) then
          want, replaces = true, true
        end
      end
    elseif c.field == "tags" then
      -- a stated subject (arXiv class, MSC) is worth adding; vocabulary only fills a gap
      op = "add"
      if cur == "" then want = (c.confidence or 0) >= 0.9 or not settled.tags
      else want = over ~= "gaps" and (c.confidence or 0) >= 0.9 end
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

--- Propose for one book from its file. opts.over, opts.only and opts.fresh
-- as for M.wanted; opts.again proposes even what was rejected before. Returns how many
-- proposals were added, and how many of them replace a value the book has.
function M.book(id, opts)
  opts = opts or {}
  local book = lulibre.book(id)
  if not book then return 0, 0 end
  local added, replacing = 0, 0
  local candidates = extract.candidates(id)
  if lulibre.o.subject_learned == "propose" then
    -- after the file's own, so a stated subject (arXiv, MSC) is heard first
    candidates[#candidates + 1] = require("lulibre.learn").candidate(id)
    candidates[#candidates + 1] = require("lulibre.refs").candidate(id)
  end
  for _, w in ipairs(M.wanted(book, candidates, opts)) do
    if proposals.add(id, w.field, w.value, { op = w.op, source = w.source, confidence = w.confidence, again = opts.again }) then
      added = added + 1
      if w.over then replacing = replacing + 1 end
    end
  end
  return added, replacing
end

return M
