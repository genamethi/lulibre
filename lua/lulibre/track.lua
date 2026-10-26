--- A parse's track record, derived from the journal and never accumulated
-- (design 20, 21).
--
-- Each decision scores the final value against the value as proposed, by
-- lulibre.similar: 1 as proposed, 0 rejected, between for an edit. The
-- final value is the field's value as the record stands now, so an undone
-- or later corrected decision counts as such. Held near a neutral prior,
-- and counted only once the journal holds the setting's number of
-- decisions across every parse.
--
-- @library lulibre.track
local M = {}

--- Returns the record of a grammar or service for a field, 0 to 1.
-- @tparam string parse
-- @tparam string field
-- @treturn number
function M.record(parse, field)
  error("not written yet", 2)
end

return M
