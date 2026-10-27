--- The sources for a book's fields (design 17, 39): the record, the file's
-- own metadata, and the online records kept for the book. A grammar's
-- parse is not a source.
--
-- @library lulibre.sources
local M = {}

--- How much each kind of source weighs in agreement (lulibre.rank).
M.weight = { record = 1, embedded = 0.5, online = 1 }

local function record(b)
  local fields = {
    title = b.title,
    authors = b.author,
    publisher = b.publisher,
    series = b.series,
    year = b.pubdate,
  }
  if b.tags and #b.tags > 0 then fields.tags = table.concat(b.tags, ", ") end
  for kind, value in pairs(b.idents or {}) do fields[kind] = kind .. ":" .. value end
  return fields
end

--- Returns the book's sources.
-- @tparam integer book
-- @param[opt] reading the book's reading, for the file's own metadata
-- @treturn {table,...} each `{ name=, kind = "record"|"embedded"|"online",
-- fields = { [field] = value } }`
function M.of(book, reading)
  local out = {}
  local b = lulibre.book(book)
  if b then out[#out + 1] = { name = "record", kind = "record", fields = record(b) } end
  local meta = reading and reading.meta
  if meta and (meta.title or meta.author) then
    out[#out + 1] = { name = "embedded", kind = "embedded", fields = { title = meta.title, authors = meta.author } }
  end
  return out
end

return M
