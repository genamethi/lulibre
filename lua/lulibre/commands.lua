--- The packaged commands (design 12): each a module function run as a
-- task, called through the module's table, so a redefinition in init.lua
-- takes effect (design 6).
local bookman = require "bookman"
local iter = require "iter"
local propose = require "lulibre.propose"
local review = require "lulibre.ui.review"

local M = {}

--- The books a command is for: the filter it was given, else the
-- selection at the time it was invoked (`selection` says so outright).
function M.books(o, otherwise)
  local args = o.args or ""
  if args ~= "" and args ~= "selection" then return bookman.ids(args) end
  if o.selection and #o.selection > 0 then return o.selection end
  return otherwise and bookman.ids(otherwise) or {}
end

-- fn(book) for each book: how many books it gave a count above 0 for,
-- and the sum of the counts
local function tally(ids, fn)
  local counts = iter(ids):map(fn):filter(function(n) return n > 0 end):totable()
  return #counts, iter(counts):fold(0, function(sum, n) return sum + n end)
end

--- :propose [filter]: proposals for the books, for :review.
function M.propose(ids)
  local w <const> = propose.settings()
  local books, fields = tally(ids, function(id) return propose.propose(id, w) end)
  print(("proposals for %d fields of %d books"):format(fields, books))
end

--- :review [filter]: the books' proposals.
function M.review(ids)
  review.open(ids)
end

--- :enrich [filter]: ask the online services about the books, by their
-- identifiers; each new answer posts "source_arrived", which proposes for
-- the book again.
function M.enrich(ids)
  local net = require "net"
  local books, answers = tally(ids, net.enrich)
  print(("%d new answers for %d books"):format(answers, books))
end

cmdman.create("enrich", function(o) M.enrich(M.books(o)) end, { desc = "[filter]  ask the online services about the books, by their identifiers" })
cmdman.create("propose", function(o) M.propose(M.books(o)) end, { desc = "[filter]  propose metadata from the files, for :review" })
cmdman.create("review", function(o) M.review(M.books(o, "is:proposed")) end, { desc = "[filter]  the books' proposals: accept, edit, reject" })

return M
