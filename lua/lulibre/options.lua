-- Options of scripts and modules, each under a name of its own (a
-- namespace), beside lulibre's own (lulibre.o).
--
-- A script declares its options when it starts, with defaults and, if it
-- likes, help:
--   local opt = lulibre.option("mytags", {
--     depth = { default = 2, type = "number", help = "how many levels of subject to keep" },
--     style = { default = "short", choices = "short|long" },   -- no help: no comment is written for it
--   })
--   print(opt.depth)
-- init.lua sets them by the same names, before or after the script has
-- declared them:
--   lulibre.cfg.mytags.depth = 3
-- What init.lua sets wins over what a script sets (unless the script says
-- force), and what is set in the session (the config window, :lua) wins
-- over both, until lulibre closes.
--
--   local options = require "lulibre.options"
--   options.declare(ns, name, spec) / options.declare(ns, { name = spec, ... })
--   options.get(ns, name)  options.set(ns, name, value, how)   -- how: "file" | "script" | "session"
--   options.reset(ns, name)                 -- forget the session's value
--   options.namespaces()                    -- in the order they were declared
--   options.list(ns)                        -- { {name=, value=, default=, from=, spec=}, ... }
local M = {}

local specs, order = {}, {}         -- ns -> name -> spec; ns order
local file, script, session = {}, {}, {}

local function slot(t, ns)
  t[ns] = t[ns] or {}
  return t[ns]
end

