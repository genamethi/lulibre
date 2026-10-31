--- The Configuration tab (:config): every setting, lulibre's and those
-- made in Lua, as a form in the list's place. A row is a setting: its
-- value (a path left empty, the one lulibre works out) and where it comes
-- from (nothing when it is the default); a band below says what the
-- setting under the cursor does, its default and what it takes. A change takes effect at once and holds for the run (with
-- persistent on, it is kept). One of the settings lulibre's systemd units
-- follow is applied to them at once (units.follow).
--
-- Its keys are the form's (edit) and the screen config's: cycle (Space,
-- the next of a setting's choices, or true for false), default (d) and
-- changed (c, only the settings not at their default).
--
-- @library lulib._config
local M = {}
local own, get = require "lulib._expose" (M) -- internal functions (expose_modules)

M.screen = {
  title = "Configuration",
  tab = true,
  actions = {
    { "cycle", "<Space>", "the next of the setting's choices (true, false)" },
    { "default", "d", "the setting back to its default" },
    { "changed", "c", "only the settings not at their default, or every one again" },
  },
  hint = { "cycle", "default", "changed" },
  views = { about = { kind = "band", size = 0.3 } }, -- what the setting under the cursor does
}
scrnman.create("config", M.screen)

-- a value as the row shows it
function own.shown(v)
  if v == "" then return '""' end
  return tostring(v)
end

-- where a value comes from, as the row says it: nothing for the default
local FROM = { default = "", saved = "saved", set = "set", ["command line"] = "command line" }

--- The settings the tab lists, in setman.ls's order (lulibre's first), as
-- setman.info gives them; only those not at their default with changed.
function M.settings(changed)
  local out = {}
  for _, name in ipairs(setman.ls()) do
    local i = setman.info(name)
    if not i.fixed and (not changed or i.from ~= "default") then out[#out + 1] = i end
  end
  return out
end

--- The band's rows for a setting: `{label, text}` each.
function M.about(i)
  local rows = {}
  local line, first = "", true
  for word in (i.help ~= "" and i.help or "(no help is given for this one)"):gmatch("%S+") do
    if #line + #word > 96 then
      rows[#rows + 1] = { first and "what it does" or "", line }
      first, line = false, word
    else
      line = line == "" and word or line .. " " .. word
    end
  end
  rows[#rows + 1] = { first and "what it does" or "", line }
  rows[#rows + 1] = { "default", get("shown")(i.default) }
  rows[#rows + 1] = { "takes", i.choices and table.concat(i.choices, " | ")
    or (i.type == "path" and "a path (~ is your home)" or i.type == "integer" and "an integer" or ("a " .. i.type)) }
  rows[#rows + 1] = { "set", i.from == "default" and "nowhere: its default" or i.from }
  if i.made then rows[#rows + 1] = { "", "made in Lua (setman.create)", style = "dim" } end
  return rows
end

-- the value after v among the setting's choices, or the other boolean
function own.next(i)
  if i.type == "boolean" then return not i.value end
  if not i.choices then return nil end
  for k, c in ipairs(i.choices) do
    if c == tostring(i.value) then return i.choices[k % #i.choices + 1] end
  end
  return i.choices[1]
end

-- set name to v (nil: its default); its error shown; the units follow
function own.change(name, v)
  local ok, err = pcall(setman.set, name, v)
  if not ok then
    uiman.notify(tostring(err):gsub("^.-:%d+: ", ""), "error")
    return
  end
  local units_ok, why = pcall(require("units").follow, name)
  if not units_ok then uiman.notify(tostring(why), "error") end
end

local open_now -- the tab while it is open: :config again comes back to it

--- Opens the tab, or brings it back.
function M.open()
  if open_now and open_now:is_open() then return open_now:focus() end
  local changed = false
  local list
  local function rows()
    list = M.settings(changed)
    local out = {}
    for k, i in ipairs(list) do out[k] = { i.name, get("shown")(setman.get(i.name)), FROM[i.from] or i.from } end
    return out
  end
  local function title()
    local kept = setman.get("persistent") and "changes are kept (persistent)" or "changes hold for this run"
    return ("configuration   %s%s"):format(kept, changed and "   (only those not at their default)" or "")
  end
  local p <close> = uiman.panel {
    title = title(), screen = "config", form = true, moves = true, side = "main",
    columns = { { "Setting", 22 }, "Value", { "Set", 13 } }, rows = rows(),
  }
  open_now = p
  local band <close> = uiman.panel { title = "the setting under the cursor", screen = "config", view = "about", focus = false,
    columns = { { "", 14 }, "" }, rows = {} }
  local function show(at)
    local i = list[at]
    band:rows(i and M.about(i) or {})
    band:title(i and i.name or "the setting under the cursor")
  end
  show(1)
  while true do
    local action, at, value = p:wait()
    if not action then break end
    local i = list[at]
    if action == "edit" and i then
      get("change")(i.name, value)
    elseif action == "cycle" and i then
      local nxt = get("next")(i)
      if nxt == nil then uiman.notify(i.name .. " takes any value: e or Enter types one")
      else get("change")(i.name, nxt) end
    elseif action == "default" and i then
      get("change")(i.name, nil)
    elseif action == "changed" then
      changed = not changed
    end
    if action ~= "<Move>" then
      -- (a value set reaches the store and comes back in a turn of the loop)
      taskman.sleep(10)
      p:rows(rows())
      p:title(title())
    end
    show(math.min(at or 1, math.max(1, #list)))
  end
  open_now = nil
end

cmdman.create("config", function() M.open() end,
  { desc = "the settings, in the Configuration tab: change one, see what it does and where it is set" })

return M
