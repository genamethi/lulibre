--- Shows a dialog: a pane of checkboxes, choices, typed values and actions,
-- under headings. The dialog takes the keys while it is open, and returns
-- the values when you choose one of its actions.
--
-- An item with `off` set is greyed out, shows why, and can't be changed.
-- The kinds of item are check, choice, number, text, action and note (a
-- line of text).
--
-- @module lulibre.ui.form
-- @usage
-- local form = require "lulibre.ui.form"
-- local did, v = form.run {
--   title = "propose and review",
--   sections = {
--     { title = "Fields", items = {
--         { id = "title", kind = "check", label = "title", value = true },
--         { id = "order", kind = "choice", label = "order", choices = { "surest first", "by id" }, value = 1 },
--         { id = "floor", kind = "number", label = "show nothing below", value = 0 },
--         { id = "learned", kind = "check", label = "learned subjects", off = "nothing learned yet: :learn" },
--     } },
--     { title = "", items = { { id = "go", kind = "action", label = "Propose, then review" } } },
--   },
-- }
-- -- did: the id of the action chosen, or nil when the dialog was closed
-- -- v: { title = true, order = 1, floor = 0, learned = false }
local M = {}

local keys = require("lulibre.ui.keys").of("form")

--- Shows the dialog and waits until you choose an action or close the dialog.
-- @tparam table spec `{ title=, sections = { {title=, items = {...}}, ... } }`
-- @treturn string|nil the id of the chosen action, or nil if the dialog was closed
-- @treturn table each item's value, by id
function M.run(spec)
  local at -- row -> item
  local function build()
    local rows = {}
    at = {}
    for _, section in ipairs(spec.sections) do
      if section.title and section.title ~= "" then
        rows[#rows + 1] = { "── " .. section.title .. " " .. ("─"):rep(math.max(4, 60 - #section.title)), style = "head" }
      end
      for _, item in ipairs(section.items) do
        local mark, value = "", ""
        if item.kind == "check" then mark = item.value and not item.off and "[x]" or "[ ]"
        elseif item.kind == "choice" then mark, value = " ‹›", tostring(item.choices[item.value] or "")
        elseif item.kind == "number" or item.kind == "text" then mark, value = "  =", tostring(item.value or "")
        elseif item.kind == "action" then mark = "  ▶" end
        if item.kind == "note" then
          rows[#rows + 1] = { "      " .. item.label, style = "note" }
        else
          rows[#rows + 1] = { mark, item.label, item.off and ("(%s)"):format(item.off) or value ~= "" and value or (item.hint or ""),
            style = item.off and "dim" or item.kind == "action" and "accent" or nil }
        end
        at[#rows] = item
      end
    end
    return rows
  end
  local p <close> = lulibre.panel {
    title = spec.title or "", help = spec.help or keys:hint("toggle", "change", "go"), height = spec.height or 0.7, keys = keys:own(),
    dialog = true,
    columns = { { "", 4 }, { "", spec.label_width or 44 }, { "", -1 } }, rows = build(),
  }
  -- start on the first thing that can be changed
  for i = 1, 200 do
    if at[i] and at[i].kind ~= "note" and not at[i].off then
      p:cursor(i)
      break
    end
  end
  local function values()
    local v = {}
    for _, section in ipairs(spec.sections) do
      for _, item in ipairs(section.items) do
        if item.id and item.kind ~= "action" and item.kind ~= "note" then
          if item.off then v[item.id] = item.kind == "check" and false or item.value
          else v[item.id] = item.value end
        end
      end
    end
    return v
  end
  local function redraw(row)
    p:rows(build())
    if row then p:cursor(row) end
  end
  while true do
    local key, row = p:wait()
    if not key then return nil end
    local item = at[row]
    local act = keys:action(key)
    if act == "help" then
      keys:show(spec.title or "dialog")
    elseif act == "go" then
      for _, section in ipairs(spec.sections) do
        for _, it in ipairs(section.items) do
          if it.kind == "action" and not it.off then return it.id, values() end
        end
      end
    elseif item and item.off then
      lulibre.notify(item.off)
    elseif item and (act == "toggle" or act == "change" or act == "next" or act == "prev") then
      if item.kind == "check" and act ~= "next" and act ~= "prev" then
        item.value = not item.value
        if spec.changed then spec.changed(item, spec) end
        redraw(row)
      elseif item.kind == "choice" then
        local n = #item.choices
        item.value = ((item.value or 1) - 1 + (act == "prev" and -1 or 1)) % n + 1
        if spec.changed then spec.changed(item, spec) end
        redraw(row)
      elseif (item.kind == "number" or item.kind == "text") and act == "change" then
        local typed = lulibre.input { prompt = item.label .. ": ", default = tostring(item.value or "") }
        if typed then
          if item.kind == "number" then
            local n = tonumber(typed)
            if n then item.value = n else lulibre.notify(("'%s' is not a number"):format(typed), "error") end
          else
            item.value = typed
          end
          if spec.changed then spec.changed(item, spec) end
          redraw(row)
        end
      elseif item.kind == "action" and act == "change" then
        return item.id, values()
      end
    end
  end
end

return M
