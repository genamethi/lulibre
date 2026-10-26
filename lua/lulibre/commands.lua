--- The packaged commands (design 12): each a module function run as a
-- task, called through the module's table, so a redefinition in init.lua
-- takes effect (design 6).
local proposals = require "lulibre.proposals"
local review = require "lulibre.ui.review"

lulibre.command("propose", function(args)
  for _, id in ipairs(lulibre.ids(args)) do proposals.propose(id) end
end, "[filter]  propose metadata from the files, for :review")

lulibre.command("review", function(args)
  review.open(lulibre.ids(args))
end, "[filter]  the books' proposals: accept, edit, reject")
