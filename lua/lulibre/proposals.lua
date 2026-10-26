--- Proposals: one per book and field, from one parse or collective
-- (design 16, 18, 19).
--
-- A collective proposal takes no span of text for two fields. Where parses
-- claim the same span for different fields, the alternatives show the
-- conflict.
--
-- @library lulibre.proposals
local M = {}

--- Reads, parses, ranks and stores a book's proposals.
-- @tparam integer book
function M.propose(book)
  error("not written yet", 2)
end

--- Returns a book's proposals for review: the first-ranked and its
-- alternatives, per field.
-- @tparam integer book
-- @treturn {table,...}
function M.of(book)
  error("not written yet", 2)
end

--- Accepts a proposal, as proposed or edited, as an operation of the
-- library, with its provenance (design 27).
-- @tparam integer id the proposal
-- @tparam[opt] string value the edited value
function M.accept(id, value)
  error("not written yet", 2)
end

--- Rejects a proposal.
-- @tparam integer id
function M.reject(id)
  error("not written yet", 2)
end

return M
