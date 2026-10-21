--- Scores how far each book's record can be trusted, and stores the records
-- you confirm as good.
--
-- The score and "good" are separate. The score is lulibre's estimate from
-- what a record holds and how the record looks. A complete record scores
-- high. A record whose title is a file name, or is full of digits and odd
-- characters, scores low. The score ranks what to look at, and only
-- *suggests*.
--
-- "Good" is your decision that a record is right. lulibre learns about the
-- library (the phrases that mark a subject, in learn.lua) only from good
-- records, so mistakes in other records are not learned. :good lists the
-- records by score so you can confirm them.
--
-- @module lulibre.quality
-- @usage
-- local quality = require "lulibre.quality"
-- quality.score(book)         --> 0.82, { "no identifiers", ... }
-- quality.set_good({ 12, 15 }, true)     quality.is_good(12)     quality.good_ids()
local edit = require "lulibre.edit"
local junk = require "lulibre.junk"
local names = require "lulibre.names"

local M = {}

-- subjects that file a book by its form rather than say what it is about;
-- the option subject_catchall adds to these
local CATCHALL = { general = true, papers = true, books = true, handbook = true, misc = true, other = true,
  unsorted = true, various = true }
local catch_text, catch_extra

--- Returns true if a subject is a catch-all, such as math/general or
-- linguistics/papers: a subject that says where a book was filed, not what
-- it is about.
-- @tparam string subject
-- @treturn boolean
function M.catchall(subject)
  local text = lulibre.o.subject_catchall or ""
  if text ~= catch_text then
    local set = {} -- built whole, then put in place (a task may be interrupted)
    for item in text:gmatch("[^,%s]+") do set[item:lower()] = true end
    catch_extra, catch_text = set, text
  end
  local last = (subject or ""):match("([^/]+)$") or ""
  return CATCHALL[last:lower()] or catch_extra[last:lower()] or catch_extra[(subject or ""):lower()] or false
end

-- characters that do not belong in a title: replacement marks, controls, and
-- runs of symbols
local function oddness(title)
  local n = 0
  for _ in title:gmatch("\239\191\189") do n = n + 3 end -- U+FFFD: a character that could not be read
  for _ in title:gmatch("[%c]") do n = n + 3 end
  for _ in title:gmatch("[_|\\<>{}%[%]=~^#@*]") do n = n + 1 end
  for _ in title:gmatch("%p%p%p") do n = n + 1 end
  return n
end

--- Returns a record's score from 0 to 1, and what lowers it. A score of
-- 0.85 or more means nothing is visibly wrong.
-- @tparam table book
-- @treturn number 0 to 1
-- @treturn {string,...} what lowers the score
function M.score(book)
  local s, why = 0, {}
  local title = book.title or ""
  local digits, letters = select(2, title:gsub("%d", "")), select(2, title:gsub("[%a\128-\255]", ""))
  if junk.unlikely_title(title) then
    why[#why + 1] = "the title looks like a file name or a heading"
  else
    s = s + 0.3
    if title == title:upper() and title ~= title:lower() then
      s = s - 0.1
      why[#why + 1] = "title in capitals"
    end
  end
  if digits > 0 and digits * 3 >= letters then
    s = s - 0.2
    why[#why + 1] = "title mostly figures"
  end
  local odd = oddness(title)
  if odd >= 2 then
    s = s - math.min(0.3, 0.1 * odd)
    why[#why + 1] = "odd characters in the title"
  end

  local who = edit.current(book, "authors")
  if who == "" then
    why[#why + 1] = "no author"
  else
    s = s + 0.25
    local bad = false
    for _, a in ipairs(book.authors or {}) do
      if a:find(";") or a:find(" and ", 1, true) or junk.author(a) or names.never(a) or a:find("%d") then bad = true end
    end
    if bad then
      s = s - 0.2
      why[#why + 1] = "an author that is not a name"
    end
  end

  if book.year then s = s + 0.15 else why[#why + 1] = "no date" end

  local topical = false
  for _, t in ipairs(book.tags or {}) do
    if not M.catchall(t) then topical = true end
  end
  if topical then s = s + 0.2
  elseif #(book.tags or {}) > 0 then
    s = s + 0.1
    why[#why + 1] = "only a catch-all subject"
  else
    why[#why + 1] = "no subject"
  end

  -- a work no catalogue has a record of (:noncatalog) is not short of an identifier
  if next(book.idents or {}) or require("lulibre.noncatalog").is(book.id) then s = s + 0.05
  else why[#why + 1] = "no identifiers" end
  if book.publisher or book.series then s = s + 0.05 end
  return math.max(0, math.min(1, s)), why
end

--- Returns true if you have confirmed this record.
-- @tparam integer id
-- @treturn boolean
function M.is_good(id)
  return lulibre.sql("SELECT 1 AS x FROM good WHERE book = ?", id)[1] ~= nil
end

--- Confirms records as good, or removes the confirmation.
-- @tparam {integer,...} ids
-- @tparam boolean on
function M.set_good(ids, on)
  for _, id in ipairs(ids) do
    if on then lulibre.store("INSERT OR IGNORE INTO good(book, ts) VALUES(?, ?)", id, os.time())
    else lulibre.store("DELETE FROM good WHERE book = ?", id) end
  end
end

--- Returns the ids confirmed as good that are still in the library.
-- @treturn {integer,...}
function M.good_ids()
  local out = {}
  for i, r in ipairs(lulibre.sql("SELECT g.book AS id FROM good g JOIN books b ON b.id = g.book ORDER BY g.book")) do out[i] = r.id end
  return out
end

--- Returns every library book with its score, best first.
-- @tparam[opt] table opts `min` leaves out books below that score; `good` keeps
-- only confirmed (true) or only unconfirmed (false) books
-- @treturn {table,...} `{ book=, score=, why=, good= }`
function M.ranked(opts)
  opts = opts or {}
  local good = {}
  for _, id in ipairs(M.good_ids()) do good[id] = true end
  local out = {}
  for _, book in ipairs(lulibre.books("in:library")) do
    local score, why = M.score(book)
    local is = good[book.id] or false
    if score >= (opts.min or 0) and (opts.good == nil or opts.good == is) then
      out[#out + 1] = { book = book, score = score, why = why, good = is }
    end
  end
  table.sort(out, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    return a.book.id < b.book.id
  end)
  return out
end

return M
