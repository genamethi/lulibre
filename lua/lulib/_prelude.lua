--- Loaded once per lua_State, before init.lua (design 12, 46).
-- Registers the packaged grammar and commands. init.lua then runs as the
-- first task; a set call there is a live change like any other.
require "exprman._front"
require "cmd"
