--- Is a service's record this book? Titles and people held against each other.
-- Part of lulibre.net: require that, not this (it adds these functions to
-- lulibre.net's table; lulibre/net/core.lua has what they share).
--
-- @submodule lulibre.net
local M = require "lulibre.net.core"

--- Are two titles the same work? Deliberately strict: a wrong match would
-- put someone else's authors on a book.
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

--- Has a record none of the people a book has? (False when either names
-- nobody.) Its authors are then not offered over the book's as if sure.
-- @tparam {string,...} mine
-- @tparam {string,...} theirs
-- @treturn boolean
function M.other_people(mine, theirs)
  return people_in_common(mine, theirs) == false
end

--- Does a record name some of the people a book has and nobody else: the
-- first author alone, where the book has all three? Catalogues often do.
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

--- Is a record's title the book's with words left out ("Extending Python"
-- for "Extending and Embedding Python")? Not something to put over it.
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

--- Is a record that a search for a title turned up the work in hand, and how
-- far can it be believed? mine: the book's title; theirs: the record's;
-- my_authors, their_authors: lists of names, either may be empty. Returns a
-- confidence (0.7 to 0.9) or nil.
--
-- A search always answers with something, and titles share their words:
-- "An introduction to the ipaddress module" brought back "An Introduction to
-- Module Theory", and two words in three were once enough. Now the titles
-- must say the same thing: the same telling words (0.8), or one of them the
-- other with something after it, a subtitle or the author's name run on
-- (0.7), and then only when four words or more are shared. A short title
-- ("Algebraic Geometry", "The Galois Correspondence") is many works': it
-- counts only when an author's family name is in the record too. Agreeing
-- authors add to the confidence; authors on both sides with no name in
-- common mean another work, whatever the titles say.
-- @tparam string mine
-- @tparam string theirs
-- @tparam {string,...} my_authors
-- @tparam {string,...} their_authors
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

--- Is a record that an identifier led to the record of the book in hand?
-- An identifier can be wrong: read off a page where it stood for a cited
-- work, written by an earlier mistake, or a chapter's or a review's in
-- place of the book's. rec: the record. titles: the book's own title, when
-- it has one worth the name, and those its file shows. authors: the book's,
-- when it has any worth the name. head: how the file's text opens.
--
-- It is the book's record when the titles say the same thing, or the
-- record's title stands in the opening of the file. A looser likeness (a
-- title cut short, most of the words) counts unless the authors plainly
-- differ, which is how a review "..., by Sutton and Barto" is told from
-- the book. With no likeness at all, an author in common is enough: the
-- same people's work under another form of its title, or the book this
-- is a part of; the third value is then "people", and the record's title
-- is not one to put over the book's.
-- Returns true, or false and whether both title and authors speak
-- against it (the identifier is then very likely another work's).
-- @tparam table rec
-- @tparam {string,...} titles
-- @tparam {string,...} authors
-- @tparam[opt] string head
-- @treturn[1] boolean true
-- @treturn[1] string|nil "people" when only an author is in common
-- @treturn[2] boolean false
-- @treturn[2] boolean both title and authors speak against it
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
