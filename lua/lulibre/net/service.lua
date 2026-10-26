--- A service as a resource: its queue, its pace, its batch size, and its
-- hold when the service says it is asked too much.
--
-- @submodule lulibre.net
local M = {}

--- Defines a service.
-- @tparam string name
-- @tparam table how `{ pace=, batch=, fetch = function(keys) ... end }`; fetch
-- asks about up to batch keys in one request and returns the records by key
function M.define(name, how)
  error("not written yet", 2)
end

return M
