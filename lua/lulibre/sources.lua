--- The sources for a book's fields (design 17, 39): the record, the
-- files' own metadata, and the online records kept for the book. A
-- grammar's parse is not a source.
--
-- @library lulibre.sources
local M = {}

--- Returns the book's sources.
-- @tparam integer book
-- @treturn {table,...} each `{ name=, kind = "record"|"embedded"|"online", fields = { [field] = value } }`
function M.of(book)
  error("not written yet", 2)
end

return M
