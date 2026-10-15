-- The snapshot browser (:snapshots, gz): the snapshots along the bottom, and
-- where the list is, what going back to the one under the cursor would do.
-- Going back asks first; the flags it would go back with are in the title.
local snapshots = require "lulibre.snapshots"
local panels = require "lulibre.ui.panels"

local M = {}

local keys = require("lulibre.ui.keys").of("snapshots")

local function when(ts) return os.date("%Y-%m-%d %H:%M", ts) end

--- What the panel where the list is shows for a snapshot: rows of
-- { label, text, style = }. Replace it in init.lua to show it your way.
function M.context(snap, plan)
  local rows = { { ("snapshot %d"):format(snap.id), snap.name, style = "head" },
    { "taken", when(snap.ts) .. (snap.auto == 1 and "   (by a rollback: going back to it rolls forward)" or "") } }
  if snap.note and snap.note ~= "" then rows[#rows + 1] = { "note", snap.note, style = "dim" } end
  if snap.retired then rows[#rows + 1] = { "retired", when(snap.retired), style = "dim" } end
  rows[#rows + 1] = { "since", ("%d changes on %d books"):format(snap.changes or 0, snap.books or 0) }
  rows[#rows + 1] = { "" }
  for i, line in ipairs(snapshots.describe(plan)) do
    rows[#rows + 1] = { i == 1 and "going back" or "", (line:gsub("^%s+", "")), style = i == 1 and "head" or nil }
  end
  -- the books it would touch, a few of them
  local seen, n = {}, 0
  for _, c in ipairs(plan.changes) do
    if not seen[c.id] and n < 12 then
      seen[c.id] = true
      n = n + 1
      local book = lulibre.book(c.id)
      rows[#rows + 1] = { n == 1 and "for example" or "", ("%d  %s: %s → %s"):format(c.id, (book and book.title or ""):sub(1, 40),
        c.field, c.value == "" and "(blank)" or c.value:sub(1, 50)), style = "dim" }
    end
  end
  return rows
end

function M.run()
  local flags = { exact = false, unsync = false, fields = false }
  local all = false
  local list = {}
  local function load()
    snapshots.observe()
    list = snapshots.list { all = all }
  end
  local function rows()
    local out = {}
    for _, s in ipairs(list) do
      out[#out + 1] = { tostring(s.id), when(s.ts), s.name, ("%d on %d books"):format(s.changes, s.books),
        (s.auto == 1 and "rollback " or "") .. (s.retired and "retired" or ""), style = s.retired and "dim" or nil }
    end
    if #out == 0 then out[1] = { "", "", ("no snapshots yet: %s takes one"):format(keys:key("take") or "n"), "", "", style = "dim" } end
    return out
  end
  local function title()
    local on = {}
    for _, f in ipairs { "exact", "unsync", "fields" } do
      if flags[f] then on[#on + 1] = "--" .. f end
    end
    return ("snapshots   %d%s   going back: %s"):format(#list, all and " (with the retired)" or "",
      #on > 0 and table.concat(on, " ") or "lulibre's changes only")
  end
  load()
  local p <close> = lulibre.panel {
    title = title(), help = keys:hint("back", "take", "retire", "exact", "unsync"), height = 0.35, moves = true,
    keys = keys:own(), pass = panels.PASS, rows = rows(),
    columns = { { "#", 5 }, { "taken", 17 }, { "name", -2 }, { "changed since", 22 }, { "", 16 } },
  }
  local ctx
  local closing <close> = setmetatable({}, { __close = function()
    if ctx then pcall(ctx.close, ctx) end
  end })
  local function about(row)
    local snap = list[row]
    if not snap then return end
    if not ctx or not ctx:is_open() then
      ctx = lulibre.panel { side = "main", title = "going back to this snapshot", columns = { { "", 14 }, { "", 0 } }, rows = {} }
    end
    local ok, plan = pcall(snapshots.plan, snap, flags)
    local r
    if ok then ok, r = pcall(M.context, snap, plan) else r = plan end
    ctx:rows(ok and r or { { "", tostring(r), style = "error" } })
  end
  about(1)
  local cur = 1
  while true do
    local key, row = p:wait()
    if not key then return end
    cur = row or cur
    local act = keys:action(key)
    local snap = list[cur]
    if key == "<Move>" then
      about(cur)
    elseif act == "help" then
      keys:show("snapshots", panels.also())
    elseif act == "take" then
      local name = lulibre.input { prompt = "name for the snapshot (empty: the time): " }
      if name then
        local s = snapshots.take(name)
        lulibre.notify(("took snapshot %d, \"%s\""):format(s.id, s.name))
        load()
        cur = 1
      end
    elseif act == "exact" or act == "unsync" or act == "fields" then
      flags[act] = not flags[act]
    elseif act == "all" then
      all = not all
      load()
    elseif snap and act == "retire" then
      snapshots.retire(snap.id, not snap.retired)
      lulibre.notify(("snapshot %d %s"):format(snap.id, snap.retired and "back in the list" or "retired"))
      load()
    elseif snap and act == "back" then
      local plan = snapshots.plan(snap, flags)
      if plan.books == 0 then
        lulibre.notify("the library is as it was then: nothing to do")
      elseif lulibre.confirm(("go back to snapshot %d, \"%s\"? (%d fields, as shown)"):format(snap.id, snap.name, #plan.changes)) then
        lulibre.progress("going back")
        local out = snapshots.rollback(snap, flags)
        lulibre.progress(nil)
        lulibre.notify(snapshots.summary(out), #out.failed > 0 and "error" or nil)
        load()
        cur = 1
      end
    end
    if key ~= "<Move>" then
      p:rows(rows())
      p:title(title())
      if cur > #list then cur = math.max(1, #list) end
      p:cursor(cur)
      about(cur)
    end
  end
end

return M
