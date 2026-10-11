-- Propose metadata for books from what their files say.
-- Changes nothing by itself: go through the proposals with :review.
--   :run propose                  the selection
--   :run propose author:unknown   every book matching a filter
--   :run propose --over           also where the file disagrees with a value the
--                                 book already has, however weak the evidence,
--                                 and even if that was proposed and rejected before
--   :run propose --gaps           only fields that are empty
--   lulibre run propose 'tag:none fmt:pdf'
-- Without a flag the option propose_over decides ("sure": a filled field is
-- proposed for only when the file is confident and differs).
local propose = require "lulibre.propose"

local words, over, again = {}, nil, false
for _, a in ipairs { ... } do
  if a == "--over" then over, again = "any", true
  elseif a == "--gaps" then over = "gaps"
  else words[#words + 1] = a end
end
local filter = table.concat(words, " ")
local ids = (lulibre.headless or filter ~= "") and lulibre.ids(filter) or lulibre.selection()

local added, replacing, books = 0, 0, 0
for n, id in ipairs(ids) do
  local a, r = propose.book(id, { over = over, again = again })
  added, replacing = added + a, replacing + r
  if a > 0 then books = books + 1 end
  if n % 25 == 0 then lulibre.progress(("proposing %d/%d"):format(n, #ids)) end
end
lulibre.progress(nil)
print(("%d proposal%s for %d of %d book%s%s; %s goes through them"):format(added, added == 1 and "" or "s", books, #ids,
  #ids == 1 and "" or "s",
  replacing > 0 and (", %d of them for a field that has a value"):format(replacing) or "", lulibre.hint("review")))
