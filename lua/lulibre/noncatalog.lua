-- Works no catalogue has a record of: a handout, the notes of a course, a
-- chapter of the Stacks project, a page saved from the web. Such a work has
-- no DOI and no ISBN of its own, so one that stands in its file is that of
-- a work it cites, and a record found by searching for its title is
-- somebody else's. Marking a book as non-catalog says so once, and the
-- rest follows:
--   - a DOI or ISBN in its pages is not offered as its own (extract);
--   - it is not looked up by DOI or ISBN, nor searched for by title (:enrich);
--     an arXiv number is still followed, arXiv being where such works are kept;
--   - having no identifiers does not count against it (:good, :stats);
--   - what waits for it from catalogue records is withdrawn when it is
--     marked, and taking off a DOI or ISBN it holds is proposed, for review.
-- The mark is lulibre's own, kept in its index; nothing is written to calibre.
--
--   local noncatalog = require "lulibre.noncatalog"
--   noncatalog.is(id)                 --> true or false
--   noncatalog.set(ids, true)         --> { withdrawn =, removals = }
--   noncatalog.ids()                  --> the marked books still in the library
--   :noncatalog add | remove          for the selection;  is:noncatalog  in a filter
local M = {}

-- the services whose records are a catalogue's: what a source begins with
M.RECORDS = { "CrossRef ", "Open Library ", "OpenAlex ", "zbMATH " }
-- the identifiers a catalogue gives
M.KINDS = { "doi", "isbn" }
-- what a proposal to take one of them off says of where it comes from
M.SOURCE = "non-catalog: no catalogue has a record of it"

local set -- the marked books, read once and kept up as they change

local function load()
  if not set then
    set = {}
    for _, r in ipairs(lulibre.sql("SELECT book FROM noncatalog")) do set[r.book] = true end
  end
  return set
end

--- Is the book marked as non-catalog?
function M.is(id)
  return id ~= nil and load()[id] == true
end

--- Forget what was read (the table was changed some other way).
function M.reload()
  set = nil
end

--- The marked books that are still in the library.
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

--- Mark books as non-catalog, or take the mark back. Marking withdraws what
-- waits for them from catalogue records (it is deleted, not rejected), and
-- proposes taking off each DOI and ISBN they hold. Taking the mark back
-- withdraws those proposals again, and nothing else: propose or enrich
-- anew for what the catalogues say. Returns { withdrawn =, removals = }.
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
