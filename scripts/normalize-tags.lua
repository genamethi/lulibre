-- Propose the canonical spelling for subjects that exist under two names
-- (math/geometry/algebraic and math/algebraic-geometry, ...). The table of
-- aliases is lulibre/taxonomy.lua's; add your own in init.lua with
--   require("lulibre.taxonomy").alias["old/name"] = "new/name"
local proposals = require "lulibre.proposals"
local taxonomy = require "lulibre.taxonomy"

local added, books = 0, 0
for old, canonical in pairs(taxonomy.alias) do
  for _, id in ipairs(lulibre.ids(('tag:="%s"'):format(old))) do
    local a = proposals.add(id, "tags", old, { op = "remove", source = "same as " .. canonical, confidence = 0.9 })
    local b = proposals.add(id, "tags", canonical, { op = "add", source = "replaces " .. old, confidence = 0.9 })
    if a or b then
      books = books + 1
      added = added + (a and 1 or 0) + (b and 1 or 0)
    end
  end
end
print(("%d new proposals for %d books.%s"):format(added, books, require("lulibre.proposals").to_review(" ")))
