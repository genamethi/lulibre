--- Ranks a book's parses (design 16, 21, 39; ranking section).
--
-- A parse is a grammar's, or an online record's. The score is coverage,
-- agreement and track record, each weighed by a setting. Agreement compares
-- a parse's fields with the sources by lulibre.similar; a parse does not
-- count agreement with itself, and circular agreement (a record value
-- written from the same parse) does not count.
--
-- @library lulibre.rank
local M = {}

--- Returns the parses, best first, each with its score and the sources
-- that agree and disagree per field.
-- @tparam {table,...} parses lulibre.grammar.parse's, and online records'
-- @tparam {table,...} sources lulibre.sources.of's
-- @treturn {table,...}
function M.order(parses, sources)
  error("not written yet", 2)
end

return M
