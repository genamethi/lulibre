--- Decides whether a service's record is this book, by comparing titles
-- and people.
-- This file is part of lulibre.net. Require lulibre.net, which adds this
-- file's functions to its table; the shared code is in lulibre/net/core.lua.
--
-- @submodule lulibre.net
local M = require "lulibre.net.core"

--- Returns true if two titles are the same work. The test is strict on
-- purpose, since a wrong match would put another work's authors on a book.
-- @tparam string a
-- @tparam string b
-- @treturn boolean
function M.same_title(a, b)
  local stop = { the = 1, a = 1, an = 1, of = 1, ["in"] = 1, on = 1, ["for"] = 1, ["and"] = 1, to = 1, with = 1,
    by = 1, from = 1, at = 1, is = 1, are = 1 }
  local function words(s)
    local set, n = {}, 0
    for w in lulibre.fold(s):gmatch("[%w]+") do
      if not stop[w] and not set[w] then
        set[w] = true
        n = n + 1
      end
    end
    return set, n
  end
  local wa, na = words(a)
  local wb, nb = words(b)
  if na == 0 or nb == 0 then return false end
  local both = 0
  for w in pairs(wa) do
    if wb[w] then both = both + 1 end
  end
  if na <= 3 or nb <= 3 then return both / math.max(na, nb) > 0.6 end
  return both >= 3 and both / (na + nb - both) > 0.4
end

-- the words of a title that tell it from another, in order
local TITLE_STOP = { the = 1, a = 1, an = 1, of = 1, ["in"] = 1, on = 1, ["for"] = 1, ["and"] = 1, to = 1, with = 1,
  by = 1, from = 1, at = 1, is = 1, are = 1 }
