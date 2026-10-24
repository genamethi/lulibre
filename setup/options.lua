-- Sets lulibre's options in init.lua, for setup/install.sh. The argument is
-- a file of lines `name=value`; an empty value puts the option back to its
-- default. Every value is checked before anything is written, and
-- init.lua.bak keeps the file as it was before this run; with "new" after
-- the file (init.lua was written by setup just before), no copy is kept.
local cf = require "lulibre.config_file"

local file, new = ...
if not file then error("usage: lulibre run setup/options.lua FILE [new]", 0) end

local items = {}
for line in io.lines(file) do
  local name, value = line:match("^([%w_]+)=(.*)$")
  if name then items[#items + 1] = { name = name, text = value } end
end

local function convert(name, s)
  if s == "" then return nil end
  local kind = lulibre.settings.info(name).type
  if kind == "number" then
    local n = math.tointeger(tonumber(s))
    if not n then error(("%s takes a whole number, not %q"):format(name, s), 0) end
    return n
  elseif kind == "boolean" then
    if s == "true" then return true elseif s == "false" then return false end
    error(("%s is true or false, not %q"):format(name, s), 0)
  end
  return s
end

for _, it in ipairs(items) do
  it.value = convert(it.name, it.text)
  local ok, err = pcall(function() lulibre.o[it.name] = it.value end)
  if not ok then error(("%s: %s"):format(it.name, tostring(err):gsub("^.-:%d+: ", "")), 0) end
end

local before = cf.read()
for _, it in ipairs(items) do
  cf.write_value({ name = it.name }, it.value)
  local shown = it.value == nil and "(lulibre's default)" or type(it.value) == "string" and ("%q"):format(it.value)
    or tostring(it.value)
  print(("  %s = %s"):format(it.name, shown))
end
if new == "new" then
  os.remove(cf.path() .. ".bak")
elseif before then
  local f = assert(io.open(cf.path() .. ".bak", "w"))
  f:write(before)
  f:close()
  print("  the file before setup: " .. cf.path() .. ".bak")
end
