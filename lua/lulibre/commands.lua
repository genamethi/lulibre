--- The packaged commands (design 12): each a module function run as a
-- task, called through the module's table, so a redefinition in init.lua
-- takes effect (design 6).
local proposals = require "lulibre.proposals"
local review = require "lulibre.ui.review"

local M = {}

--- :propose [filter]: proposals for the books, for :review.
function M.propose(args)
  local w <const> = proposals.settings()
  local books, fields = 0, 0
  for _, id in ipairs(lulibre.ids(args)) do
    local n = proposals.propose(id, w)
    if n then
      books = books + 1
      fields = fields + n
    end
  end
  print(("proposals for %d fields of %d books"):format(fields, books))
end

--- :review [filter]: the books' proposals.
function M.review(args)
  review.open(lulibre.ids(args))
end

cmd.create("propose", function(o) M.propose(o.args) end, { desc = "[filter]  propose metadata from the files, for :review" })
cmd.create("review", function(o) M.review(o.args) end, { desc = "[filter]  the books' proposals: accept, edit, reject" })

return M