local function title_words(s)
  local list, seen = {}, {}
  for w in lulibre.fold(s or ""):gmatch("[%w]+") do
    if not TITLE_STOP[w] and not seen[w] then
      seen[w] = true
      list[#list + 1] = w
    end
  end
  return list, seen
end

-- family names, folded: of "Given Family", "Family, Given" and "G. Family"
local function family_names(people)
  local set, n = {}, 0
  for _, name in ipairs(people or {}) do
    local low = lulibre.fold(name)
    local family = low:match("^([^,]+),") or low
    local last
    for w in family:gmatch("[%a][%a'%-]+") do last = w end
    if last and not set[last] then
      set[last] = true
      n = n + 1
    end
  end
  return set, n
end

-- how many letters apart two words are (insert, drop, change)
local function apart(a, b)
  if math.abs(#a - #b) > 2 then return 3 end
  local prev = {}
  for j = 0, #b do prev[j] = j end
  for i = 1, #a do
    local cur = { [0] = i }
    for j = 1, #b do
      cur[j] = math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a:byte(i) == b:byte(j) and 0 or 1))
    end
    prev = cur
  end
  return prev[#b]
end

-- Do two lists of people have somebody in common, going by family names?
-- true, false, or nil when either list is empty. A name spelled a little
-- differently is the same name ("Bugrii" and "Bugrij", "Schloze" for
-- "Scholze"): that is what a record is there to put right.
local function people_in_common(mine, theirs)
  local fa, na = family_names(mine)
  local fb, nb = family_names(theirs)
  if na == 0 or nb == 0 then return nil end
  for x in pairs(fa) do
    if fb[x] then return true end
    for y in pairs(fb) do
      if #x >= 5 and #y >= 5 and apart(x, y) <= (math.min(#x, #y) >= 7 and 2 or 1) then return true end
    end
  end
  return false
end

--- Returns true if a record has none of the book's people. Returns false if
-- either names nobody. If true, the record's authors are not offered over
-- the book's as if they were sure.
-- @tparam {string,...} mine
-- @tparam {string,...} theirs
-- @treturn boolean
function M.other_people(mine, theirs)
  return people_in_common(mine, theirs) == false
end

--- Returns true if a record names some of the book's people and nobody
-- else, such as the first author alone where the book has all three.
-- Catalogues often do this.
-- @tparam {string,...} mine
-- @tparam {string,...} theirs
-- @treturn boolean
function M.fewer_people(mine, theirs)
  local fa, na = family_names(mine)
  local fb, nb = family_names(theirs)
  if nb == 0 or nb >= na then return false end
  for y in pairs(fb) do
    if not fa[y] then return false end
  end
  return true
end

--- Returns true if a record's title is the book's title with words left out
-- ("Extending Python" for "Extending and Embedding Python"). Such a title
-- should not replace the book's.
-- @tparam string mine
-- @tparam string theirs
-- @treturn boolean
function M.shorter_title(mine, theirs)
  local a, sa = title_words(mine)
  local b = title_words(theirs)
  if #b == 0 or #b >= #a then return false end
  for _, w in ipairs(b) do
    if not sa[w] then return false end
  end
  return true
end

--- Returns how far a record from a title search can be believed to be the
-- book: a confidence from 0.7 to 0.9, or nil if the record is another work.
--
-- A search always returns something, and titles share words. "An
-- introduction to the ipaddress module" once brought back "An Introduction
-- to Module Theory", when two words in three were enough. Now the titles
-- must mean the same: the same significant words (0.8), or one title is
-- the other plus a subtitle or the author's name (0.7), and then only if
-- they share four words or more. A short title ("Algebraic Geometry", "The
-- Galois Correspondence") belongs to many works, so it counts only if an
-- author's family name is in the record too. Matching authors raise the
-- confidence. If both sides name authors and no name is in common, the
-- record is another work, whatever the titles say.
-- @tparam string mine the book's title
-- @tparam string theirs the record's title
-- @tparam {string,...} my_authors may be empty
-- @tparam {string,...} their_authors may be empty
-- @treturn number|nil
function M.title_match(mine, theirs, my_authors, their_authors)
  local a, sa = title_words(mine)
  local b, sb = title_words(theirs)
  if #a == 0 or #b == 0 then return nil end
  local short, long, in_long = a, b, sb
  if #b < #a then short, long, in_long = b, a, sa end
  local same = #a == #b
  for _, w in ipairs(short) do
    if not in_long[w] then same = false end
  end
  local runs_on = false
  if not same and #short >= 4 then
    runs_on = true
    for i, w in ipairs(short) do
      if long[i] ~= w then runs_on = false end
    end
  end
  if not same and not runs_on then return nil end
  local agree = people_in_common(my_authors, their_authors)
  if agree == false then return nil end
  if same then return agree and 0.9 or (#short >= 4 and 0.8 or nil) end
  return agree and 0.85 or 0.7
end

--- Returns true if a record found by an identifier is the book's record.
-- An identifier can be wrong: read from a page where it belonged to a
-- cited work, written by an earlier mistake, or a chapter's or a review's
-- identifier instead of the book's.
--
-- The record is the book's if the titles mean the same, or if the record's
-- title appears at the start of the file. A looser likeness (a shortened
-- title, most of the words) counts unless the authors clearly differ; that
-- is how a review "..., by Sutton and Barto" is told from the book. With no
-- likeness at all, an author in common is enough: the record may be the
-- same people's work under another form of the title, or the book that
-- contains this one. The second value is then "people", and the record's
-- title should not replace the book's.
-- @tparam table rec the record
-- @tparam {string,...} titles the book's own title, if it is a real title, and the titles its file shows
-- @tparam {string,...} authors the book's authors, if they are real names
-- @tparam[opt] string head the start of the file's text
-- @treturn[1] boolean true
-- @treturn[1] string|nil "people" if only an author is in common
-- @treturn[2] boolean false
-- @treturn[2] boolean true if both title and authors are against the record, so the
-- identifier very likely belongs to another work
function M.fits(rec, titles, authors, head)
  if not rec.title or (#(titles or {}) == 0 and #(authors or {}) == 0) then return true end
  local agree = people_in_common(authors, rec.authors)
  local theirs, their_set = title_words(rec.title)
  local folded = lulibre.fold(rec.title)
  local alike = false
  for _, title in ipairs(titles or {}) do
    local mine, my_set = title_words(title)
    local same = #mine == #theirs and #mine > 0
    for _, w in ipairs(mine) do
      if not their_set[w] then same = false end
    end
    if same then return true end
    local low = lulibre.fold(title)
    -- the book's title with a subtitle after it is the book
    if #low >= 12 and folded:sub(1, #low) == low and folded:sub(#low + 1):find("^%s*[:%.%-(]") then return true end
    if M.same_title(title, rec.title) or (#low >= 12 and folded:sub(1, #low) == low) or (#folded >= 12 and low:sub(1, #folded) == folded) then
      alike = true
    end
    local _ = my_set
  end
  -- the record's title, word for word, in the opening of the file (its first six telling words, at least three)
  if head and head ~= "" then
    local want = {}
    for w in folded:gmatch("[%w]+") do
      if not TITLE_STOP[w] and #want < 6 then want[#want + 1] = w end
    end
    if #want >= 3 then
      local opening = {}
      for w in lulibre.fold(head):gmatch("[%w]+") do
        if not TITLE_STOP[w] then opening[#opening + 1] = w end
      end
      if (" " .. table.concat(opening, " ") .. " "):find(" " .. table.concat(want, " ") .. " ", 1, true) then return true end
    end
  end
  if alike then return agree ~= false, false end
  if agree then return true, false, #(titles or {}) > 0 and "people" or nil end
  return false, agree == false and #(titles or {}) > 0
end

return M
