--- Loaded once per lua_State, before init.lua (design 12, 46).
-- Registers the packaged grammar and commands, and uiman.list and
-- uiman.form. init.lua then runs as the first task; a set call there is a
-- live change like any other, under the command line's value.
--
-- @library lulib._prelude
require "exprman._front"
require "exprman._pages"
require "cmd"
require "lulib._uiman"
require "units"
require "lulib._config"
-- once init.lua has started: lulibre's systemd units as the settings say,
-- in the interface only (lulib.headless is known by then)
taskman.spawn(function()
  if not lulib.headless then require("units").on_start() end
end)
