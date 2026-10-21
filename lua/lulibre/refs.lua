--- Reads the bibliography at the end of a book, and finds what books that
-- cite the same works have in common.
--
-- The index holds each file's first pages, but a bibliography is on the
-- last pages. `index_book` reads the last pages (the option refs_pages sets
-- how many), finds the bibliography's heading, cuts the text after it into
-- entries, and gives each entry a key. The key recognises the same work in
-- another book's list, however each list writes it:
--
--   doi:10.1090/s0002-9947                     if the entry gives a DOI
--   arxiv:1012.6008                            or an arXiv number
--   bogoliubov:1957:227                        else first author, year, first page
--   serre:1973                                 or author and year, for a book
--
-- The keys are stored in the table `refs`. refs never uses the network.
--
-- @module lulibre.refs
-- @usage
-- local refs = require "lulibre.refs"
-- refs.index_book(id)             --> how many entries were found (waits: it reads the file)
-- refs.of(id)                     --> { {key=, raw=}, ... }
-- refs.coupled(id)                --> { {book=, shared=, weight=}, ... } the books that cite the same works
-- refs.subject(id)                --> subject, confidence, how many books say so; or nil
local ids = require "lulibre.ids"
local quality = require "lulibre.quality"

local M = {}

-- the words a bibliography is headed with
local HEADS = { references = true, bibliography = true, literature = true, ["literature cited"] = true,
  ["works cited"] = true, ["references cited"] = true, reference = true, bibliographie = true, literatur = true,
  ["références"] = true, references_and_notes = true, ["cited literature"] = true, ["selected bibliography"] = true }

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Returns true if a line is a bibliography's heading: a short line with
-- one of the usual words and nothing else, numbered or not ("7.
-- References", "REFERENCES"). A table of contents line ("References 213")
-- is not a heading.
-- @tparam string text
-- @treturn boolean
function M.is_heading(text)
  local t = trim(text or ""):lower():gsub("^[%divxlc]+[.)]?%s+", ""):gsub("[.:]$", "")
  return #t <= 30 and HEADS[t] == true
end

--- Returns the lines under the last bibliography heading of a file's
-- closing pages, and the heading's page.
-- @tparam {table,...} pages as `lulibre.extract` gives them: `{ {lines = { {text=, x0=, size=}, ... }}, ... }`
-- @treturn {table,...}|nil the lines, or nil if no heading is found
-- @treturn[opt] integer the heading's page
function M.find(pages)
  local at_page, at_line
  for p, page in ipairs(pages) do
    for k, line in ipairs(page.lines or {}) do
      if M.is_heading(line.text) then at_page, at_line = p, k end
    end
  end
  if not at_page then return nil end
  local out = {}
  for p = at_page, #pages do
    local lines = pages[p].lines or {}
    for k = (p == at_page and at_line + 1 or 1), #lines do
      local t = trim(lines[k].text)
      -- not page numbers and running heads
      if t ~= "" and not t:find("^%d+$") and not M.is_heading(t) then out[#out + 1] = lines[k] end
    end
  end
  return out, pages[at_page].no
end

local function starts(text)
  return text:find("^%[[%w+%-,. ]-%]") or text:find("^%d+%.%s") or text:find("^%(%d+%)%s") or text:find("^%d+%s+%u")
end

--- Cuts the lines of a bibliography into entries. If most entries are
-- numbered ("[1]", "[Se73]", "1."), the numbers separate them. Otherwise
-- the hanging indent does: each entry's first line starts further left
-- than the lines that continue it.
-- @tparam {table,...} lines
-- @treturn {string,...}
function M.entries(lines)
  if #lines == 0 then return {} end
  local numbered, left = 0, math.huge
  for _, l in ipairs(lines) do
    if starts(trim(l.text)) then numbered = numbered + 1 end
    if l.x0 and l.x0 < left then left = l.x0 end
  end
  local by_number = numbered * 5 >= #lines
  local out, cur = {}, nil
  local function close()
    if cur then out[#out + 1] = cur:gsub("(%a)%-%s+(%l)", "%1%2"):gsub("%s+", " ") end
    cur = nil
  end
  for _, l in ipairs(lines) do
    local t = trim(l.text)
    local first
    if by_number then first = starts(t) ~= nil
    else first = l.x0 ~= nil and l.x0 <= left + 3 and t:find("^[%u\128-\255]") ~= nil end
    if first or not cur then
      close()
      cur = t
    else
      cur = cur .. " " .. t
    end
  end
  close()
  return out
end

local NOT_SURNAME = { ["and"] = true, ["the"] = true, ["von"] = true, ["van"] = true, ["de"] = true, ["der"] = true,
  ["la"] = true, ["le"] = true, ["du"] = true, ["et"] = true, ["al"] = true, ["eds"] = true, ["ed"] = true }

--- Returns an entry's key, which identifies the same work in another
-- book's list. Returns nil for a line that is not a reference.
-- @tparam string entry
-- @treturn string|nil
function M.key(entry)
  local doi = ids.doi(entry)
  if doi then return "doi:" .. doi:lower() end
  local arxiv = entry:match("ar[Xx]iv[:%s]*(%d%d%d%d%.%d%d%d%d%d?)") or entry:match("ar[Xx]iv[:%s]*([%a%-]+/%d%d%d%d%d%d%d)")
  if arxiv then return "arxiv:" .. arxiv:lower() end
  local body = entry:gsub("^%[[^%]]*%]%s*", ""):gsub("^%(?%d+[.)]?%s+", "")
  -- The first author's surname. Lists write a name either way round ("F. V.
  -- Atkinson, Some aspects", "Abdulali, S. 1994", "Jean Dieudonné and
  -- Alexander Grothendieck, Éléments"), so the first author is what stands
  -- before the first comma, "and", colon or year, and the surname its last
  -- word that is not an initial.
  local head = body:sub(1, 90)
  local cut = #head + 1
  for _, pat in ipairs { ",", "%f[%a]and%f[%A]", "%f[%a]et%f[%A]", "&", ":", ";", "%(", "%f[%d][12]%d%d%d%f[%D]", "%l%l%l%.%s" } do
    local at, to = head:find(pat)
    if at and pat == "%l%l%l%.%s" then at = to - 1 end -- keep the word, drop its full stop
    if at and at < cut then cut = at end
  end
  local surname
  for word in head:sub(1, cut - 1):gmatch("[%a\128-\255'%-]+%.?") do
    local low = lulibre.fold(word)
    if not word:find("%.$") and #word >= 2 and word:find("^[%u\128-\255]") and not NOT_SURNAME[low] then
      surname = low:gsub("[^%a]", "") -- the last such word wins
    end
  end
  -- the year: the last one the entry gives
  local year
  for y in entry:gmatch("%f[%d]([12]%d%d%d)%f[%D]") do
    local n = tonumber(y)
    if n >= 1700 and n <= 2099 then year = y end
  end
  if not surname or #surname < 3 or not year then return nil end
  -- the first page of the pages it gives, where it gives them
  local page = entry:match("%f[%d](%d+)%s*[–%-]+%s*%d+%f[%D]%s*%.?%s*$") or entry:match("pp?%.%s*(%d+)%s*[–%-]")
    or entry:match("%f[%d](%d%d+)%s*[–%-]+%s*%d%d+%f[%D]")
  if page and tonumber(page) ~= tonumber(year) then return ("%s:%s:%s"):format(surname, year, page) end
  return ("%s:%s"):format(surname, year)
end

--- Reads a book's bibliography from its file and stores the keys. Waits.
-- @tparam integer id
-- @tparam[opt] table opts `pages`: how many closing pages to read (the option refs_pages by default)
-- @treturn[1] integer how many entries were stored
-- @treturn[2] nil
-- @treturn[2] string why none
function M.index_book(id, opts)
  local file = lulibre.files(id)[1]
  if not file then return nil, "no file" end
  local n = opts and opts.pages or tonumber(lulibre.o.refs_pages) or 14
  local doc, err = lulibre.extract(file.path, { pages = n, layout_pages = n, tail = true })
  if not doc then return nil, err end
  lulibre.store("DELETE FROM refs WHERE book = ?", id)
  lulibre.store("INSERT OR REPLACE INTO kv(key, value) VALUES(?, ?)", "refs:" .. id, tostring(os.time()))
  local lines = M.find(doc.page)
  if not lines then return 0 end
  local kept = 0
  for _, entry in ipairs(M.entries(lines)) do
    local key = #entry >= 20 and #entry <= 900 and M.key(entry)
    if key then
      lulibre.store("INSERT OR IGNORE INTO refs(book, key, raw) VALUES(?, ?, ?)", id, key, entry:sub(1, 300))
      kept = kept + 1
    end
  end
  return kept
end

--- Returns true if the book's bibliography has been looked for already.
-- @tparam integer id
-- @treturn boolean
function M.done(id)
  return lulibre.sql("SELECT 1 AS x FROM kv WHERE key = ?", "refs:" .. id)[1] ~= nil
end

--- Returns what a book cites, as it was read.
-- @tparam integer id
-- @treturn {table,...} `{ {key=, raw=}, ... }`
function M.of(id)
  return lulibre.sql("SELECT key, raw FROM refs WHERE book = ? ORDER BY key", id)
end

--- Returns the books that cite works this book cites, the strongest links
-- first. A work half the library cites counts for little; a work only two
-- books cite counts for much.
-- @tparam integer id
-- @tparam[opt] integer limit
-- @treturn {table,...} `{ {book=, shared=, weight=}, ... }`
function M.coupled(id, limit)
  return lulibre.sql([[
    SELECT o.book AS book, count(*) AS shared,
           sum(1.0 / (SELECT count(*) FROM refs d WHERE d.key = o.key)) AS weight
    FROM refs mine JOIN refs o ON o.key = mine.key AND o.book <> mine.book
    WHERE mine.book = ? GROUP BY o.book ORDER BY weight DESC, shared DESC LIMIT ?]], id, limit or 20)
end

--- Returns the subject of the books that cite what this book cites, how
-- sure the subject is, and how many books support it. Returns nil unless
-- at least two books share at least two cited works with this book.
-- @tparam integer id
-- @treturn[1] string
-- @treturn[1] number how sure
-- @treturn[1] integer how many books
-- @treturn[2] nil
function M.subject(id)
  local score, books = {}, {}
  for _, c in ipairs(M.coupled(id, 30)) do
    if c.shared >= 2 then
      local other = lulibre.book(c.book)
      for _, tag in ipairs(other and other.tags or {}) do
        if not quality.catchall(tag) then
          score[tag] = (score[tag] or 0) + c.weight
          books[tag] = (books[tag] or 0) + 1
        end
      end
    end
  end
  local best, total = nil, 0
  for tag, s in pairs(score) do
    total = total + s
    if books[tag] >= 2 and (not best or s > score[best]) then best = tag end
  end
  if not best then return nil end
  local share = score[best] / total
  return best, math.min(0.75, 0.35 + 0.08 * books[best]) * (share >= 0.5 and 1 or 0.8), books[best]
end

--- Returns how many entries of a book's bibliography have this person as
-- first author. People cite themselves, so a name read from a title page
-- that also heads several of the book's references is less likely a
-- misreading.
-- @tparam integer id
-- @tparam string name
-- @treturn integer
function M.cites(id, name)
  local surname = lulibre.fold((name or ""):match("([%a\128-\255'%-]+)%s*$") or ""):gsub("[^%a]", "")
  if #surname < 3 then return 0 end
  return lulibre.sql("SELECT count(*) AS n FROM refs WHERE book = ? AND key LIKE ?", id, surname .. ":%")[1].n
end

--- Returns the authors of the books that share the most references with
-- this book, for a book whose author is unknown. The result is a hint: the
-- people who write on the same topics, not the book's author.
-- @tparam integer id
-- @tparam[opt] integer limit
-- @treturn {table,...} `{ {name=, shared=, book=}, ... }`
function M.neighbours(id, limit)
  local out, seen = {}, {}
  for _, c in ipairs(M.coupled(id, 12)) do
    local other = c.shared >= 3 and lulibre.book(c.book)
    for _, name in ipairs(other and other.authors or {}) do
      local key = lulibre.fold(name)
      if not seen[key] and name ~= "Unknown" then
        seen[key] = true
        out[#out + 1] = { name = name, shared = c.shared, book = c.book }
        if #out == (limit or 5) then return out end
      end
    end
  end
  return out
end

--- Returns the subject that shared references point to, as a candidate, or nil.
-- @tparam integer id
-- @treturn table|nil
function M.candidate(id)
  if lulibre.o.learned_tags == "off" then return nil end
  local subject, confidence, n = M.subject(id)
  if not subject then return nil end
  return { field = "tags", value = subject, confidence = math.min(0.35, confidence / 2),
    source = ("shares references with %d books of that subject"):format(n) }
end

return M
