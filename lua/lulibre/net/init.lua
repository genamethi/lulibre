--- Online lookups (design 39-43). Each service is a resource with a queue
-- (lulibre.net.service): a caller asks about one work and waits; the
-- service batches, paces and holds back by its own rules. Every answer is
-- kept, and an offline dataset answers first. An answer arriving posts
-- "source arrived" for the book.
--
-- @services lulibre.net
local M = {}

--- Asks a service about a work, and waits for the answer.
-- @tparam string service "arxiv", "crossref", "zbmath", "openlibrary", "openalex"
-- @tparam string key the work's identifier, canonical
-- @treturn table|nil the record, or nil and the reason
function M.ask(service, key)
  error("not written yet", 2)
end

return M
