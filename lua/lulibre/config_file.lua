--- Writes options to init.lua.
-- Options that init.lua does not mention yet are added, commented out and
-- with their defaults. The file then lists what can be set without changing
-- anything. A value set in the config window is written to the line that
-- sets the option. Before each write, the old file is saved as init.lua.bak
-- beside it.
--
-- Added lines look like the rest of the file. First comes a comment that
-- says what the option does (`config_comments = "full"`), or only the values
-- it takes ("values"). Then comes the setting: `-- o.pages = 6` for one of
-- lulibre's options, `-- lulibre.cfg.mytags.depth = 2` for a script's.
--
-- An item names an option: `{ name= }` for one of lulibre's options,
-- `{ ns=, name= }` for a script's.
--
-- @module lulibre.config_file
-- @usage
-- local cf = require "lulibre.config_file"
-- cf.missing()             --> { core = { names }, scripts = { {ns=, name=}, ... } }
-- cf.add({ { name = "pages" } })               -- put it in, commented out with its default
-- cf.write_value({ name = "pages" }, 8)        -- o.pages = 8
-- cf.write_value({ name = "pages" }, nil)      -- -- o.pages = 6, back to its default
-- cf.line_of({ ns = "mytags", name = "depth" }) --> 41, "lulibre.cfg.mytags.depth = 3"
local options = require "lulibre.options"

local M = {}

--- Returns the path of init.lua.
-- @treturn string
function M.path()
  return lulibre.settings.paths().init
end

--- Returns the text of init.lua.
-- @treturn string|nil nil if there is no init.lua
function M.read()
  local f = io.open(M.path(), "r")
  if not f then return nil end
  local text = f:read("a")
  f:close()
  return text
end

local function write(text)
  local path = M.path()
  local dir = path:match("^(.*)/[^/]*$")
  if dir and not io.open(dir .. "/.") then lulibre.system({ "mkdir", "-p", dir }) end
  local old = M.read()
  if old then
    local b = assert(io.open(path .. ".bak", "w"))
    b:write(old)
    b:close()
  end
  local tmp = path .. ".new"
  local f = assert(io.open(tmp, "w"))
  f:write(text)
  f:close()
  assert(os.rename(tmp, path))
end

-- How an option is named in the file: lulibre's own as o.NAME (when the file
-- has `local o = lulibre.o`, as `lulibre config` writes it) or lulibre.o.NAME.
local function lhs(item, text)
  if item.ns then return ("lulibre.cfg.%s.%s"):format(item.ns, item.name) end
  return ((text or ""):find("local%s+o%s*=%s*lulibre%.o") and "o." or "lulibre.o.") .. item.name
end

local function pattern(item)
  local name = item.name:gsub("%p", "%%%0")
  if item.ns then return "cfg%." .. item.ns:gsub("%p", "%%%0") .. "%." .. name .. "%s*=" end
  return "%f[%w_]o%." .. name .. "%s*="
end

--- Finds the line that names an option, commented out or not.
-- @tparam table item
-- @tparam[opt] string text the text of init.lua, read from the file if not given
-- @treturn[1] integer the line's number
-- @treturn[1] string the line
-- @treturn[2] nil if no line names the option
function M.line_of(item, text)
  text = text or M.read() or ""
  local n = 0
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    n = n + 1
    if line:find(pattern(item)) then return n, line end
  end
  return nil
end

