-- Tags whose levels are split with "/" ("math/number-theory") rewritten
-- with calibre's "." ("math.number-theory"), which calibre shows as a tree
-- in the categories listed under Preferences → Look & feel → "Categories
-- with hierarchical items". Without an argument it lists what it would
-- change, in a list (printed by lulibre run); with "write" it changes it,
-- as one operation in the journal, which :undo puts back.
--   :run tag-dots [write]        lulibre run tag-dots [write]
local bookman = require "bookman"
local store = require "store"

local changes, rows = {}, {}
for _, b in ipairs(bookman.books("tag:/")) do
  for _, tag in ipairs(b.tags) do
    if tag:find("/", 1, true) then
      local dotted = tag:gsub("%s*/%s*", ".")
      changes[#changes + 1] = { book = b.id, field = "tags", value = tag, op = "remove" }
      changes[#changes + 1] = { book = b.id, field = "tags", value = dotted, op = "add" }
      rows[#rows + 1] = { ("%5d  %s  →  %s"):format(b.id, tag, dotted), id = b.id }
    end
  end
end

local summary = ("%d tags with \"/\" in %d books"):format(#rows, #bookman.ids("tag:/"))
if (...) ~= "write" then
  rows[#rows + 1] = { summary .. "; :run tag-dots write rewrites them", style = "note" }
  uiman.list { title = "tag-dots", help = summary, follow = true, items = rows }
  return
end
if #changes == 0 then
  print(summary)
  return
end
local batch, err = store.apply(changes, "tags: / as .")
if not batch then error(err or "nothing changed") end
print(("%s rewritten as operation %d; :undo puts it back"):format(summary, batch))
