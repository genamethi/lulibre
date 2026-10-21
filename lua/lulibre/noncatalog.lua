--- Marks books that no catalogue describes: handouts, course notes, Stacks
-- project chapters, saved web pages. A non-catalog book has no DOI or ISBN
-- of its own. A DOI or ISBN in its file belongs to a work it cites, and a
-- title search finds another work's record.
--
-- For a book marked non-catalog, lulibre:
--
-- - doesn't offer a DOI or ISBN found in its pages as the book's own (extract);
-- - doesn't look the book up by DOI or ISBN, or search for its title
--   (:enrich), but still follows an arXiv number, since arXiv keeps many
--   non-catalog works;
-- - doesn't count missing identifiers against the book (:good, :stats);
-- - withdraws the book's waiting proposals from catalogue records when you
--   mark the book, and proposes removing each DOI and ISBN the book has.
--
-- lulibre stores the mark in its index and writes nothing to calibre.
--
-- @judging lulibre.noncatalog
-- @usage
-- local noncatalog = require "lulibre.noncatalog"
-- noncatalog.is(id)                 --> true or false
-- noncatalog.set(ids, true)         --> { withdrawn =, removals = }
-- noncatalog.ids()                  --> the marked books still in the library
-- :noncatalog add | remove          for the selection;  is:noncatalog  in a filter
local M = {}

--- The catalogue services, as the start of a proposal's source.
M.RECORDS = { "CrossRef ", "Open Library ", "OpenAlex ", "zbMATH " }
--- The identifiers a catalogue gives.
M.KINDS = { "doi", "isbn" }
--- The source of a proposal to remove a DOI or ISBN.
M.SOURCE = "non-catalog: no catalogue has a record of it"

local set -- the marked books, read once and kept up as they change

local function load()
  if not set then
    set = {}
    for _, r in ipairs(lulibre.sql("SELECT book FROM noncatalog")) do set[r.book] = true end
  end
  return set
end

--- Returns true if the book is marked as non-catalog.
-- @tparam integer id
-- @treturn boolean
function M.is(id)
  return id ~= nil and load()[id] == true
end

--- Clears the cached marks. Call it if the table was changed some other way.
function M.reload()
  set = nil
end

--- Returns the marked books that are still in the library.
-- @treturn {integer,...}
function M.ids()
  local out = {}
  for i, r in ipairs(lulibre.sql("SELECT n.book AS id FROM noncatalog n JOIN books b ON b.id = n.book ORDER BY n.book")) do out[i] = r.id end
  return out
end

-- does a proposal come from a catalogue: a record of one, or an identifier one gives?
local function from_catalogue(pr)
  for _, prefix in ipairs(M.RECORDS) do
    if (pr.source or ""):sub(1, #prefix) == prefix then return true end
  end
  if pr.field == "identifiers" and pr.op ~= "remove" then
    for _, kind in ipairs(M.KINDS) do
      if (pr.value or ""):sub(1, #kind + 1) == kind .. ":" then return true end
    end
  end
  return false
end

--- Marks books as non-catalog, or removes the mark. Marking deletes (does
-- not reject) the waiting proposals from catalogue records, and proposes
-- removing each DOI and ISBN the books have. Removing the mark withdraws
-- those removal proposals and nothing else. To get the catalogues' values
-- again, propose or enrich again.
-- @tparam {integer,...} ids
-- @tparam boolean on
-- @treturn table `{ withdrawn=, removals= }`
function M.set(ids, on)
  local proposals = require "lulibre.proposals"
  local out = { withdrawn = 0, removals = 0 }
  local marks = load()
  for _, id in ipairs(ids) do
    if on then
      lulibre.store("INSERT OR IGNORE INTO noncatalog(book, ts) VALUES(?, ?)", id, os.time())
      marks[id] = true
      for _, pr in ipairs(lulibre.store("SELECT id, field, op, value, source FROM proposals WHERE book = ? AND status = 'pending'", id)) do
        if from_catalogue(pr) then
          lulibre.store("DELETE FROM proposals WHERE id = ?", pr.id)
          out.withdrawn = out.withdrawn + 1
        end
      end
      local book = lulibre.book(id)
      for _, kind in ipairs(M.KINDS) do
        local value = book and book.idents[kind]
        if value and proposals.add(id, "identifiers", kind .. ":" .. value, { op = "remove", confidence = 0.8,
            source = M.SOURCE }) then
          out.removals = out.removals + 1
        end
      end
    else
      lulibre.store("DELETE FROM noncatalog WHERE book = ?", id)
      marks[id] = nil
      local _, n = lulibre.store("DELETE FROM proposals WHERE book = ? AND status = 'pending' AND source = ?", id, M.SOURCE)
      out.withdrawn = out.withdrawn + (n or 0)
    end
  end
  return out
end

return M
