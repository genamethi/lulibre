-- Duplicates: books whose files are byte for byte the same. Each group
-- keeps one copy; the others can be marked, merged into it and removed.
local dupes = require "lulibre.dupes"
local edit = require "lulibre.edit"

local M = {}

local HELP = "Space keep this copy   s skip group   m mark the rest   f filter   D remove the rest   q close"

function M.run()
  local groups, stats = dupes.scan()
  if #groups == 0 then
    lulibre.notify(("no two books hold the same file (%d files of equal size compared)"):format(stats.hashed))
    return
  end

  local at -- row -> { group, book } ; book is nil on a heading
  local function build()
    local rows = {}
    at = {}
    for _, g in ipairs(groups) do
      rows[#rows + 1] = { ("%d copies   %s each   md5 %s%s"):format(#g.books, dupes.human(g.size), g.md5,
        g.skip and "   skipped: nothing here will be removed" or ""), id = g.keep, style = "head" }
      at[#rows] = { g }
      for _, b in ipairs(g.books) do
        local keep = b.id == g.keep
        rows[#rows + 1] = { g.skip and "" or (keep and "✓" or "×"), b.id, b.title or "",
          edit.is_unknown(b.author) and "" or b.author, table.concat(b.tags, ", "), b.year or "",
          id = b.id, style = g.skip and "dim" or (keep and "ok" or nil) }
        at[#rows] = { g, b }
      end
    end
    return rows
  end
  local function title()
    local n, bytes = 0, 0
    for _, g in ipairs(groups) do
      if not g.skip then
        n = n + #g.books - 1
        bytes = bytes + g.size * (#g.books - 1)
      end
    end
    return ("duplicates  %d groups, %d surplus books, %s"):format(#groups, n, dupes.human(bytes))
  end

  local p <close> = lulibre.panel {
    title = title(), help = HELP, follow = true, height = 0.5,
    columns = { { "", 1 }, { "Id", 9 }, { "Title", -4 }, { "Authors", -2 }, { "Subject", -2 }, { "Year", 4 } },
    rows = build(),
  }
  p:cursor(2)

  while true do
    local key, row = p:wait()
    if not key then return end
    local g, b = at[row] and at[row][1], at[row] and at[row][2]
    if g and b and (key == "<Space>" or key == "<CR>") then
      g.keep, g.skip = b.id, nil
    elseif g and key == "s" then
      g.skip = not g.skip or nil
    elseif key == "m" then
      local ids = dupes.surplus(groups)
      for _, id in ipairs(ids) do lulibre.mark(id, true) end
      lulibre.notify(("marked %d surplus books; they are now the selection"):format(#ids))
    elseif key == "f" then
      lulibre.filter("is:dupe")
    elseif key == "D" then
      local ids = dupes.surplus(groups)
      if #ids == 0 then
        lulibre.notify("nothing to remove")
      elseif lulibre.confirm(("remove %d surplus book%s from calibre? (they go to its recycle bin)"):format(
          #ids, #ids == 1 and "" or "s")) then
        p:close()
        -- what the copies being removed know and the kept ones do not is
        -- kept as proposals for the kept ones
        local carried = dupes.propose(dupes.gather(groups), "duplicate")
        local n, err = edit.remove(ids)
        local msg = ("removed %d duplicate book%s"):format(n, n == 1 and "" or "s")
        if carried > 0 then msg = msg .. ("; %d things they knew are proposals for the kept copies (gr)"):format(carried) end
        lulibre.notify(err and ("removed %d, then: %s"):format(n, err) or msg, err and "error" or nil)
        return
      end
    end
    p:rows(build())
    p:title(title())
  end
end

return M
