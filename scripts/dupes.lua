-- Find books whose files are byte for byte the same (MD5).
--   :dupes                        the panel: choose what to keep, remove the rest
--   lulibre run dupes             list the groups
--   lulibre run dupes --ids       only the ids that would be removed
--   lulibre run dupes --all       hash every file, not only those of equal size
--   lulibre run dupes --remove    remove the surplus copies (to calibre's recycle bin)
local dupes = require "lulibre.dupes"
local edit = require "lulibre.edit"

local opt = {}
for _, a in ipairs({ ... }) do opt[a:gsub("^%-%-", "")] = true end

if not lulibre.headless and not (opt.ids or opt.remove) then
  require("lulibre.ui.dupes").run()
  return
end

local groups, stats = dupes.scan { all = opt.all }
local ids = dupes.surplus(groups)
if opt.ids then
  for _, id in ipairs(ids) do io.write(id, "\n") end
  return
end
local bytes = 0
for _, g in ipairs(groups) do
  bytes = bytes + g.size * (#g.books - 1)
  io.write(("%s  %s  %d copies\n"):format(g.md5, dupes.human(g.size), #g.books))
  for _, b in ipairs(g.books) do
    io.write(("  %s %5d  %s%s\n"):format(b.id == g.keep and "keep" or "    ", b.id, b.title or "",
      edit.is_unknown(b.author) and "" or ("  —  " .. b.author)))
  end
end
io.write(("%d files hashed, %d groups, %d surplus books, %s\n"):format(stats.hashed, #groups, #ids, dupes.human(bytes)))
if opt.remove and #ids > 0 then
  local carried = dupes.propose(dupes.gather(groups), "duplicate")
  if carried > 0 then io.write(("%d things the removed copies knew are now proposals for the kept ones\n"):format(carried)) end
  local n, err = edit.remove(ids)
  io.write(("removed %d books%s\n"):format(n, err and (", then: " .. err) or ""))
  if err then error(err, 0) end
end
