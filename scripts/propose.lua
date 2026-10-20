-- Propose metadata for books from what their files say.
-- Changes nothing by itself: go through the proposals with :review.
--   :run propose                  the selection
--   :run propose author:unknown   every book matching a filter
--   :run propose --only title,ids author:conrad
--                                 only those fields: title authors subject ids date publisher,
--                                 or their letters t a s i d p
--   :run propose --fresh FILTER   as if the fields were empty: the file's best reading of each,
--                                 whatever the book says now, and even if it was barred before.
--                                 With --only, for when one field went wrong across many books.
--   :run propose --over           also where the file disagrees with a value the book has,
--                                 however weak the evidence
--   :run propose --gaps           only fields that are empty or hold junk
--   lulibre run propose 'tag:none fmt:pdf'
-- Without a flag the option propose_over decides ("sure": a filled field is
-- proposed for only when the file is confident and differs).
local propose = require "lulibre.propose"

local words, opts = {}, {}
local args = { ... }
local i = 1
while i <= #args do
  local a = args[i]
  if a == "--over" then opts.over, opts.again = "any", true
  elseif a == "--gaps" then opts.over = "gaps"
  elseif a == "--fresh" then opts.fresh, opts.again = true, true
  elseif a == "--only" or a:match("^%-%-only=") then
    local list = a:match("^%-%-only=(.*)$")
    if not list then
      i = i + 1
      list = args[i] or ""
    end
    local set, bad = propose.fields(list)
    if not set or not next(set) then
      error(("--only wants fields (title authors subject ids date publisher, or t a s i d p), not '%s'"):format(bad or list), 0)
    end
    opts.only = set
  else
    words[#words + 1] = a
  end
  i = i + 1
end
local filter = table.concat(words, " ")
local ids = (lulibre.headless or filter ~= "") and lulibre.ids(filter) or lulibre.selection()

-- a run of its own, unless this is a step of one (the propose-and-review dialog)
local run <close> = require("lulibre.runs").join { ids = ids, steps = { "files" } }
run:step("files")
local added, replacing, books = 0, 0, 0
for n, id in ipairs(ids) do
  local a, r = propose.book(id, opts)
  added, replacing = added + a, replacing + r
  if a > 0 then books = books + 1 end
  if n % 25 == 0 then lulibre.progress(("proposing %d/%d"):format(n, #ids)) end
end
lulibre.progress(nil)
run:done()
-- what this run added, then what waits in all: "of" only where some of the
-- selected books got proposals and some did not
local selected = #ids == 1 and "the selected book" or ("the %d selected books"):format(#ids)
local said
if added == 0 then
  said = ("No new proposals for %s."):format(selected)
else
  said = ("%d new proposal%s for %s%s."):format(added, added == 1 and "" or "s",
    books == #ids and selected or ("%d of %s"):format(books, selected),
    replacing > 0 and ("; %d would replace a value the book has"):format(replacing) or "")
end
print(said .. require("lulibre.proposals").to_review(" "))
