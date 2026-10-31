--- How much of a value is on a file's pages, and whether an online record
-- is the book the file holds.
--
-- What is counted is kept per file and value (lulib._kept), and what it
-- scores is worked out from the count: changing a setting reads nothing
-- again. A record's score is its title's on the pages, plus what its
-- authors found there add; with a page count too far from the file's it is
-- not the book, whatever its score. A record with no page count, or a file
-- with none, is not judged by it.
--
-- The settings: check_title_k, check_title_base, check_authors, check_pages,
-- check_same.
--
-- @library lulib._check
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

--- An online record against the file: `{ score=, same=, length= }`, or nil
-- when the file has no text to compare it with.
-- @tparam table r `{ fields=, pages= }`
-- @tparam table file a row of bookman.files
-- @param kept the file's lulib._kept
-- @param text an object whose `get()` gives the file's txt
-- @tparam table c M.settings()
function M.record(r, file, kept, text, c)
  if not r.fields.title then
    return { score = 0, same = false }
  end
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