--- Returns the options that init.lua does not mention.
-- @treturn table `{ core = { name, ... }, scripts = { {ns=, name=}, ... } }`
function M.missing()
  local text = M.read() or ""
  local out = { core = {}, scripts = {} }
  for _, name in ipairs(lulibre.settings.names()) do
    if not M.line_of({ name = name }, text) then out.core[#out.core + 1] = name end
  end
  for _, ns in ipairs(options.namespaces()) do
    for _, o in ipairs(options.list(ns)) do
      if o.spec and not M.line_of({ ns = ns, name = o.name }, text) then
        out.scripts[#out.scripts + 1] = { ns = ns, name = o.name }
      end
    end
  end
  return out
end

-- a value as Lua writes it
local function literal(v)
  if type(v) == "string" then return ("%q"):format(v) end
  return tostring(v)
end

-- text wrapped to lines of `width`, each begun with "-- "
local function wrap(text, width)
  local out, line = {}, ""
  for word in text:gmatch("%S+") do
    if #line + #word + 1 > width - 3 and line ~= "" then
      out[#out + 1] = "-- " .. line
      line = word
    else
      line = line == "" and word or line .. " " .. word
    end
  end
  if line ~= "" then out[#out + 1] = "-- " .. line end
  return out
end

-- what an option is, for the lines above it: help, or what it takes, or nothing
local function about(item)
  local style = lulibre.o.config_comments
  local help, choices, kind
  if item.ns then
    local s = options.spec(item.ns, item.name) or {}
    help, choices, kind = s.help, s.choices, s.type
  else
    local i = lulibre.settings.info(item.name)
    help, choices, kind = i.help, i.choices, i.type
  end
  if style == "none" then return {} end
  local values = choices and ("(" .. table.concat(choices, " | ") .. ")") or (kind and ("(" .. kind .. ")")) or ""
  if style == "values" then return values ~= "" and { "-- " .. values } or {} end
  -- with no help there is nothing to say: no comment
  if not help or help == "" then return {} end
  local text = help .. (choices and ("  " .. values) or "")
  return wrap(text, 78)
end

local function default_of(item)
  if item.ns then
    local s = options.spec(item.ns, item.name)
    return s and s.default
  end
  return lulibre.settings.info(item.name).default
end

--- Adds options to init.lua with their defaults. lulibre's options go under
-- one heading, and each script's namespace under its own. The option
-- `config_add_as` says whether they are commented out or set.
-- @tparam {table,...} items
-- @treturn integer how many were put in
function M.add(items)
  if #items == 0 then return 0 end
  local text = M.read() or "-- lulibre configuration (see `lulibre config`)\nlocal o = lulibre.o\n"
  local groups, order = {}, {}
  for _, it in ipairs(items) do
    local key = it.ns or ""
    if not groups[key] then
      groups[key] = {}
      order[#order + 1] = key
    end
    table.insert(groups[key], it)
  end
  local out = {}
  for _, key in ipairs(order) do
    out[#out + 1] = ""
    out[#out + 1] = ("-- ---- %s, put here by lulibre on %s ----"):format(
      key == "" and "lulibre's own options" or ("options of " .. key), os.date("%Y-%m-%d"))
    for _, it in ipairs(groups[key]) do
      out[#out + 1] = ""
      for _, l in ipairs(about(it)) do out[#out + 1] = l end
      out[#out + 1] = (lulibre.o.config_add_as == "set" and "%s = %s" or "-- %s = %s"):format(lhs(it, text),
        literal(default_of(it)))
    end
  end
  write(text:gsub("\n*$", "\n") .. table.concat(out, "\n") .. "\n")
  return #items
end

--- Writes an option's value to init.lua. The line that names the option is
-- uncommented and set, or a new line is added.
-- @tparam table item
-- @param value nil resets the option: the line is commented out and shows the default
function M.write_value(item, value)
  local text = M.read() or "local o = lulibre.o\n"
  local n = M.line_of(item, text)
  local line = value == nil and ("-- %s = %s"):format(lhs(item, text), literal(default_of(item)))
    or ("%s = %s"):format(lhs(item, text), literal(value))
  if not n then
    if value == nil then return end
    write(text:gsub("\n*$", "\n") .. "\n" .. line .. "\n")
    return
  end
  local out, i = {}, 0
  for l in (text .. "\n"):gmatch("([^\n]*)\n") do
    i = i + 1
    if i == n then
      -- keep what stood before the name on its line (indentation)
      out[#out + 1] = (l:match("^(%s*)") or "") .. line
    else
      out[#out + 1] = l
    end
  end
  -- (the last line read is the empty one after the final newline)
  if out[#out] == "" then out[#out] = nil end
  write(table.concat(out, "\n") .. "\n")
end

return M
