--- The internal functions of a packaged module, in its table or not as
-- the setting expose_modules says, asked each time (so the setting may be
-- changed from the command line, options.lua or :set alike).
--
--     local own, get = require "lulib._expose" (M)
--     function own.once(book) ... end      -- internal
--     get("once")(book)                    -- M.once when exposed (yours,
--                                          -- if you redefined it), else own.once
--
-- With expose_modules on, reading M.once gives own.once unless you have
-- put a function of your own there; with it off, M has none of them and
-- the module calls its own whatever M holds.
--
-- @library lulib._expose
return function(M)
  local own = {}
  setmetatable(M, { __index = function(_, k) if setman.get("expose_modules") then return own[k] end end })
  local function get(name)
    if setman.get("expose_modules") then return M[name] end
    return own[name]
  end
  return own, get
end
