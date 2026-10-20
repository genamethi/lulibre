-- lulibre's systemd units around calibre's content server, as the options
-- server_hook, opf_writer and server_restart_at ask (lulibre.units):
--   lulibre units          what would change, and why not where it cannot
--   lulibre units apply    make it: a user unit's files directly; a system
--                          unit's with sudo, after asking
--   :units [apply]         the same, in the interface
local units = require "lulibre.units"

local what = (...) or ""

local function say(lines)
  if lulibre.headless then
    for _, l in ipairs(lines) do print(l) end
  else
    lulibre.show(lines, "calibre's server and lulibre's systemd units")
  end
end

local function confirm(question)
  if lulibre.headless then
    io.write(question .. " [y/N] ")
    io.flush()
    return (io.read("l") or ""):lower():match("^y") ~= nil
  end
  return lulibre.confirm(question)
end

if what == "" or what == "show" then
  say(units.describe(units.plan()))
elseif what == "apply" then
  local p = units.plan()
  if p.server and not p.why and #p.changes == 0 then return say(units.describe(p)) end
  say(units.apply(p, confirm))
else
  error("units [apply]", 0)
end
