-- References: what a book cites, read from the bibliography at its end, and
-- what books that cite the same things have in common.
--
-- The index holds each file's first pages; a bibliography is on its last.
-- refs.index_book reads those (the option refs_pages says how many), finds
-- the heading the bibliography stands under, cuts what follows into entries
-- and gives each a key by which the same work is recognised in another
-- book's list, however each list writes it:
--
--   doi:10.1090/s0002-9947                     when the entry gives a DOI
--   arxiv:1012.6008                            or an arXiv number
--   bogoliubov:1957:227                        else first author, year, first page
--   serre:1973                                 or author and year, for a book
--
-- The keys are kept in the table `refs`. Nothing here needs the network.
--
--   local refs = require "lulibre.refs"
--   refs.index_book(id)             --> how many entries were found (waits: it reads the file)
--   refs.of(id)                     --> { {key=, raw=}, ... }
--   refs.coupled(id)                --> { {book=, shared=, weight=}, ... } the books that cite the same works
--   refs.subject(id)                --> subject, confidence, how many books say so; or nil
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

--- Is the line the heading of a bibliography? A short line that is one of the
-- usual words and nothing else, numbered or not ("7. References",
-- "REFERENCES"); not a line of a table of contents ("References 213").
function M.is_heading(text)
  local t = trim(text or ""):lower():gsub("^[%divxlc]+[.)]?%s+", ""):gsub("[.:]$", "")
  return #t <= 30 and HEADS[t] == true
end

--- The lines under the last bibliography heading of a file's closing pages.
-- pages: as lulibre.extract gives them ({ {lines = { {text=, x0=, size=}, ... }}, ... }).
-- Returns the lines (nil when no heading is found) and the page it is on.
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

--- Cut the lines of a bibliography into its entries (strings). Entries are
-- told apart by their numbering ("[1]", "[Se73]", "1.") when most have one,
-- else by the hanging indent: the first line of each stands further left
-- than the lines that continue it.
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

--- The key of one entry, by which the same work is known in another list;
-- nil for a line that is not a reference at all.
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

--- Read a book's bibliography from its file and keep its keys. Waits.
-- opts.pages: how many closing pages to read (default: the option
-- refs_pages). Returns how many entries were kept, or nil and why none.
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

--- Has the book's bibliography been looked for already?
function M.done(id)
  return lulibre.sql("SELECT 1 AS x FROM kv WHERE key = ?", "refs:" .. id)[1] ~= nil
end

--- What a book cites, as it was read: { {key=, raw=}, ... }.
function M.of(id)
  return lulibre.sql("SELECT key, raw FROM refs WHERE book = ? ORDER BY key", id)
end

--- The books that cite works this one cites, the most telling first:
-- { {book=, shared=, weight=}, ... }. A work half the library cites counts
-- for little; one cited by two books counts for much.
function M.coupled(id, limit)
  return lulibre.sql([[
    SELECT o.book AS book, count(*) AS shared,
           sum(1.0 / (SELECT count(*) FROM refs d WHERE d.key = o.key)) AS weight
    FROM refs mine JOIN refs o ON o.key = mine.key AND o.book <> mine.book
    WHERE mine.book = ? GROUP BY o.book ORDER BY weight DESC, shared DESC LIMIT ?]], id, limit or 20)
end

--- The subject of the books that cite what this one cites: the subject, how
-- sure, and how many books speak for it; nil when too few do. Two books that
-- share at least two works with this one are wanted.
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

--- How many entries of a book's bibliography have this person as their
-- first author. People cite themselves: a name read off a title page that
-- also heads several of the book's own references is less likely a
-- misreading.
function M.cites(id, name)
  local surname = lulibre.fold((name or ""):match("([%a\128-\255'%-]+)%s*$") or ""):gsub("[^%a]", "")
  if #surname < 3 then return 0 end
  return lulibre.sql("SELECT count(*) AS n FROM refs WHERE book = ? AND key LIKE ?", id, surname .. ":%")[1].n
end

--- The authors of the books that share the most references with this one,
-- for a book whose author is not known: { {name=, shared=, book=}, ... }.
-- A hint, not a finding: who writes on the same things, not who wrote this.
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

--- The subject shared references point to, as a candidate, or nil.
function M.candidate(id)
  if lulibre.o.subject_learned == "off" then return nil end
  local subject, confidence, n = M.subject(id)
  if not subject then return nil end
  return { field = "tags", value = subject, confidence = math.min(0.7, confidence),
    source = ("shares references with %d books of that subject"):format(n) }
end

return M
