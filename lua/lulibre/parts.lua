-- Books that are parts of a whole: a chapter of a handbook, of the Stacks
-- project, of a book the library also holds whole. What lulibre knows of it
-- is kept in its own index (calibre has no field for it), from the grammars
-- of publications (lulibre.grammars) and from records much longer than the
-- file (lulibre.verify).
--
--   local parts = require "lulibre.parts"
--   parts.set(id, { whole=, part=, parts=, source= })   -- nil takes it away
--   parts.of(id)            -- { whole=, part=, parts=, source= } or nil
--   parts.wholes()          -- { { whole=, parts=, books = { {id=, part=}, ... }, missing = { n, ... } }, ... }
local M = {}

function M.set(id, p)
  if not p then
    lulibre.store("DELETE FROM parts WHERE book = ?", id)
    return
  end
  lulibre.store([[INSERT OR REPLACE INTO parts(book, whole, part, parts, source, ts) VALUES(?, ?, ?, ?, ?, ?)]],
    id, p.whole, p.part, p.parts, p.source, os.time())
end

function M.of(id)
  return lulibre.sql("SELECT whole, part, parts, source FROM parts WHERE book = ?", id)[1]
end

--- Each whole, its parts in order, and the numbers it is known to have that
-- the library does not (when how many there are is known).
function M.wholes()
  local by, order = {}, {}
  for _, r in ipairs(lulibre.sql("SELECT book, whole, part, parts FROM parts ORDER BY whole, part, book")) do
    if lulibre.book(r.book) then
      local w = by[r.whole]
      if not w then
        w = { whole = r.whole, books = {}, parts = r.parts }
        by[r.whole] = w
        order[#order + 1] = r.whole
      end
      w.parts = math.max(w.parts or 0, r.parts or 0)
      table.insert(w.books, { id = r.book, part = r.part })
    end
  end
  local out = {}
  for _, name in ipairs(order) do
    local w = by[name]
    local have = {}
    for _, b in ipairs(w.books) do
      if b.part then have[b.part] = true end
    end
    w.missing = {}
    if w.parts and w.parts > 0 then
      for n = 1, w.parts do
        if not have[n] then w.missing[#w.missing + 1] = n end
      end
    end
    if w.parts == 0 then w.parts = nil end
    out[#out + 1] = w
  end
  return out
end

return M
