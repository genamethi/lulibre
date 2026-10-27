--- A parse's track record, derived from the journal and never accumulated
-- (design 20, 21).
--
-- Each decision scores the final value against the value as proposed, by
-- lulibre.similar: 1 as proposed, 0 rejected, between for an edit. The
-- final value is the field's value as the record stands now, so an undone
-- or later corrected decision counts as such. Held at the prior until the
-- journal holds the setting track_after's number of decisions across every
-- parse.
--
-- @library lulibre.track
local M = {}

--- The neutral record.
M.prior = 0.5

--- Returns the record of a grammar or service for a field, 0 to 1.
-- @tparam string parse
-- @tparam string field
-- @tparam integer after the decisions the journal must hold first
-- @treturn number
function M.record(parse, field, after)
  -- the journal holds no review decisions until the write path keeps them
  -- (design 27): every record is the prior till then
  return M.prior
end

return M
