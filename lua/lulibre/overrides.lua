--- Finds your own modules and scripts that replace lulibre's, and warns
-- about them.
-- lulibre looks for your files first (~/.config/lulibre/lua/ and scripts/),
-- so you can replace any part of lulibre that is written in Lua. But a
-- changed copy of one of lulibre's files stays in use after an update fixes
-- lulibre's own file. So at start, lulibre lists each replacing file in the
-- console once, and again whenever lulibre's own file has changed since.
--
-- @setup lulibre.overrides
-- @usage
-- local overrides = require "lulibre.overrides"
-- overrides.find()   -- { {kind="module"|"script", name=, yours=, bundled=, stamp=}, ... }
-- overrides.warn()   -- say so of those not said of yet (lulibre does at each start); returns them
local M = {}

local uv = require "luv"
local json = require "lulibre.json"

-- the .lua files under dir, as paths relative to it
local function walk(dir, rel, out)
  local h = uv.fs_scandir(rel == "" and dir or dir .. "/" .. rel)
  if not h then return out end
  while true do
    local name, kind = uv.fs_scandir_next(h)
    if not name then break end
    local r = rel == "" and name or rel .. "/" .. name
    if kind ~= "file" and kind ~= "directory" then -- a link, say
      local st = uv.fs_stat(dir .. "/" .. r)
      kind = st and st.type
    end
    if kind == "directory" then walk(dir, r, out)
    elseif kind == "file" and name:match("%.lua$") then out[#out + 1] = r end
  end
  return out
end

local function read(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("a")
  f:close()
  return s
end

-- what lulibre's file holds, in a number (FNV-1a): it changes with the
-- file's contents, not with its time (make install gives every file a new one)
local function digest(path)
  local s, h = read(path) or "", 2166136261
  for i = 1, #s do h = ((h ~ s:byte(i)) * 16777619) & 0xffffffff end
  return ("%d:%08x"):format(#s, h)
end

--- Returns your files that replace lulibre's own, sorted by path.
-- @treturn {table,...} `{ kind=, name=, yours=, bundled=, stamp= }`
function M.find()
  local p = lulibre.settings.paths()
  local bundled = p.bundled or {}
  local out = {}
  if p.modules and bundled.modules then
    -- a module "a.b" is a/b.lua or a/b/init.lua, in either place
    for _, rel in ipairs(walk(p.modules, "", {})) do
      local base = rel:gsub("%.lua$", ""):gsub("/init$", "")
      for _, form in ipairs { base .. ".lua", base .. "/init.lua" } do
        if uv.fs_stat(bundled.modules .. "/" .. form) then
          out[#out + 1] = { kind = "module", name = base:gsub("/", "."), yours = p.modules .. "/" .. rel,
            bundled = bundled.modules .. "/" .. form }
          break
        end
      end
    end
  end
  if p.scripts and bundled.scripts then
    for _, rel in ipairs(walk(p.scripts, "", {})) do
      if uv.fs_stat(bundled.scripts .. "/" .. rel) then
        out[#out + 1] = { kind = "script", name = rel:gsub("%.lua$", ""), yours = p.scripts .. "/" .. rel,
          bundled = bundled.scripts .. "/" .. rel }
      end
    end
  end
  for _, o in ipairs(out) do o.stamp = digest(o.bundled) end
  table.sort(out, function(a, b) return a.yours < b.yours end)
  return out
end

local function seen_path()
  return lulibre.settings.paths().data_dir .. "/overrides.json"
end

--- Lists in the console your files that replace lulibre's own: the files
-- not listed before, and the files whose lulibre counterpart has changed
-- since. A replaceable function.
-- @treturn {table,...} the files listed
function M.warn()
  local found = M.find()
  local ok, seen = pcall(json.decode, read(seen_path()) or "{}")
  if not ok or type(seen) ~= "table" then seen = {} end
  local now, new, changed = {}, {}, false
  for _, o in ipairs(found) do
    now[o.yours] = o.stamp
    if seen[o.yours] ~= o.stamp then
      new[#new + 1] = o
      -- what to do first, the paths last: the console cuts a line at its width
      lulibre.log(("your %s %s is used in place of lulibre's own%s, and may lack its fixes: remove or rename "
        .. "yours to use lulibre's (yours: %s; lulibre's: %s; said again only when lulibre's changes)")
        :format(o.kind, o.name, seen[o.yours] and ", which has changed since" or "", o.yours, o.bundled), "warn")
    end
  end
  for k in pairs(seen) do changed = changed or now[k] == nil end
  if #new > 0 or changed then
    uv.fs_mkdir(lulibre.settings.paths().data_dir, 448) -- 0700; there already, most often
    local f = io.open(seen_path(), "w")
    if f then
      f:write(json.encode(now))
      f:close()
    end
  end
  return new
end

return M
