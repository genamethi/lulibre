--- Shows the books whose files are byte-for-byte the same. Each group keeps
-- one copy. You can mark the other copies, merge them into the kept copy,
-- and remove them.
--
-- @screens lulibre.ui.dupes
-- @usage
-- require("lulibre.ui.dupes").run()   -- as :dupes, gd does
local dupes = require "lulibre.dupes"
local edit = require "lulibre.edit"

local M = {}

local keys = require("lulibre.ui.keys").of("dupes")
local panels = require "lulibre.ui.panels"

--- Scans for duplicates and opens the screen on them.
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
        g.skip and "   skipped: nothing in this group will be removed" or ""), id = g.keep, style = "head" }
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

  local p <close> = panels.open("dupes", {
    title = title(), help = keys:hint("keep", "edit", "about", "remove"), follow = true, height = 0.5,
    keys = keys:own(), pass = panels.PASS, reloads = true, moves = true,
    columns = { { "", 1 }, { "Id", 9 }, { "Title", -4 }, { "Authors", -2 }, { "Subject", -2 }, { "Year", 4 } },
    rows = build(),
  })
  if not p then return end
  p:cursor(2)
  local peek = panels.peeker(p, 0.5)
  -- where the list is: the group's copies side by side, field by field
  local SHOWN = 3
  local about <close> = panels.about(p, {
    keys = "dupes", columns = { { "", 12 }, { "", -1 }, { "", -1 }, { "", -1 } },
    fill = function(r)
      local g, b = at[r] and at[r][1], at[r] and at[r][2]
      if not g then return {} end
      local copies = {}
      for i = 1, math.min(SHOWN, #g.books) do copies[i] = g.books[i] end
      local head = { "copy", style = "ok" }
      for i, c in ipairs(copies) do
        head[i + 1] = ("%s%d%s"):format(c.id == g.keep and "✓ " or "", c.id, b and c.id == b.id and "  ←" or "")
      end
      local out = { head }
      for _, field in ipairs(edit.fields) do
        local row, first, same = { field }, nil, true
        for i, c in ipairs(copies) do
          local v = edit.current(c, field)
          row[i + 1] = v
          if i == 1 then first = v elseif v ~= first then same = false end
        end
        row.style = same and "dim" or "warn"
        out[#out + 1] = row
      end
      local folder, formats = { "folder" }, { "formats" }
      for i, c in ipairs(copies) do
        folder[i + 1], formats[i + 1] = c.dir or "", table.concat(c.formats or {}, ", ")
      end
      out[#out + 1] = formats
      out[#out + 1] = folder
      if #g.books > SHOWN then
        out[#out + 1] = { "", ("and %d more copies, not shown"):format(#g.books - SHOWN), style = "dim" }
      end
      return out, ("the %d copies, field by field (differing fields in colour)"):format(#g.books)
    end,
  }, 2)
  -- after something may have changed the books: read them again, and let go
  -- of copies that are no longer there and of groups left with one
  local function refresh()
    for i = #groups, 1, -1 do
      local g = groups[i]
      panels.refresh_books(g.books)
      local kept = false
      for _, b in ipairs(g.books) do kept = kept or b.id == g.keep end
      if #g.books < 2 then table.remove(groups, i)
      elseif not kept then g.keep = g.books[1].id end
    end
  end

  while true do
    local key, row = p:wait()
    if not key then return end
    local g, b = at[row] and at[row][1], at[row] and at[row][2]
    local id = b and b.id or g and g.keep -- the book the row stands for
    local act = keys:action(key)
    if key == "<Move>" then
      about:update(row)
    elseif act == "about" then
      about:toggle(row)
    elseif key == "<Reload>" then
      refresh() -- the library changed under us
    elseif act == "help" then
      keys:show("duplicates", panels.also())
    elseif act == "peek" then
      peek()
    elseif g and act == "take" then
      -- what this copy's record says, offered to the copy being kept
      if not b or b.id == g.keep then
        lulibre.notify(("this is the copy being kept: put the cursor on the copy to take from (%s chooses which is kept)"):format(
          keys:key("keep") or "keep"))
      else
        local from, to = lulibre.book(b.id), lulibre.book(g.keep)
        local n = from and to and dupes.pull(from, to) or 0
        if n == 0 then
          lulibre.notify(("book %d says nothing that book %d does not"):format(b.id, g.keep))
        else
          panels.over(p, require("lulibre.ui.review").run, { ids = { g.keep } })
          refresh()
        end
      end
    elseif id and act == "edit" then
      panels.over(p, require("lulibre.ui.edit").run, { ids = { id } })
      refresh()
    elseif id and act == "review" then
      panels.over(p, require("lulibre.ui.review").run, { ids = { id } })
      refresh()
    elseif g and b and act == "keep" then
      g.keep, g.skip = b.id, nil
    elseif g and act == "skip" then
      g.skip = not g.skip or nil
    elseif act == "mark" then
      local ids = dupes.surplus(groups)
      for _, id in ipairs(ids) do lulibre.mark(id, true) end
      lulibre.notify(("marked %d surplus books; they are now the selection"):format(#ids))
    elseif act == "filter" then
      lulibre.filter("is:dupe")
    elseif act == "remove" then
      local ids = dupes.surplus(groups)
      if #ids == 0 then
        lulibre.notify("nothing to remove")
      elseif lulibre.confirm(("remove %d surplus book%s from calibre? (they go to its recycle bin)"):format(
          #ids, #ids == 1 and "" or "s")) then
        p:close()
        -- what the copies being removed know and the kept ones do not is
        -- kept as proposals for the kept ones
        local carried = dupes.propose(dupes.gather(groups), "duplicate")
        local n, err = edit.remove(ids, { label = "duplicates" })
        local msg = ("removed %d duplicate book%s"):format(n, n == 1 and "" or "s")
        if carried > 0 then
          -- say what was saved from the removed records, and where it went
          msg = msg .. ("; %d value%s only they had (tags, dates and the like) %s proposed for the copies kept: %s reviews them"):format(
            carried, carried == 1 and "" or "s", carried == 1 and "is" or "are", lulibre.hint("review"))
        end
        lulibre.notify(err and ("removed %d, then: %s"):format(n, err) or msg, err and "error" or nil)
        return
      end
    end
    if #groups == 0 then
      lulibre.notify("no duplicates are left")
      return
    end
    p:rows(build())
    p:title(title())
    about:update(row)
  end
end

return M
