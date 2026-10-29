-- Writes lulibre's settings into lua/config/options.lua in the
-- configuration folder, for setup/install.sh, which runs it as
--
--   lulibre --clean run setup/options.lua FILE DEFAULT_INIT
--
-- FILE holds lines `name=value`; an empty value takes the setting's line
-- out, so it goes back to lulibre's default. Every value is checked first:
-- one refused, nothing is written. A line of the file that sets one of
-- these settings is replaced, the rest kept; options.lua.bak keeps the file
-- as it was. Where there is no init.lua, DEFAULT_INIT is written there with
-- its `require "config.options"` taken out of its comment.
local file, default_init = ...
if not (file and default_init) then
  error("usage: lulibre --clean run setup/options.lua FILE DEFAULT_INIT", 0)
end

local function read(path)
  local f = io.open(path)
  if not f then return nil end
  local s = f:read("a")
  f:close()
  return s
end

local function write(path, text)
  local f = assert(io.open(path .. ".new", "w"))
  f:write(text)
  f:close()
  assert(os.rename(path .. ".new", path))
end

-- checked through setman.set: lulibre runs this with --clean, and a set
-- here is gone when it ends
local items, refused = {}, {}
for line in io.lines(file) do
  local name, value = line:match("^([%w_.]+)=(.*)$")
  if name then
    local ok, err = true, nil
    if value ~= "" then ok, err = pcall(setman.set, name, value) end
    if ok then
      local got = value ~= "" and setman.get(name)
      items[#items + 1] = { name = name, text = value, literal = type(got) == "string" and ("%q"):format(value)
        or tostring(got) }
    else
      refused[#refused + 1] = tostring(err):gsub("^.-:%d+: ", "")
    end
  end
end
if #refused > 0 then error("nothing written: " .. table.concat(refused, "; "), 0) end

local cfg = setman.get("path.config")
local dir = cfg .. "/lua/config"
local path = dir .. "/options.lua"
os.execute(("mkdir -p '%s'"):format(dir:gsub("'", "'\\''")))

local before = read(path)
local text = before or "-- lulibre's settings, written by lulibre-setup; init.lua loads them with\n"
  .. "-- `require \"config.options\"`\nlocal _ENV = setman.settings\n"
-- a file of setman.set lines, without setman.settings as its environment
local plain = before and not before:find("_ENV%s*=%s*setman%.settings")

local function pattern(name)
  local quoted = name:gsub("%p", "%%%0")
  if plain then return "^%s*setman%.set%(%s*[\"']" .. quoted .. "[\"']" end
  return "^%s*" .. quoted .. "%s*="
end

local lines = {}
for line in (text:sub(-1) == "\n" and text or text .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
for _, it in ipairs(items) do
  local new = it.text ~= "" and (plain and ("setman.set(%q, %s)"):format(it.name, it.literal)
    or ("%s = %s"):format(it.name, it.literal))
  local found
  for i = #lines, 1, -1 do
    if lines[i]:find(pattern(it.name)) then
      if new and not found then lines[i] = new else table.remove(lines, i) end
      found = true
    end
  end
  if new and not found then lines[#lines + 1] = new end
  print(("  %s = %s"):format(it.name, new and it.literal or "(lulibre's default)"))
end
if before then write(path .. ".bak", before) end
write(path, table.concat(lines, "\n") .. "\n")
print("  written: " .. path)
if before then print("  the file before setup: " .. path .. ".bak") end

local init = cfg .. "/init.lua"
local had = read(init)
if not had then
  local default = assert(read(default_init))
  local line = default:match("\n%-%-%s*(require%s*\"config%.options\")")
  write(init, line .. "\n")
  print("  written: " .. init)
elseif not had:gsub("%-%-%[%[.-%]%]", ""):gsub("%-%-[^\n]*", ""):find("require%s*%(?%s*[\"']config%.options[\"']") then
  print(("  %s does not load these: lulibre reads them once it has `require \"config.options\"`"):format(init))
end
