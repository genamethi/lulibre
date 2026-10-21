--- Shows the config window (the bar's tab 3, :config, gC) in place of the
-- list, until you choose tab 1 or 2. The window lists every option:
-- lulibre's own under their headings, and each script's under the script's
-- name, with the value, the default and where the option is set. Below the
-- list, a panel says what the option under the cursor does.
--
-- A value changed here takes effect at once and is written to init.lua,
-- after the old file is saved as init.lua.bak. E opens init.lua in your
-- editor ($VISUAL, $EDITOR, or else vim or vi), and lulibre reads the file
-- again when you leave the editor.
--
-- @module lulibre.ui.config
-- @usage
-- require("lulibre.ui.config").run()   -- as :config, gC, 3 does
local cf = require "lulibre.config_file"
local options = require "lulibre.options"
local panels = require "lulibre.ui.panels"

local M = {}

local keys = require("lulibre.ui.keys").of("config")
local asked -- the offer to put missing options in init.lua is made once a session

local function show(v)
  if v == nil then return "" end
  if type(v) == "string" then return v == "" and '""' or v end
  return tostring(v)
end

-- every option, as items: { name=, ns= (a script's), value=, default=, help=, choices=, type=, group= }
local function items()
  local out = {}
  for _, name in ipairs(lulibre.settings.names()) do
    local i = lulibre.settings.info(name)
    out[#out + 1] = { name = name, value = i.value, default = i.default, help = i.help, choices = i.choices, type = i.type,
      group = i.group or "lulibre" }
  end
  for _, ns in ipairs(options.namespaces()) do
    for _, o in ipairs(options.list(ns)) do
      local s = o.spec or {}
      out[#out + 1] = { ns = ns, name = o.name, value = o.value, default = o.default, help = s.help, choices = s.choices,
        type = s.type, group = "options of " .. ns, from = o.from, undeclared = o.spec == nil }
    end
  end
  return out
end

--- Returns what the panel below the window shows for an option. Replace
-- this function in init.lua to change the panel.
-- @tparam table it the option, as the window lists it
-- @tparam[opt] string line the line of init.lua that names the option
-- @treturn {table,...} rows of `{ label, text, style = }`
function M.context(it, line)
  local rows = { { it.ns and ("%s.%s"):format(it.ns, it.name) or it.name, it.group, style = "head" } }
  rows[#rows + 1] = { "value", show(it.value) }
  rows[#rows + 1] = { "default", show(it.default) }
  if it.choices then rows[#rows + 1] = { "takes", table.concat(it.choices, " | ") }
  elseif it.type then rows[#rows + 1] = { "takes", it.type == "path" and "a path (~ is your home)" or ("a " .. it.type) } end
  rows[#rows + 1] = { "in init.lua", line and ("line %d: %s"):format(line.n, line.text) or "not mentioned", style = line and nil or "dim" }
  if it.undeclared then rows[#rows + 1] = { "", "set in init.lua, but no script has declared it (yet)", style = "warn" } end
  rows[#rows + 1] = { "" }
  local help = it.help and it.help ~= "" and it.help or "(no help is given for this one)"
  local line_, first = "", true
  for word in help:gmatch("%S+") do
    if #line_ + #word > 72 then
      rows[#rows + 1] = { first and "what it does" or "", line_ }
      first, line_ = false, word
    else
      line_ = line_ == "" and word or line_ .. " " .. word
    end
  end
  if line_ ~= "" then rows[#rows + 1] = { first and "what it does" or "", line_ } end
  return rows
end

local open_now -- the window while it is open: the bar's tab opens it once

--- Opens the window. Does nothing if the window is already open.
function M.run()
  if open_now and open_now:is_open() then return end
  local only_changed = false
  local list, text
  local function load()
    list = items()
    text = cf.read() or ""
  end
  load()
  -- options that are not in init.lua: offered once a session, if config_add_* says ask
  if not asked then
    asked = true
    local missing = cf.missing()
    local core = lulibre.o.config_add_core == "ask" and #missing.core or 0
    local scripts = lulibre.o.config_add_scripts == "ask" and #missing.scripts or 0
    if core + scripts > 0 and lulibre.confirm(("%d of lulibre's options%s are not in init.lua. Add them %s? (Press %s in this window to add them later.)")
        :format(core, scripts > 0 and (" and %d of the scripts' options"):format(scripts) or "",
          lulibre.o.config_add_as == "set" and "set to their defaults" or "commented out, with their defaults",
          keys:key("add") or "a")) then
      local add = {}
      for _, n in ipairs(core > 0 and missing.core or {}) do add[#add + 1] = { name = n } end
      for _, it in ipairs(scripts > 0 and missing.scripts or {}) do add[#add + 1] = it end
      lulibre.notify(("Added %d options to %s."):format(cf.add(add), cf.path()))
      load()
    end
  end
  local shown -- row -> item
  local function rows()
    local out, group = {}, nil
    shown = {}
    for _, it in ipairs(list) do
      local changed = show(it.value) ~= show(it.default)
      if not only_changed or changed then
        if it.group ~= group then
          group = it.group
          out[#out + 1] = { group, "", "", "", style = "head" }
          shown[#out] = false
        end
        local n, l = cf.line_of(it, text)
        local in_file = n and not l:find("^%s*%-%-")
        out[#out + 1] = { (it.ns and it.ns .. "." or "") .. it.name, show(it.value), show(it.default),
          in_file and ("init.lua:%d"):format(n) or (it.from == "session" and "this session" or ""),
          style = changed and "accent" or nil }
        shown[#out] = it
      end
    end
    return out
  end
  local function title()
    return ("configuration   %s comments: %s%s   %s"):format(keys:key("comments") or "c", lulibre.o.config_comments,
      only_changed and "   (only what differs from the default)" or "", cf.path())
  end
  -- the bar's Configuration tab: in the list's place, until the list's tabs are chosen
  local p <close> = lulibre.panel {
    title = title(), help = keys:hint("edit", "default", "editor", "add", "changed"), side = "main", moves = true,
    screen_tab = true, keys = keys:own(), pass = panels.PASS .. " sync", rows = rows(),
    columns = { { "option", 30 }, { "value", -2 }, { "default", -1 }, { "set in", 16 } },
  }
  open_now = p
  local ctx
  local closing <close> = setmetatable({}, { __close = function()
    if ctx then pcall(ctx.close, ctx) end
    open_now = nil
  end })
  local function about(row)
    local it = shown[row]
    if not it then return end
    if not ctx or not ctx:is_open() then
      ctx = lulibre.panel { title = "the option under the cursor", height = 0.35, focus = false,
        columns = { { "", 14 }, { "", 0 } }, rows = {} }
    end
    local n, l = cf.line_of(it, text)
    local ok, r = pcall(M.context, it, n and { n = n, text = l } or nil)
    ctx:rows(ok and r or { { "", tostring(r), style = "error" } })
  end
  local cur = 2
  p:cursor(cur)
  about(cur)
  while true do
    local key, row = p:wait()
    if not key then return end
    cur = row or cur
    local it = shown[cur]
    local act = keys:action(key)
    -- the options lulibre's systemd units follow (lulibre.units): changed
    -- here, the units are changed now (asking before sudo, or a restart)
    local function units_follow(name)
      if it.ns or not (name == "server_hook" or name == "opf_writer" or name == "server_restart_at") then return end
      local units = require "lulibre.units"
      local ok, said = pcall(function() return units.apply(units.plan(), lulibre.confirm) end)
      if not ok then lulibre.notify(tostring(said), "error")
      elseif #said > 0 then lulibre.show(said, "calibre's server and lulibre's systemd units") end
    end
    local function set(value)
      local ok, err = pcall(function()
        if it.ns then options.set(it.ns, it.name, value, "session")
        else lulibre.settings.set(it.name, value) end
      end)
      if not ok then
        lulibre.notify(tostring(err):gsub("^.-:%d+: ", ""), "error")
        return
      end
      local v = it.ns and options.get(it.ns, it.name) or lulibre.settings.get(it.name)
      cf.write_value(it, v)
      lulibre.notify(("%s = %s, and written to init.lua"):format(it.name, show(v)))
      units_follow(it.name)
    end
    if key == "<Move>" then
      about(cur)
    elseif act == "help" then
      keys:show("config", panels.also())
    elseif it and act == "edit" then
      local v = lulibre.input { prompt = it.name .. " = ", default = show(it.value) ~= '""' and show(it.value) or "",
        suggestions = it.choices }
      if v then set(v) end
    elseif it and act == "default" then
      if it.ns then options.reset(it.ns, it.name) else lulibre.settings.reset(it.name) end
      cf.write_value(it, nil)
      lulibre.notify(("%s back to its default, %s (the line in init.lua is commented out)"):format(it.name, show(it.default)))
      units_follow(it.name)
    elseif act == "editor" then
      local status, why = lulibre.edit_file(cf.path())
      if not status then lulibre.notify(why, "error")
      else
        -- what was written there takes effect: init.lua is read again
        lulibre.exec("reload-cfg")
        lulibre.notify("init.lua read again")
      end
    elseif act == "add" then
      local missing = cf.missing()
      local add = {}
      for _, n in ipairs(missing.core) do add[#add + 1] = { name = n } end
      for _, x in ipairs(missing.scripts) do add[#add + 1] = x end
      if #add == 0 then lulibre.notify("Every option is in init.lua already.")
      elseif lulibre.confirm(("Add %d options to init.lua, %s?"):format(#add,
          lulibre.o.config_add_as == "set" and "set to their defaults" or "commented out, with their defaults")) then
        lulibre.notify(("Added %d options to %s."):format(cf.add(add), cf.path()))
      end
    elseif act == "comments" then
      local nxt = { full = "values", values = "none", none = "full" }
      lulibre.settings.set("config_comments", nxt[lulibre.o.config_comments] or "full")
      cf.write_value({ name = "config_comments" }, lulibre.o.config_comments)
    elseif act == "changed" then
      only_changed = not only_changed
    end
    if key ~= "<Move>" then
      load()
      p:rows(rows())
      p:title(title())
      p:cursor(cur)
      about(cur)
    end
  end
end

return M
