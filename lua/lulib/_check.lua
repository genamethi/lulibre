--- How much of a value is on a file's pages, and whether an online record
-- is the book the file holds.
--
-- What is counted is kept per file and value (lulib._kept), and what it
-- scores is worked out from the count: changing a setting reads nothing
-- again. A record's score is its title's on the pages, plus what its
-- authors found there add; with a page count too far from the file's it is
-- not the book, whatever its score. A record with no page count, or a file
-- with none, is not judged by it; a file whose text can't be read judges
-- nothing.
--
-- The settings: check_title_k, check_title_base, check_authors, check_pages,
-- check_same.
--
-- @library lulib._check
local expr = require "expr"
local mesr = require "mesr"

local M = {}

--- The words a title's score does not count: articles, prepositions and
-- other small words, in the folded form. Add to it in init.lua.
M.minor = {}
for w in ([[a an the of and or in on at to for from by with without into onto over under as is are
  its it this that these those some about between via de la le les el del der die das und du et al]]):gmatch("%S+") do
  M.minor[w] = true
end

--- The settings a check goes by, taken once by the command (design 3).
function M.settings()
  local k <const>, base <const>, authors <const>, pages <const>, same <const> =
    setman.get("check_title_k", "check_title_base", "check_authors", "check_pages", "check_same")
  return { k = k, base = base, authors = authors, pages = pages, same = same }
end

