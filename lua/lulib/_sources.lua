--- The sources for a book's fields (design 17, 39): the record, the file's
-- own metadata, and the online records kept for the book. A grammar's
-- parse is not a source.
--
-- @library lulib._sources
local bookman = require "bookman"

local M = {}
local own, get = require "lulib._expose" (M) -- internal functions (expose_modules)

--- How much each kind of source weighs in agreement (lulib._rank).
M.weight = { record = 1, embedded = 0.5, online = 1 }

-- the record's fields that have a value, as bookman.get gives them
function own.record(b)
  local fields = {}
  for _, field in ipairs { "title", "authors", "publisher", "series", "pubdate", "tags" } do
    local v = bookman.get(b.id, field)
    if v ~= "" then fields[field] = v end
  end
  for kind, value in pairs(b.idents or {}) do fields["identifier:" .. kind] = value end
  return fields
end

--- Returns the book's sources: the record, the file's own metadata as the
-- index holds it, and each online record kept for it (net).
-- @tparam integer book
-- @tparam[opt] table file the row of bookman.files it is read from
-- @tparam[opt] {table,...} found the file's identifiers (lulib._ids)
-- @treturn {table,...} each `{ name=, kind = "record"|"embedded"|"online",
-- fields = { [field] = value } }`; an online one has its key, ident and
-- pages too
function M.of(book, file, found)
  local out = {}
  local b = bookman.get(book)
  if b then out[#out + 1] = { name = "record", kind = "record", fields = get("record")(b) } end
  if file and (file.title or file.author) then
    out[#out + 1] = { name = "embedded", kind = "embedded", fields = { title = file.title, authors = file.author } }
  end
  for _, r in ipairs(require("net").records(book, found)) do
    out[#out + 1] = { name = r.service, kind = "online", fields = r.fields, key = r.key, ident = r.ident, pages = r.pages,
                            identifies = r.identifies }
  end
  return out
end

return M
