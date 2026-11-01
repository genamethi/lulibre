-- Writes the settings setup chose into lua/config/options.lua, and has
-- init.lua load them (lulib._options), for setup/install.sh, which runs it as
--
--   lulibre --clean run setup/options.lua FILE
--
-- FILE holds lines `name=value`; an empty value takes the setting's line
-- out, so it goes back to lulibre's default. Every value is checked first:
-- one refused, nothing is written.
local file = ...
if not file then error("usage: lulibre --clean run setup/options.lua FILE", 0) end

local options = require "lulib._options"

-- checked through setman.set: lulibre runs this with --clean, and a set
-- here is gone when it ends
local items, refused = {}, {}
for line in io.lines(file) do
  local name, value = line:match("^([%w_.]+)=(.*)$")
  if name then
    local ok, err = true, nil
    if value ~= "" then ok, err = pcall(setman.set, name, value) end
    if ok then
      items[#items + 1] = { name = name, value = value ~= "" and setman.get(name) or nil }
    else
      refused[#refused + 1] = tostring(err):gsub("^.-:%d+: ", "")
    end
  end
end
if #refused > 0 then error("nothing written: " .. table.concat(refused, "; "), 0) end

local path, had = options.write(items)
for _, it in ipairs(items) do
  print(("  %s = %s"):format(it.name, it.value ~= nil and tostring(it.value) or "(lulibre's default)"))
end
print("  written: " .. path)
if had then print("  the file before setup: " .. path .. ".bak") end

local done = options.link()
if done == "created" then
  print("  written: " .. options.init_path())
elseif done == "added" then
  print(('  %s now loads them (`require "config.options"`); the file before: %s.bak'):format(options.init_path(), options.init_path()))
end
