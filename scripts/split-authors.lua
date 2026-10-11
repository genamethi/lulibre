-- Propose proper author lists where one "author" is really several people
-- ("Yuri Manin; Matilde Marcolli"). Review with :review.
--   :run split-authors            every such book
--   :run split-authors FILTER     only those matching a filter as well
local names = require "lulibre.names"
local proposals = require "lulibre.proposals"

local extra = table.concat({ ... }, " ")
local ids = lulibre.ids("is:listauthor " .. extra)
local added = 0
for _, id in ipairs(ids) do
  local book = lulibre.book(id)
  local people = {}
  for _, author in ipairs(book.authors) do
    for _, person in ipairs(names.split(author)) do people[#people + 1] = names.titlecase(person) end
  end
  if #people > #book.authors and proposals.add(id, "authors", table.concat(people, " & "),
      { source = "split list", confidence = 0.9 }) then
    added = added + 1
  end
end
print(("%d author lists to split, out of %d books; :review goes through them"):format(added, #ids))
