-- init.lua as lulibre writes to it: options it does not mention yet are put
-- in (commented out, with their defaults, so the file says what can be set
-- and changes nothing), and a value set in the config window is written to
-- the line that sets it. Every write keeps the file as it was in
-- init.lua.bak beside it. Lines it adds look like the rest of the file:
--   -- what the option does (config_comments = "full"), or only the values it takes ("values")
--   -- o.pages = 6                       lulibre's own
--   -- lulibre.cfg.mytags.depth = 2      a script's, under its namespace
--
--   local cf = require "lulibre.config_file"
--   cf.path()                -- init.lua
--   cf.missing()             -- { core = { names }, scripts = { {ns=, name=}, ... } }
--   cf.add(items)            -- put options in, commented out with their defaults
--   cf.write_value(item, v)  -- set one in the file (v == nil: back to its default, commented out)
--   cf.line_of(item)         -- the line that names it, or nil
local options = require "lulibre.options"

local M = {}

function M.path()
  return lulibre.settings.paths().init
end

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

--- The line (number, text) that names an option, commented or not.
function M.line_of(item, text)
  text = text or M.read() or ""
  local n = 0
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    n = n + 1
    if line:find(pattern(item)) then return n, line end
  end
  return nil
end

--- The options init.lua does not mention: { core = { name, ... },
-- scripts = { {ns=, name=}, ... } }.
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

--- Put options in init.lua with their defaults, under a heading for
-- lulibre's own and one for each script's namespace: commented out, or set,
-- as the option config_add_as says. items: { {name=} or {ns=, name=}, ... }.
-- Returns how many were put in.
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

--- Write a value for an option into init.lua: the line that names it is
-- made to set it (uncommented), or one is added. value == nil puts it back
-- to its default: the line is commented out, with the default.
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
