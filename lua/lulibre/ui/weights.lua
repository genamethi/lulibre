--- How much each kind of source is believed about each field: as measured
-- against the library (:weigh), and as set by hand where you know better.
--
-- @module lulibre.ui.weights
-- @usage
-- require("lulibre.ui.weights").run()   -- as :weights, <Leader>w does
local consensus = require "lulibre.consensus"

local M = {}

local keys = require("lulibre.ui.keys").of("weights")

--- Open the table of weights.
function M.run()
  if not consensus.ready() then
    if not lulibre.confirm("the sources have not been measured against the library yet; measure them now? (some seconds)") then return end
    consensus.learn()
  end
  local list
  local function build()
    list = consensus.table()
    local rows, last = {}, nil
    for i, r in ipairs(list) do
      rows[i] = { r.field ~= last and r.field or "", r.kind, r.n > 0 and ("%d of %d"):format(r.agree, r.n) or "",
        r.measured and ("%.2f"):format(r.measured) or (r.n > 0 and "(too few)" or ""), r.manual and ("%.2f"):format(r.manual) or "",
        r.weight and ("%.2f"):format(r.weight) or "its own", style = r.manual and "accent" or (not r.weight and "dim") or nil }
      last = r.field
    end
    return rows
  end
  local p <close> = require("lulibre.ui.panels").open("weights", {
    title = "how much each source is believed, field by field", help = keys:hint("set", "clear", "measure"), height = 0.6, keys = keys:own(),
    columns = { { "field", 11 }, { "source", -1 }, { "agreed with the library", 24 }, { "measured", 10 }, { "by hand", 8 }, { "in force", 9 } },
    rows = build(),
  })
  if not p then return end
  while true do
    local key, row = p:wait()
    if not key then return end
    local r = list[row]
    local act = keys:action(key)
    if act == "help" then
      keys:show("source weights", {
        "", "A weight is the share of times a kind of source agreed with the library's own",
        "records about a field, where those are worth trusting. With the option weigh_sources",
        "on, a proposal's confidence is worked out from these instead of from what each rule",
        "claims for itself. A weight set by hand is used as it stands.",
      })
    elseif act == "set" and r then
      local typed = lulibre.input { prompt = ("believe %s about %s (0 to 1): "):format(r.kind, r.field), default = r.weight and ("%.2f"):format(r.weight) or "" }
      local w = tonumber(typed or "")
      if w and w >= 0 and w <= 1 then
        consensus.set(r.kind, r.field, w)
        p:rows(build())
        p:cursor(row)
      elseif typed and typed ~= "" then
        lulibre.notify("a weight is a number from 0 to 1", "error")
      end
    elseif act == "clear" and r then
      consensus.set(r.kind, r.field, nil)
      p:rows(build())
      p:cursor(row)
    elseif act == "measure" then
      local used = consensus.learn()
      lulibre.notify(("measured against %d books"):format(used))
      p:rows(build())
    end
  end
end

return M
