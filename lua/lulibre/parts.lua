--- Records which books are parts of a whole: a chapter of a handbook, of
-- the Stacks project, or of a book the library also holds whole.
-- The parts are custom fields (lulibre.custom): #partof (the whole), #part
-- (the book's number in the whole) and #parts (how many parts there are).
-- The grammars of publications (lulibre.grammars) set them, or you set them
-- by hand like any field. Filters: is:part, #partof:handbook.
--
-- @module lulibre.parts
-- @usage
-- local parts = require "lulibre.parts"
-- parts.set{ { id=, whole=, part=, parts= }, ... }   -- as one change (journaled); returns edit.apply's summary
-- parts.of(id)            -- { whole=, part=, parts= } or nil
-- parts.wholes()          -- { { whole=, parts=, books = { {id=, part=}, ... }, missing = { n, ... } }, ... }
local custom = require "lulibre.custom"

local M = {}

--- Sets the whole, number and count of several books, as one journaled change.
-- @tparam {table,...} list `{ id=, whole=, part=, parts= }`
-- @tparam[opt] string label
-- @treturn table `lulibre.edit.apply`'s result
function M.set(list, label)
  local changes = {}
  for _, p in ipairs(list) do
    local function put(field, v) changes[#changes + 1] = { id = p.id, field = field, value = v and tostring(v) or "" } end
    put("#partof", p.whole)
    put("#part", p.part)
    put("#parts", p.parts)
  end
  return require("lulibre.edit").apply(changes, { label = label or "parts" })
end

--- Returns what a book is a part of.
-- @tparam integer id
-- @treturn table|nil `{ whole=, part=, parts= }`
function M.of(id)
  local whole = custom.get(id, "#partof")
  if whole == "" then return nil end
  return { whole = whole, part = tonumber(custom.get(id, "#part")), parts = tonumber(custom.get(id, "#parts")) }
end

--- Returns each whole with its parts in order. If the number of parts is
-- known, also returns the part numbers the library is missing.
-- @treturn {table,...}
function M.wholes()
  local by, order = {}, {}
  for _, r in ipairs(lulibre.sql([[SELECT w.book, w.value AS whole,
      (SELECT value FROM custom.data p WHERE p.book = w.book AND p.field = '#part') AS part,
      (SELECT value FROM custom.data n WHERE n.book = w.book AND n.field = '#parts') AS parts
    FROM custom.data w WHERE w.field = '#partof' ORDER BY w.value]])) do
    if lulibre.book(r.book) then
      local w = by[r.whole]
      if not w then
        w = { whole = r.whole, books = {}, parts = 0 }
        by[r.whole] = w
        order[#order + 1] = r.whole
      end
      w.parts = math.max(w.parts, tonumber(r.parts) or 0)
      table.insert(w.books, { id = r.book, part = tonumber(r.part) })
    end
  end
  local out = {}
  for _, name in ipairs(order) do
    local w = by[name]
    table.sort(w.books, function(a, b)
      if (a.part or math.huge) ~= (b.part or math.huge) then return (a.part or math.huge) < (b.part or math.huge) end
      return a.id < b.id
    end)
    local have = {}
    for _, b in ipairs(w.books) do
      if b.part then have[b.part] = true end
    end
    w.missing = {}
    for n = 1, w.parts do
      if not have[n] then w.missing[#w.missing + 1] = n end
    end
    if w.parts == 0 then w.parts = nil end
    out[#out + 1] = w
  end
  return out
end

return M