local function choices_of(spec)
  if type(spec.choices) == "string" then
    local list = {}
    for c in spec.choices:gmatch("[^|]+") do list[#list + 1] = c end
    return list
  end
  return spec.choices
end

--- A value made to fit an option, or nil and why it does not.
function M.check(spec, v)
  if v == nil then return nil, "no value" end
  local t = spec.type or type(spec.default)
  if t == "number" then
    local n = tonumber(v)
    if not n then return nil, ("a number, not %s"):format(tostring(v)) end
    v = n
  elseif t == "boolean" then
    if v == "on" or v == "true" or v == "yes" or v == 1 then v = true
    elseif v == "off" or v == "false" or v == "no" or v == 0 then v = false end
    if type(v) ~= "boolean" then return nil, ("on or off, not %s"):format(tostring(v)) end
  else
    v = tostring(v)
  end
  local choices = choices_of(spec)
  if choices then
    local ok = false
    for _, c in ipairs(choices) do
      if tostring(c) == tostring(v) then ok = true end
    end
    if not ok then return nil, ("one of %s, not %s"):format(table.concat(choices, " | "), tostring(v)) end
  end
  return v
end

--- Declare an option (or a table of them) under a namespace.
function M.declare(ns, name, spec)
  if type(name) == "table" then
    local names = {}
    for n in pairs(name) do names[#names + 1] = n end
    table.sort(names)
    for _, n in ipairs(names) do M.declare(ns, n, name[n]) end
    return
  end
  assert(type(ns) == "string" and ns:match("^[%a_][%w_]*$"), "a namespace is a name: letters, figures and _")
  assert(type(name) == "string" and name:match("^[%a_][%w_]*$"), "an option's name is letters, figures and _")
  assert(type(spec) == "table" and spec.default ~= nil, "an option needs a default")
  if not specs[ns] then
    specs[ns] = {}
    order[#order + 1] = ns
  end
  local s = {}
  for k, v in pairs(spec) do s[k] = v end
  s.choices = choices_of(spec)
  s.type = spec.type or type(spec.default)
  specs[ns][name] = s
  -- a value init.lua gave before the option was declared is checked now
  local given = (file[ns] or {})[name]
  if given ~= nil and not M.check(s, given) then
    lulibre.log(("init.lua sets %s.%s to %s, which it does not take: the default holds"):format(ns, name, tostring(given)), "warn")
    file[ns][name] = nil
  end
end

function M.spec(ns, name)
  return specs[ns] and specs[ns][name]
end

local function pick(ns, name)
  for _, t in ipairs { session, file, script } do
    local v = t[ns] and t[ns][name]
    if v ~= nil then return v end
  end
  local s = M.spec(ns, name)
  return s and s.default
end

function M.get(ns, name)
  return pick(ns, name)
end

--- Where an option's value comes from: "session", "file", "script" or "default".
function M.from(ns, name)
  if session[ns] and session[ns][name] ~= nil then return "session" end
  if file[ns] and file[ns][name] ~= nil then return "file" end
  if script[ns] and script[ns][name] ~= nil then return "script" end
  return "default"
end

--- Set an option. how: "file" (what init.lua says), "script" (a script's
-- own say, beneath init.lua's unless opts.force) or "session".
function M.set(ns, name, value, how, opts)
  local s = M.spec(ns, name)
  if value == nil then
    -- nil takes this source's value away: the next one down holds (init.lua's,
    -- the script's, the default)
    how = how or "session"
    if how == "script" and opts and opts.force then how = "session" end
    local t = how == "file" and file or how == "script" and script or session
    if t[ns] then t[ns][name] = nil end
    return
  end
  if s then
    local v, why = M.check(s, value)
    if v == nil then error(("%s.%s takes %s"):format(ns, name, why), 3) end
    value = v
  end
  how = how or "session"
  if how == "script" and opts and opts.force then how = "session" end
  local t = how == "file" and file or how == "script" and script or session
  slot(t, ns)[name] = value
end

function M.reset(ns, name)
  if session[ns] then session[ns][name] = nil end
end

--- Forget what init.lua said (it is about to be read again).
function M.forget_file()
  file = {}
end

function M.namespaces()
  local out = {}
  for _, ns in ipairs(order) do out[#out + 1] = ns end
  -- names init.lua set that no script has declared yet
  for ns in pairs(file) do
    if not specs[ns] then out[#out + 1] = ns end
  end
  return out
end

function M.list(ns)
  local names = {}
  for n in pairs(specs[ns] or {}) do names[#names + 1] = n end
  for n in pairs(file[ns] or {}) do
    if not (specs[ns] or {})[n] then names[#names + 1] = n end
  end
  table.sort(names)
  local out = {}
  for _, n in ipairs(names) do
    local s = M.spec(ns, n)
    out[#out + 1] = { name = n, value = M.get(ns, n), default = s and s.default, from = M.from(ns, n), spec = s }
  end
  return out
end

-- Who is setting a value: init.lua and the modules beside it (the
-- configuration directory, but not its scripts/) speak for the file;
-- other code for a script; what was typed (:lua) for the session.
local function caller_kind(level)
  local info = debug.getinfo(level, "S")
  local src = info and info.source or ""
  if src:sub(1, 1) ~= "@" then return "session" end
  local path = src:sub(2)
  local paths = lulibre.settings.paths()
  local dir = (paths.config_dir or ""):gsub("/+$", "")
  if dir ~= "" and path:sub(1, #dir + 1) == dir .. "/" and not path:find("^" .. dir:gsub("%p", "%%%0") .. "/scripts/") then
    return "file"
  end
  return "script"
end

--- lulibre.cfg.<ns>.<name>: read an option, or set it (as init.lua, a
-- script or the session, by where the line that sets it is).
local proxies = {}
M.cfg = setmetatable({}, {
  __index = function(_, ns)
    if not proxies[ns] then
      proxies[ns] = setmetatable({}, {
        __index = function(_, name) return M.get(ns, name) end,
        __newindex = function(_, name, value) M.set(ns, name, value, caller_kind(3)) end,
        __pairs = function()
          local list, i = M.list(ns), 0
          return function()
            i = i + 1
            if list[i] then return list[i].name, list[i].value end
          end
        end,
      })
    end
    return proxies[ns]
  end,
  __newindex = function() error("set an option as lulibre.cfg.NAMESPACE.OPTION = value", 2) end,
})

--- lulibre.option(ns, { name = spec, ... }): declare, and get the namespace
-- to read the values from.
function M.option(ns, defs)
  if defs then M.declare(ns, defs) end
  return M.cfg[ns]
end

return M