-- what of a value is looked for on the pages: authors by their last names,
-- a date by its year, the rest by its words
local function looked_for(field, value)
  if field == "authors" then
    local names = {}
    for person in (value .. "&"):gmatch("%s*(.-)%s*&") do
      names[#names + 1] = person:match("([^%s,]+)$")
    end
    return table.concat(names, " ")
  end
  if field == "pubdate" then return value:match("%d%d%d%d") or value end
  return value
end

--- How much of a value the pages hold, kept: found, words.
-- @tparam string field
-- @tparam string value
-- @param kept the file's lulib._kept
-- @param text an object whose `get()` gives the file's txt
-- @treturn integer|nil found; nil when the file has no text
-- @treturn integer|nil how many words were looked for
function M.count(field, value, kept, text)
  local key = field .. "\0" .. value
  local c = kept:get("check", key)
  if not c then
    local t = text.get()
    if not t then return nil end
    local found, words = mesr.found(looked_for(field, value), t.text, M.minor)
    c = { found, words }
    kept:put("check", key, c)
  end
  return c[1], c[2]
end

--- A value's share on the pages, 0 to 1, or nil when the file has no text.
function M.share(field, value, kept, text)
  local found, words = M.count(field, value, kept, text)
  if not found then return nil end
  return words > 0 and found / words or 0
end

--- A title's score on the pages: min(1, k * found / words + base).
function M.title(found, words, c)
  if words == 0 then return c.base end
  return math.min(1, c.k * found / words + c.base)
end

--- Whether a record's page count fits the file's, or nil if it can't be
-- told.
function M.length(record_pages, file_pages, c)
  if not record_pages or not file_pages or file_pages <= 0 then return nil end
  return math.abs(record_pages - file_pages) <= c.pages * file_pages
end

-- a title's significant words, folded, in order, and as a set
local function title_words(s)
  local list, seen = {}, {}
  for w in expr.fold(s or ""):gmatch("[%w]+") do
    if not M.minor[w] and not seen[w] then
      seen[w] = true
      list[#list + 1] = w
    end
  end
  return list, seen
end

-- family names, folded: of "Given Family", "Family, Given" and "G. Family"
local function family_names(people)
  local set, n = {}, 0
  for name in ((people or "") .. " & "):gmatch("(.-) & ") do
    local low = expr.fold(name)
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

-- how many letters apart two words are, at most 3
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

-- Do two lists of people, "A & B", have somebody in common, by family names?
-- nil when either has none. A name spelled a little differently is the same name.
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

--- Whether two titles can be one work: the same significant words, or one the
-- other plus a subtitle, and then only with four words or more. Also how many
-- words the shorter has.
-- @treturn boolean
-- @treturn integer
function M.titles_agree(mine, theirs)
  local a, sa = title_words(mine)
  local b, sb = title_words(theirs)
  if #a == 0 or #b == 0 then return false, 0 end
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
  return same or runs_on, #short
end

--- Whether a record a title search found is the same work. A search always
-- returns something, and titles share words: they must agree (titles_agree). A
-- short title belongs to many works, so under four words it counts only with an
-- author in common. Both sides naming authors with none in common is another
-- work, whatever the titles say.
-- @tparam string mine
-- @tparam string theirs
-- @tparam[opt] string my_authors "A & B"
-- @tparam[opt] string their_authors "A & B"
-- @treturn boolean
function M.title_match(mine, theirs, my_authors, their_authors)
  local agree_titles, words = M.titles_agree(mine, theirs)
  if not agree_titles then return false end
  local agree = people_in_common(my_authors, their_authors)
  if agree == false then return false end
  return agree == true or words >= 4
end

-- Text as words: folded; the accents TeX leaves beside their letter dropped;
-- punctuation, symbols and figures glued to a name apart.
local LOOSE_ACCENTS = { "\194\180", "\194\168", "\194\184", "\203\134", "\203\156", "\203\153", "`" }
local function each_word(text, fn)
  local t = expr.fold(text or "")
  for _, a in ipairs(LOOSE_ACCENTS) do t = t:gsub(a, "") end
  t = t:gsub("\226[\128-\191][\128-\191]", " "):gsub("\194[\128-\191]", " ")
  for w in t:gmatch("[%a\128-\255]+") do fn(w) end
  for w in t:gmatch("%d+") do fn(w) end
end

-- the longest run of a value's words found in a text's order, as a share
local function phrase_in(value, text)
  local want = {}
  each_word(value, function(w)
    if not M.minor[w] then want[#want + 1] = w end
  end)
  if #want == 0 then return nil end
  local seq, at = {}, {}
  each_word(text, function(w)
    if not M.minor[w] and not w:match("^%d+$") then
      seq[#seq + 1] = w
      at[w] = at[w] or {}
      table.insert(at[w], #seq)
    end
  end)
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

--- How much of a title the pages hold in its own word order: the longest run of its
-- significant words that stands in that order, as a share of them, kept. "On Predicate
-- Logic as Modal Logic" against pages that say "Modal Predicate Logic" shares every
-- word, but its longest run is two of four. nil with no text or no words.
function M.phrase(value, k, text)
  local key = "phrase\0" .. value
  local v = k:get("check", key)
  if v == nil then
    local t = text.get()
    if not t then return nil end
    v = phrase_in(value, t.text) or false
    k:put("check", key, v)
  end
  return v or nil
end

--- How many pages `headline` reads type sizes from.
M.HEADLINE_PAGES = 3

--- How much of a title the largest type of the first pages holds, as `phrase`
-- measures it, kept: a title page sets the title there, and a section heading is
-- smaller than the title above it. nil with no text or no words.
function M.headline(value, k, text)
  local key = "headline\0" .. value
  local v = k:get("check", key)
  if v == nil then
    local t = text.get()
    if not t then return nil end
    local parts, by_page = {}, {}
    for i = 1, #t do
      local l = t:line(i)
      if l.page > M.HEADLINE_PAGES then break end
      -- (a line set sideways is arXiv's stamp in the margin, not the title)
      if not l.rotated then
        by_page[l.page] = by_page[l.page] or {}
        table.insert(by_page[l.page], l)
      end
    end
    for page = 1, M.HEADLINE_PAGES do
      local top = 0
      for _, l in ipairs(by_page[page] or {}) do
        if (l.size or 0) > top then top = l.size end
      end
      for _, l in ipairs(by_page[page] or {}) do
        if top > 0 and (l.size or 0) >= top * 0.8 then parts[#parts + 1] = l.text end
      end
    end
    v = phrase_in(value, table.concat(parts, "\n")) or false
    k:put("check", key, v)
  end
  return v or nil
end

--- An online record against the file: `{ score=, same=, length= }`, or nil
-- when the file has no text it can compare it with.
-- @tparam table r `{ fields=, pages= }`
-- @tparam table file a row of bookman.files
-- @param kept the file's lulib._kept
-- @param text an object whose `get()` gives the file's txt
-- @tparam table c M.settings()
function M.record(r, file, kept, text, c)
  if not r.fields.title then
    return { score = 0, same = false }
  end
  if file.usable == false then return nil end
  local found, words = M.count("title", r.fields.title, kept, text)
  if not found then return nil end
  local score = M.title(found, words, c)
  if r.fields.authors then
    local share = M.share("authors", r.fields.authors, kept, text)
    score = math.min(1, score + c.authors * (share or 0))
  end
  local length = M.length(r.pages, file.pages, c)
  return { score = score, length = length, same = score >= c.same and length ~= false }
end

return M
