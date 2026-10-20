-- Orphans: records with no file, and files with no record. Each row carries
-- a verdict and what would be done about it; Space changes that, w does it.
-- x opens a row up: what does not fit its columns (the verdict in full, the
-- whole path, where a link points) is shown beneath it. X does so for all.
local dupes = require "lulibre.dupes"
local edit = require "lulibre.edit"
local orphans = require "lulibre.orphans"

local M = {}

local keys = require("lulibre.ui.keys").of("orphans")
local panels = require "lulibre.ui.panels"
local SIGN = { keep = "", remove = "×", reattach = "↩", move = "→", add = "+", relink = "↩", unlink = "×" }
local WORD = { keep = "keep", remove = "remove record", reattach = "re-attach file", move = "move out", add = "add as book",
  relink = "repair link", unlink = "delete link" }

function M.run()
  local found = orphans.scan()
  if #found.records + #found.strays + #found.links + #found.empty == 0 then
    lulibre.notify("no orphans: every record has its file and every file has its record")
    return
  end

  local at -- row -> the record, stray or link it shows
  local section -- heading's row -> the records, strays or links under it
  local open = {} -- item -> its details are shown beneath it
  local function build()
    local rows = {}
    at, section = {}, {}
    local function head(text, id, items)
      rows[#rows + 1] = { text, id = id, style = "head" }
      section[#rows] = items
    end
    -- beneath an opened row: each line across the whole width
    local function details(item, id, lines)
      if not open[item] then return end
      for _, line in ipairs(lines) do
        if line and line ~= "" then
          rows[#rows + 1] = { "      " .. line, id = id, style = "note" }
          at[#rows] = item
        end
      end
    end
    if #found.records > 0 then
      head(("Records with no file  (%d)"):format(#found.records), found.records[1].book.id, found.records)
      for _, r in ipairs(found.records) do
        local b = r.book
        rows[#rows + 1] = { SIGN[r.action], WORD[r.action], b.id, b.title or "",
          edit.is_unknown(b.author) and "" or b.author, r.brief or r.verdict, id = b.id,
          style = r.action == "remove" and "warn" or (r.action == "reattach" and "ok" or nil) }
        at[#rows] = r
        details(r, b.id, { (b.title or "") .. (edit.is_unknown(b.author) and "" or "  —  " .. b.author), r.verdict,
          r.twin and ("book %d: %s%s"):format(r.twin.id, r.twin.title or "",
            edit.is_unknown(r.twin.author) and "" or "  —  " .. r.twin.author) })
      end
    end
    if #found.strays > 0 then
      head(("Files with no record  (%d)"):format(#found.strays), nil, found.strays)
      for _, s in ipairs(found.strays) do
        rows[#rows + 1] = { SIGN[s.action], WORD[s.action], "", s.rel, dupes.human(s.size), s.verdict,
          id = s.twin, style = s.action == "move" and "warn" or (s.action == "add" and "ok" or nil) }
        at[#rows] = s
        details(s, s.twin, { s.rel, s.verdict })
      end
    end
    if #found.links > 0 then
      head(("Links that lead nowhere  (%d)"):format(#found.links), found.links[1].book, found.links)
      for _, l in ipairs(found.links) do
        rows[#rows + 1] = { SIGN[l.action], WORD[l.action], l.book or "", l.rel, "", l.verdict,
          id = l.book, style = l.action == "relink" and "ok" or (l.action == "unlink" and "warn" or nil) }
        at[#rows] = l
        details(l, l.book, { l.rel, "points at  " .. l.target, l.to and ("would point at  " .. l.to), l.verdict })
      end
    end
    if #found.empty > 0 then
      head(("Empty folders  (%d)   left alone"):format(#found.empty))
      for _, dir in ipairs(found.empty) do
        rows[#rows + 1] = { "", "", "", dir:sub(#found.root + 2), "", "", style = "dim" }
      end
    end
    return rows
  end
  local function title()
    local n = orphans.counts(found)
    local todo = {}
    for _, a in ipairs { "reattach", "remove", "move", "add", "relink", "unlink" } do
      if n[a] > 0 then todo[#todo + 1] = ("%d %s"):format(n[a], WORD[a]) end
    end
    return "orphans  " .. (#todo > 0 and table.concat(todo, ", ") or "nothing to do as it stands")
  end

  local p <close> = lulibre.panel {
    title = title(), help = keys:hint("action", "expand", "edit", "about", "write"), follow = true, height = 0.5,
    keys = keys:own(), pass = panels.PASS, reloads = true, moves = true,
    columns = { { "", 1 }, { "Action", 14 }, { "Id", 6 }, { "Title or file", -3 }, { "Authors", -2 }, { "Verdict", 32 } },
    rows = build(),
  }
  p:cursor(2)
  local peek = panels.peeker(p, 0.5)
  -- where the list is: a record beside the book that has its file, a stray
  -- file beside the book that holds the same bytes, a link and its target
  local about <close> = panels.about(p, {
    keys = "orphans", columns = { { "", 12 }, { "", -1 }, { "", -1 } },
    fill = function(r)
      local item, out = at[r], {}
      if not item then return out end
      local function fields(a, b)
        for _, field in ipairs(edit.fields) do
          local va, vb = a and edit.current(a, field) or "", b and edit.current(b, field) or ""
          out[#out + 1] = { field, va, b and vb or "", style = (b and va ~= vb) and "warn" or "dim" }
        end
      end
      local twin = type(item.twin) == "table" and item.twin or (type(item.twin) == "number" and lulibre.book(item.twin)) or nil
      if type(item.book) == "table" then
        out[#out + 1] = { "", ("record %d, no file"):format(item.book.id), twin and ("book %d, with its file"):format(twin.id) or "", style = "head" }
        fields(item.book, twin)
        out[#out + 1] = { "verdict", item.verdict or "", "" }
        out[#out + 1] = { "action", WORD[item.action] or item.action or "", "" }
        return out, twin and "the record beside the copy that has its file" or "the record"
      end
      out[#out + 1] = { "path", item.rel or "", "" }
      if item.target then out[#out + 1] = { "points at", item.target, "" } end
      if item.to then out[#out + 1] = { "would point", item.to, "" } end
      if item.size then out[#out + 1] = { "size", require("lulibre.dupes").human(item.size), "" } end
      out[#out + 1] = { "verdict", item.verdict or "", "" }
      out[#out + 1] = { "action", WORD[item.action] or item.action or "", "" }
      if twin then
        out[#out + 1] = { "", "", "" }
        out[#out + 1] = { "", ("book %d"):format(twin.id), "", style = "head" }
        for _, field in ipairs(edit.fields) do out[#out + 1] = { field, edit.current(twin, field), "" } end
      end
      return out, item.target and "the link" or "the file"
    end,
  }, 2)
  -- after something may have changed the books: read the records again, and
  -- let go of those whose book is no longer there
  local function refresh()
    for i = #found.records, 1, -1 do
      local fresh = lulibre.book(found.records[i].book.id)
      if fresh then found.records[i].book = fresh else table.remove(found.records, i) end
    end
  end

  while true do
    local key, row = p:wait()
    if not key then return end
    local item = at[row]
    -- the book the row stands for: the record's own, a stray file's twin, a link's target
    local id = item and (type(item.book) == "table" and item.book.id or item.book or item.twin)
    if type(id) == "table" then id = id.id end
    local act = keys:action(key)
    if key == "<Move>" then
      about:update(row)
    elseif act == "about" then
      about:toggle(row)
    elseif key == "<Reload>" then
      refresh() -- the library changed under us
    elseif act == "help" then
      keys:show("orphans", panels.also())
    elseif act == "peek" then
      peek()
    elseif act == "take" then
      -- a record whose file is gone, and another book that is the same work
      -- and has it: what the record says is offered to that book
      local from = item and type(item.book) == "table" and lulibre.book(item.book.id)
      local to = from and item.twin and lulibre.book(item.twin.id)
      if not to then
        lulibre.notify("this works on a record with no file that has a copy in the library to give its values to")
      elseif dupes.pull(from, to) == 0 then
        lulibre.notify(("book %d says nothing that book %d does not"):format(from.id, to.id))
      else
        panels.over(p, require("lulibre.ui.review").run, { ids = { to.id } })
        refresh()
      end
    elseif act == "edit" or act == "review" then
      if not id or not lulibre.book(id) then
        lulibre.notify("this row has no book in the library to " .. act)
      else
        panels.over(p, require(act == "edit" and "lulibre.ui.edit" or "lulibre.ui.review").run, { ids = { id } })
        refresh()
      end
    elseif section[row] and act == "action" then
      -- on a heading: every row under it takes the next action of its first
      local items = section[row]
      local first, i = items[1], 1
      for k, a in ipairs(first.actions) do
        if a == first.action then i = k end
      end
      local to, n = first.actions[i % #first.actions + 1], 0
      for _, it in ipairs(items) do
        for _, a in ipairs(it.actions) do
          if a == to then
            it.action, n = to, n + 1
            break
          end
        end
      end
      lulibre.notify(("%d of %d rows set to %s"):format(n, #items, WORD[to] or to))
    elseif item and act == "action" then
      local i = 1
      for k, a in ipairs(item.actions) do
        if a == item.action then i = k end
      end
      item.action = item.actions[i % #item.actions + 1]
    elseif item and act == "expand" then
      open[item] = not open[item] or nil
    elseif act == "expand_all" then
      local any = next(open) ~= nil
      open = {}
      if not any then
        for _, list in ipairs { found.records, found.strays, found.links } do
          for _, it in ipairs(list) do open[it] = true end
        end
      end
    elseif act == "mark" then
      local n = 0
      for _, r in ipairs(found.records) do
        if r.action == "remove" then
          lulibre.mark(r.book.id, true)
          n = n + 1
        end
      end
      lulibre.notify(("marked the %d records set to be removed"):format(n))
    elseif act == "filter" then
      lulibre.filter("is:missing")
    elseif act == "write" then
      local n = orphans.counts(found)
      if n.remove + n.reattach + n.move + n.add + n.relink + n.unlink == 0 then
        lulibre.notify(("every row is set to keep; %s changes a row's action"):format(keys:key("action") or "action"))
      else
        local parts = {}
        if n.reattach > 0 then parts[#parts + 1] = ("give %d records their files back"):format(n.reattach) end
        if n.remove > 0 then parts[#parts + 1] = ("remove %d records (to calibre's recycle bin)"):format(n.remove) end
        if n.add > 0 then parts[#parts + 1] = ("add %d files as books"):format(n.add) end
        if n.move > 0 then parts[#parts + 1] = ("move %d stray files out of the library"):format(n.move) end
        if n.relink > 0 then parts[#parts + 1] = ("repair %d links"):format(n.relink) end
        if n.unlink > 0 then parts[#parts + 1] = ("delete %d links"):format(n.unlink) end
        if lulibre.confirm(table.concat(parts, ", ") .. "?") then
          p:close()
          local carried = dupes.propose(orphans.gather(found), "record with no file")
          local out = orphans.apply(found)
          lulibre.notify(orphans.summary(out) .. (carried > 0
            and ("; %d value%s only the removed records had %s proposed for the books that remain: %s reviews them"):format(
              carried, carried == 1 and "" or "s", carried == 1 and "is" or "are", lulibre.hint("review")) or ""),
            #out.failed > 0 and "error" or nil)
          return
        end
      end
    end
    p:rows(build())
    p:title(title())
    about:update(row)
  end
end

return M
