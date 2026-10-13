-- Read bibliographies: what each book cites, from the last pages of its file.
--   :run refs                 the selection
--   :run refs FILTER          the books a filter matches; `all` for the library
--   :run refs --force ...     again, for books already read
-- Books are read several at a time and each is remembered, so a run that is
-- stopped can be taken up again. Afterwards a book's tags are suggested from
-- the subjects of the books that cite what it cites (see lulibre.refs).
local refs = require "lulibre.refs"

local words, force = {}, false
for _, a in ipairs { ... } do
  if a == "--force" then force = true else words[#words + 1] = a end
end
local filter = table.concat(words, " ")
if filter == "all" then filter = "in:library" end
local ids = (lulibre.headless or filter ~= "") and lulibre.ids(filter) or lulibre.selection()

local todo = {}
for _, id in ipairs(ids) do
  if id > 0 and (force or not refs.done(id)) then todo[#todo + 1] = { id = id } end
end
lulibre.each(todo, function(item)
  local n = refs.index_book(item.id)
  item.n = n or 0
end, { progress = "reading bibliographies" })
local with, entries = 0, 0
for _, item in ipairs(todo) do
  if item.n > 0 then with = with + 1 end
  entries = entries + item.n
end
print(("read %d of %d book%s (%d already done): a bibliography in %d, %d entries"):format(#todo, #ids, #ids == 1 and "" or "s",
  #ids - #todo, with, entries))
