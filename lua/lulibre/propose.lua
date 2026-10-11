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
    local ya, yb = (a or ""):match("^%d%d%d%d"), (b or ""):match("^%d%d%d%d")
    local bare = (a or ""):match("^%d%d%d%d$") or (b or ""):match("^%d%d%d%d$")
      or (a or ""):match("%-01%-01$") or (b or ""):match("%-01%-01$")
    if ya and yb and bare then return ya == yb end
  end
  return plain(a) == plain(b)
end

local function is_gap(field, cur)
  if field == "title" then return junk.title(cur) or not cur:find("%s") end
  return cur == ""
end

local SINGLE = { title = true, authors = true, pubdate = true, publisher = true }

--- Which of a file's candidates (strongest first within a field, as
-- extract gives them) are worth proposing for a book. over: "gaps", "sure"
-- or "any" (default: the option propose_over). Each result carries
-- over = true when it would replace a value the book has.
function M.wanted(book, candidates, over)
  over = over or lulibre.o.propose_over
  local out, settled = {}, {}
  for _, c in ipairs(candidates) do
    local cur = edit.current(book, c.field)
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
  return out
end

--- Propose for one book from its file. opts.over as for M.wanted;
-- opts.again proposes even what was rejected before. Returns how many
-- proposals were added, and how many of them replace a value the book has.
function M.book(id, opts)
  opts = opts or {}
  local book = lulibre.book(id)
  if not book then return 0, 0 end
  local added, replacing = 0, 0
  for _, w in ipairs(M.wanted(book, extract.candidates(id), opts.over)) do
    if proposals.add(id, w.field, w.value, { op = w.op, source = w.source, confidence = w.confidence, again = opts.again }) then
      added = added + 1
      if w.over then replacing = replacing + 1 end
    end
  end
  return added, replacing
end

return M
