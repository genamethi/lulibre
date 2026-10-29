--- :lua CODE runs a line of Lua as a task and shows what it returns, a
-- table written out as Lua.
-- @library lulibre.eval
local pretty = require "pl.pretty"

local M = {}

--- Runs the line: as an expression if it is one, else as statements.
function M.run(line)
  local f, err = load("return " .. line, "=:lua")
  if not f then f, err = load(line, "=:lua") end
  if not f then
    uiman.notify(err, "error")
    return
  end
  local r = table.pack(f())
  if r.n == 0 then return end
  local out = {}
  for i = 1, r.n do out[i] = pretty.write(r[i], "") end
  uiman.notify(table.concat(out, "\t"))
end

return M
