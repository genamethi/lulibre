--- Settings in a file: `lua/config/options.lua` in the configuration folder,
-- and the `require "config.options"` in init.lua that loads it. The one
-- writer: lulibre-setup (setup/options.lua) and the Configuration tab both
-- come here.
--
-- Only what is asked for changes. A line of the file that sets a setting is
-- replaced when its value changes and left alone when it already gives that
-- value, however it is written; every other line is kept. The file as it was
-- stays in `options.lua.bak`, and an init.lua changed in `init.lua.bak`.
--
--     local options = require "lulib._options"
--     options.write(options.pending())
--     options.link()
--
-- @library lulib._options
local M = {}

local REQUIRE = 'require "config.options"'
local HEADER = "local opt = lulib.opt"

local function read(path)
  local f = io.open(path)
  if not f then return nil end
  local s = f:read("a")
  f:close()
  return s
end

local function replace(path, text)
  local f = assert(io.open(path .. ".new", "w"))
  f:write(text)
  f:close()
  assert(os.rename(path .. ".new", path))
end

local function folder(dir)
  os.execute(("mkdir -p '%s'"):format((dir:gsub("'", "'\\''"))))
end

local function lines_of(text)
  local out = {}
  for line in (text:sub(-1) == "\n" and text or text .. "\n"):gmatch("(.-)\n") do out[#out + 1] = line end
  return out
end

--- The path of options.lua.
function M.path() return setman.get("path.config") .. "/lua/config/options.lua" end

--- The path of init.lua.
function M.init_path() return setman.get("path.config") .. "/init.lua" end

-- what follows a setting's name on a line that sets it, as Lua: the value's
-- expression. nil when the line does not set it.
local function expression(line, name)
  local q = name:gsub("%p", "%%%0")
  return line:match("^%s*opt%." .. q .. "%s*=%s*(.+)$")
    or line:match("^%s*lulib%.opt%." .. q .. "%s*=%s*(.+)$")
    or line:match("^%s*opt%[%s*[\"']" .. q .. "[\"']%s*%]%s*=%s*(.+)$")
    or line:match("^%s*lulib%.opt%[%s*[\"']" .. q .. "[\"']%s*%]%s*=%s*(.+)$")
    or line:match("^%s*setman%.set%(%s*[\"']" .. q .. "[\"']%s*,%s*(.-)%s*%)%s*$")
end

local function commented(line, name)
  local q = name:gsub("%p", "%%%0")
  return line:find("^%s*%-%-%s*opt%." .. q .. "%s*=") ~= nil
    or line:find("^%s*%-%-%s*opt%[%s*[\"']" .. q .. "[\"']%s*%]%s*=") ~= nil
end

-- what an expression comes to; nil when that can't be told
local function value_of(expr)
  local f = load("return " .. expr, "=options.lua", "t", setmetatable({ opt = lulib.opt }, { __index = _G }))
  if not f then return nil end
  local ok, v = pcall(f)
  if ok then return v end
  return nil
end

local function same(a, b)
  if a == nil or b == nil then return false end
  if type(a) == "string" then a = a:gsub("^~", os.getenv("HOME") or "~") end
  if type(b) == "string" then b = b:gsub("^~", os.getenv("HOME") or "~") end
  return tostring(a) == tostring(b)
end

--- The settings options.lua sets now.
-- @treturn table name to value; `true` for a value that can't be told
function M.says()
  local out = {}
  local text = read(M.path())
  if not text then return out end
  local lines = lines_of(text)
  for _, name in ipairs(setman.ls()) do
    for _, line in ipairs(lines) do
      local expr = expression(line, name)
      if expr then
        local v = value_of(expr)
        out[name] = v == nil and true or v
      end
    end
  end
  return out
end

-- a value as Lua source
local function literal(value)
  if type(value) == "string" then return ("%q"):format(value) end
  return tostring(value)
end

-- the left side of a setting's line. A dotted name made in Lua is in brackets:
-- run before the script that makes it, `opt.mine.colour` would be an error
local function target(name)
  if name:find(".", 1, true) and setman.info(name).made then return ("opt[%q]"):format(name) end
  return "opt." .. name
end

-- a path as it reads from any folder
local function absolute(info, value)
  if info.type == "path" and type(value) == "string" and value ~= "" and not value:find("^[/~]") then
    local here = os.getenv("PWD")
    if here then return (value == "." and here) or (here .. "/" .. value) end
  end
  return value
end

--- What is not in options.lua yet: each setting not at its default whose
-- value the file does not give, and each at its default that the file still
-- sets. What the command line gave is for its run, and stays out.
-- @treturn {table,...} `{ name=, value= }` each; no value takes the line out
function M.pending()
  local out = {}
  local says = M.says()
  for _, name in ipairs(setman.ls()) do
    local i = setman.info(name)
    if not i.fixed then
      if i.from == "default" then
        if says[name] ~= nil then out[#out + 1] = { name = name } end
      elseif i.from ~= "command line" and says[name] ~= true and not same(says[name], i.value) then
        out[#out + 1] = { name = name, value = absolute(i, i.value) }
      end
    end
  end
  return out
end

--- Writes settings into options.lua.
-- @tparam {table,...} items `{ name=, value= }` each; no value takes the setting's line out
-- @tparam[opt] table o `{ defaults = true }`: every setting with no line gets one, commented out, with its default
-- @treturn string the path
-- @treturn[2] boolean whether there was a file before
function M.write(items, o)
  o = o or {}
  local path = M.path()
  folder((path:gsub("/[^/]*$", "")))
  local before = read(path)
  local text = before or ("-- lulibre's settings; init.lua loads them with `%s`\n%s\n"):format(REQUIRE, HEADER)
  local lines = lines_of(text)
  -- opt, where the file has none: after its first comments
  if not text:find("local%s+opt%s*=%s*lulib%.opt") then
    local at = 1
    while lines[at] and lines[at]:find("^%-%-") do at = at + 1 end
    table.insert(lines, at, HEADER)
  end
  for _, it in ipairs(items) do
    local new = it.value ~= nil and ("%s = %s"):format(target(it.name), literal(it.value))
    local found
    for i = #lines, 1, -1 do
      if expression(lines[i], it.name) then
        if new and not found then lines[i] = new else table.remove(lines, i) end
        found = true
      end
    end
    if new and not found then
      -- in the place of its line commented out, where there is one
      for i = #lines, 1, -1 do
        if commented(lines[i], it.name) then
          lines[i] = new
          found = true
          break
        end
      end
    end
    if new and not found then lines[#lines + 1] = new end
  end
  if o.defaults then
    for _, name in ipairs(setman.ls()) do
      local i = setman.info(name)
      local there
      for _, line in ipairs(lines) do there = there or expression(line, name) or commented(line, name) end
      if not there and not i.fixed then
        local d = i.default
        if i.type == "integer" or i.type == "number" then d = tonumber(d) or d
        elseif i.type == "boolean" then d = d == true or d == "true" end
        lines[#lines + 1] = ("-- %s = %s"):format(target(name), literal(d))
      end
    end
  end
  local out = table.concat(lines, "\n") .. "\n"
  if before and before ~= out then replace(path .. ".bak", before) end
  replace(path, out)
  return path, before ~= nil
end

-- init.lua without its comments
local function code_of(text)
  return (text:gsub("%-%-%[%[.-%]%]", ""):gsub("%-%-[^\n]*", ""))
end

--- Whether init.lua loads options.lua.
-- @treturn boolean|nil nil when there is no init.lua
function M.loads()
  local text = read(M.init_path())
  if not text then return nil end
  return code_of(text):find("require%s*%(?%s*[\"']config%.options[\"']") ~= nil
end

--- Makes init.lua load options.lua: an init.lua with only that where there is
-- none; in one that doesn't, the line commented out comes alive, else the line
-- goes at the end, after what makes settings of its own.
-- @treturn string what was done: `"there"`, `"created"` or `"added"`
function M.link()
  local path = M.init_path()
  local text = read(path)
  if not text then
    folder(setman.get("path.config"))
    replace(path, REQUIRE .. "\n")
    return "created"
  end
  if M.loads() then return "there" end
  replace(path .. ".bak", text)
  local lines = lines_of(text)
  for i, line in ipairs(lines) do
    local live = line:match("^%s*%-%-%s*(require%s*%(?%s*[\"']config%.options[\"']%s*%)?)%s*$")
    if live then
      lines[i] = live
      replace(path, table.concat(lines, "\n") .. "\n")
      return "added"
    end
  end
  lines[#lines + 1] = REQUIRE
  replace(path, table.concat(lines, "\n") .. "\n")
  return "added"
end

return M
