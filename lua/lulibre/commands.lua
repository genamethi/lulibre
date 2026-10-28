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

--- :enrich [filter]: ask the online services about the books, by their
-- identifiers; each new answer posts "source_arrived", which proposes for
-- the book again.
function M.enrich(args)
  local net = require "lulibre.net"
  local books, answers = 0, 0
  for _, id in ipairs(lulibre.ids(args)) do
    local n = net.enrich(id)
    if n > 0 then
      books = books + 1
      answers = answers + n
    end
  end
  print(("%d new answers for %d books"):format(answers, books))
end

-- an answer arriving re-ranks the book (design 42)
evman.add("source_arrived", function(ev)
  proposals.propose(ev.book, proposals.settings())
end)

cmd.create("enrich", function(o) M.enrich(o.args) end, { desc = "[filter]  ask the online services about the books, by their identifiers" })
cmd.create("propose", function(o) M.propose(o.args) end, { desc = "[filter]  propose metadata from the files, for :review" })
cmd.create("review", function(o) M.review(o.args) end, { desc = "[filter]  the books' proposals: accept, edit, reject" })

return M
