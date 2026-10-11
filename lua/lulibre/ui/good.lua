-- Known good: the records by how complete and clean they look, for
-- confirming the ones that are right. What lulibre learns about subjects
-- (:learn) it learns from the confirmed ones.
local edit = require "lulibre.edit"
local keys = require("lulibre.ui.keys").of("good")
local panels = require "lulibre.ui.panels"
local quality = require "lulibre.quality"

local M = {}

local VIEWS = { "to confirm", "confirmed", "all" }

function M.run()
  local view = 1
  local ranked, shown
  local function load()
    lulibre.progress("scoring the records…")
    ranked = quality.ranked()
    lulibre.progress(nil)
  end
  local function build()
    local rows = {}
    shown = {}
    for _, r in ipairs(ranked) do
      if view == 3 or (view == 1) == not r.good then
        local b = r.book
        rows[#rows + 1] = { r.good and "✓" or "", ("%.2f"):format(r.score), b.id, b.title or "",
          edit.is_unknown(b.author) and "" or b.author, table.concat(b.tags, ", "), b.year or "",
          table.concat(r.why, "; "), id = b.id, style = r.good and "ok" or (r.score < 0.6 and "dim" or nil) }
        shown[#rows] = r
      end
    end
    return rows
  end
  local function title()
    local good, ready = 0, 0
    for _, r in ipairs(ranked) do
      if r.good then good = good + 1 elseif r.score >= 0.85 then ready = ready + 1 end
    end
    return ("known good  %d confirmed of %d   %d more score 0.85 or above   showing: %s"):format(good, #ranked, ready,
      VIEWS[view])
  end

  load()
  if #ranked == 0 then
    lulibre.notify("the library is empty")
    return
  end
  local p <close> = lulibre.panel {
    title = title(), help = keys:hint("confirm", "confirm_above", "view", "learn"), follow = true, height = 0.5,
    keys = keys:own(), pass = panels.PASS, reloads = true,
    columns = { { "", 1 }, { "Score", 5 }, { "Id", 6 }, { "Title", -4 }, { "Authors", -2 }, { "Subject", -2 }, { "Year", 4 },
      { "Holding it down", -3 } },
    rows = build(),
  }
  local peek = panels.peeker(p, 0.5)

  while true do
    local key, row = p:wait()
    if not key then return end
    local r = shown[row]
    local act = keys:action(key)
    local keep = r and r.book.id
    if key == "<Reload>" then
      load()
    elseif act == "help" then
      keys:show("known good", panels.also())
    elseif act == "peek" then
      peek()
    elseif r and act == "confirm" then
      r.good = not r.good
      quality.set_good({ r.book.id }, r.good)
      keep = shown[row + 1] and shown[row + 1].book.id or keep -- on to the next, as marking does
    elseif act == "confirm_above" then
      local v = lulibre.input { prompt = "confirm every record scoring at least: ", default = "0.85" }
      local floor = tonumber(v or "")
      if floor then
        local ids = {}
        for _, q in ipairs(ranked) do
          if not q.good and q.score >= floor then
            q.good = true
            ids[#ids + 1] = q.book.id
          end
        end
        quality.set_good(ids, true)
        lulibre.notify(("confirmed %d records; %s learns each subject's phrases from the confirmed ones"):format(#ids,
          keys:key("learn") or ":learn"))
      end
    elseif act == "view" then
      view = view % #VIEWS + 1
    elseif r and act == "edit" then
      panels.over(p, require("lulibre.ui.edit").run, { ids = { r.book.id } })
      load()
    elseif act == "learn" then
      panels.over(p, function() lulibre.exec("learn") end)
    end
    p:rows(build())
    p:title(title())
    if keep then
      for i, q in ipairs(shown) do
        if q.book.id == keep then
          p:cursor(i)
          break
        end
      end
    end
  end
end

return M
