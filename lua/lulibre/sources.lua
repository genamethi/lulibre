--- The sources for a book's fields (design 17, 39): the record, the file's
-- own metadata, and the online records kept for the book. A grammar's
-- parse is not a source.
--
-- @library lulibre.sources
local bookman = require "bookman"

local M = {}

--- How much each kind of source weighs in agreement (lulibre.rank).
M.weight = { record = 1, embedded = 0.5, online = 1 }

-- the record's fields that have a value, as bookman.get gives them
local function record(b)
  local fields = {}
  for _, field in ipairs { "title", "authors", "publisher", "series", "pubdate", "tags" } do
    local v = bookman.get(b.id, field)
    if v ~= "" then fields[field] = v end
  end
  for kind, value in pairs(b.idents or {}) do fields["identifier:" .. kind] = value end
  return fields
end

--- Returns the book's sources: the record, the file's own metadata, and
-- each online record kept for it (net).
-- @tparam integer book
-- @param[opt] t the book's text (txt), for the file's own metadata
-- @treturn {table,...} each `{ name=, kind = "record"|"embedded"|"online",
-- fields = { [field] = value } }`
function M.of(book, t)
  local out = {}
  local b = bookman.get(book)
  if b then out[#out + 1] = { name = "record", kind = "record", fields = record(b) } end
  local meta = t and t.meta
  if meta and (meta.title or meta.author) then
    out[#out + 1] = { name = "embedded", kind = "embedded", fields = { title = meta.title, authors = meta.author } }
  end
  for _, r in ipairs(require("net").records(book)) do
    out[#out + 1] = { name = r.service, kind = "online", fields = r.fields }
  end
  return out
end

return M
