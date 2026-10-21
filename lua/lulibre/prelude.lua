--- Defines the functions of the `lulibre` table that are written in Lua.
-- The other functions of `lulibre` are written in C (src/lua/l_*.c), and
-- the Lua API page lists both kinds. lulibre loads this file once at
-- startup, together with the commands written in Lua (lulibre/commands/).
--
-- @scripting lulibre
-- @usage
-- lulibre.each(lulibre.ids("no:ids"), function(id) ... end, { progress = "looking" })
-- if lulibre.confirm("remove 3 books?") then ... end
-- lulibre.propose(12, "title", "Knot Theory", { source = "my script", confidence = 0.7 })
-- print(lulibre.inspect(lulibre.book(12)))

--- Returns any value as readable text, for :lua and for debugging.
-- @param v any value
-- @tparam[opt] string indent
-- @tparam[opt] table seen the tables already shown, so a table that contains itself is shown once
-- @treturn string
function lulibre.inspect(v, indent, seen)
  indent, seen = indent or "", seen or {}
  if type(v) == "string" then return string.format("%q", v) end
  if type(v) ~= "table" then return tostring(v) end
  if seen[v] then return "<cycle>" end
  seen[v] = true
  local keys = {}
  for k in pairs(v) do keys[#keys + 1] = k end
  if #keys == 0 then return "{}" end
  table.sort(keys, function(a, b)
    if type(a) == type(b) and (type(a) == "number" or type(a) == "string") then return a < b end
    return type(a) == "number" or (type(b) ~= "number" and tostring(a) < tostring(b))
  end)
  local inner, parts = indent .. "  ", {}
  local list = #keys == #v -- a plain sequence prints without its indexes
  for _, k in ipairs(keys) do
    local key = list and "" or (type(k) == "string" and k:match("^[%a_][%w_]*$") and k
      or "[" .. lulibre.inspect(k, inner, seen) .. "]") .. " = "
    parts[#parts + 1] = inner .. key .. lulibre.inspect(v[k], inner, seen)
  end
  seen[v] = nil
  local flat = table.concat(parts, ","):gsub("%s+", " ")
  if #flat < 72 and not flat:find("\n") then return "{" .. flat .. " }" end
  return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
end
--- Runs the code typed after :lua. The code is evaluated as an expression
-- if possible, and otherwise run as statements.
-- @local
function lulibre._eval(code)
  local f, err = load("return " .. code, "=:lua")
  if not f then f, err = load(code, "=:lua") end
  if not f then error(err, 0) end
  local r = table.pack(f())
  if r.n == 0 then return end
  local out = {}
  for i = 1, r.n do out[i] = lulibre.inspect(r[i]) end
  local text = table.concat(out, "\n")
  if text:find("\n") and not lulibre.headless then lulibre.show(text, ":lua " .. code)
  else print(text) end
end
--- Asks a yes/no question on the bottom line and waits for the answer.
-- Returns true only for y or yes.
-- @tparam string question "[y/N]" is added to it
-- @treturn boolean
function lulibre.confirm(question)
  local a = lulibre.input({ prompt = question .. " [y/N] " })
  return a ~= nil and (a:lower() == "y" or a:lower() == "yes")
end
--- Returns true if lulibre should do something it may do on its own.
-- The option named `name` decides: "auto" returns true and "never" returns
-- false. "ask" asks the question, and returns false if nobody can be asked.
-- @tparam string name the option, set to "auto", "ask" or "never"
-- @tparam string question
-- @treturn boolean
function lulibre.policy(name, question)
  local v = lulibre.o[name]
  if v == "auto" then return true end
  if v == "ask" and not lulibre.headless and lulibre.task_id() then return lulibre.confirm(question) end
  return false
end
--- Sets several options at once: lulibre.setup{ pages = 8, ocr = "auto" }.
-- @tparam table opts `{ name = value, ... }`
function lulibre.setup(opts)
  for k, v in pairs(opts) do lulibre.o[k] = v end
end
--- Runs fn(item, index) for each item of a list, several at once, and waits
-- for all of them. `opts.jobs` is how many run at a time (one per CPU by
-- default). `opts.progress` is a word for the status line: "hashing" shows
-- "hashing 12/300". An error in fn stops the remaining items and is raised
-- here.
--
-- The tasks take turns, and a turn can end between any two Lua operations.
-- So fn must not count in a shared variable: `n = n + 1` can lose a count.
-- Store results on the item, or use table.insert, which cannot be
-- interrupted.
-- @tparam table items
-- @tparam function fn `fn(item, index)`
-- @tparam[opt] table opts `jobs`, `progress`
function lulibre.each(items, fn, opts)
  opts = opts or {}
  local total = #items
  if total == 0 then return end
  local jobs = opts.jobs
  if not jobs then
    local ok, uv = pcall(require, "luv")
    jobs = ok and uv.available_parallelism and uv.available_parallelism() or 4
  end
  jobs = math.max(1, math.min(jobs, total))
  local queue, done, finished, errors = {}, {}, {}, {}
  for i = total, 1, -1 do queue[#queue + 1] = i end
  local function worker()
    local ok, err = pcall(function()
      while #errors == 0 do
        local i = table.remove(queue)
        if not i then break end
        fn(items[i], i)
        table.insert(done, true)
        if opts.progress then lulibre.progress(("%s %d/%d"):format(opts.progress, #done, total)) end
      end
    end)
    if not ok then table.insert(errors, err) end
    table.insert(finished, true)
  end
  if opts.progress then lulibre.progress(("%s 0/%d"):format(opts.progress, total)) end
  for _ = 1, jobs do lulibre.spawn(worker) end
  while #finished < jobs do lulibre.sleep(10) end
  if opts.progress then lulibre.progress(nil) end
  if errors[1] then error(errors[1], 0) end
end
--- Returns the key a command is bound to now, or ":command" if it has no
-- key. Messages that name a key use this function.
-- @tparam string command
-- @treturn string
function lulibre.hint(command)
  return lulibre.key(command) or (":" .. command)
end

-- Keys. lulibre.map binds a global key; given the name of a screen written
-- in Lua instead of modes, it puts a key on one of that screen's actions:
--   lulibre.map("nv", "gx", "run mine")       a command line or a function
--   lulibre.map("review", "y", "accept")      see lulibre.ui.keys
do
  local map = lulibre.map
  function lulibre.map(modes, key, target, help)
    local screens = require "lulibre.ui.keys"
    if type(modes) == "string" and screens.has(modes) then return screens.set(modes, key, target) end
    -- or of a place with keys of its own: "panel", "line", "picker", "pager", "console"
    if type(modes) == "string" and #modes > 2 and lulibre._place_map(modes, key, target or "") then return end
    return map(modes, key, target, help)
  end
end
--- Proposes a change for later review. See lulibre.proposals.
-- @tparam integer id
-- @tparam string field
-- @tparam string value
-- @tparam[opt] table opts as `lulibre.proposals.add` takes them
-- @return what `lulibre.proposals.add` returns
function lulibre.propose(id, field, value, opts)
  return require("lulibre.proposals").add(id, field, value, opts)
end
--- Applies changes now and waits for them to finish:
-- lulibre.apply{ {id=, field=, value=, op=}, ... }.
-- @tparam {table,...} changes
-- @tparam[opt] table opts as `lulibre.edit.apply` takes them
-- @treturn table its result
function lulibre.apply(changes, opts)
  return require("lulibre.edit").apply(changes, opts)
end
--- Returns a title in title case (APA style). See lulibre.titlecase.
-- @tparam string s
-- @treturn string
function lulibre.titlecase(s)
  return require("lulibre.titlecase").apply(s)
end
-- ---- options of scripts, and the configuration file ----

--- Declares a script's options and returns the namespace to read them from:
-- lulibre.option(namespace, { name = { default=, type=, choices=, help= }, ... }).
-- See lulibre.options.
-- @tparam string ns
-- @tparam[opt] table defs
-- @treturn table
function lulibre.option(ns, defs)
  return require("lulibre.options").option(ns, defs)
end
--- A script's options, read and set as lulibre.cfg.<namespace>.<name>.
-- In init.lua, for example: lulibre.cfg.mytags.depth = 3.
lulibre.cfg = require("lulibre.options").cfg
-- C modules. One built for another Lua (compiled against another version's
-- lua.h, which a stray header earlier on the include path makes easy) can
-- crash the program the moment it is loaded, with nothing to say why. So
-- each is loaded first in a child process (this program, `run` on a probe),
-- once for each file and its date, and one that does not survive that is
-- refused with the reason. The answers are kept in cmodules.cache in the data
-- folder.
local probe_cache
local function cache_file() return lulibre.settings.paths().data_dir .. "/cmodules.cache" end
local function load_cache()
  if probe_cache then return probe_cache end
  local cache = {} -- built whole, then put in place (a task may be interrupted)
  local f = io.open(cache_file(), "r")
  if f then
    for line in f:lines() do
      local verdict, stamp, path = line:match("^(%a+) (%d+) (.+)$")
      if path then cache[path] = { verdict = verdict, stamp = stamp } end
    end
    f:close()
  end
  probe_cache = cache
  return cache
end
local function shq(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
local function c_module_ok(name, file)
  if name == "luv" then return true end -- lulibre's own, checked when it is built
  local ok, uv = pcall(require, "luv")
  if not ok then return true end -- cannot tell; load it as Lua would
  local st = uv.fs_stat(file)
  local stamp = tostring(st and st.mtime and st.mtime.sec or 0)
  local cache = load_cache()
  local known = cache[file]
  if known and known.stamp == stamp then return known.verdict == "ok" end
  local dir = lulibre.settings.paths().data_dir
  local probe = dir .. "/cprobe.lua"
  if not uv.fs_stat(probe) then
    os.execute("mkdir -p " .. shq(dir))
    local f = io.open(probe, "w")
    if f then
      f:write('local name, path = ...\nlocal open = assert(package.loadlib(path, "luaopen_" .. name:gsub("%.", "_")))\nopen(name, path)\n')
      f:close()
    end
  end
  local exe = uv.exepath()
  local good = exe and os.execute(("%s --clean run %s %s %s >/dev/null 2>&1"):format(shq(exe), shq(probe), shq(name), shq(file))) == true
  cache[file] = { verdict = good and "ok" or "bad", stamp = stamp }
  local f = io.open(cache_file(), "a")
  if f then
    f:write(("%s %s %s\n"):format(good and "ok" or "bad", stamp, file))
    f:close()
  end
  return good
end
local function refused(name, file)
  return ("\n\tthe C module %s at %s crashes when it is loaded: it was built for another Lua than this %s"
    .. " (rebuild it against this version's headers; `luarocks install` takes LUA_INCDIR=...)"):format(name, file, _VERSION)
end
-- the C searchers (a module's own file, and the one its root is in) go through the probe
local std_c, std_croot = package.searchers[3], package.searchers[4]
package.searchers[3] = function(name)
  local file = package.searchpath(name, package.cpath)
  if file and not c_module_ok(name, file) then return refused(name, file) end
  return std_c(name)
end
package.searchers[4] = function(name)
  local root = name:match("^([^%.]+)%.")
  local file = root and package.searchpath(root, package.cpath)
  if file and not c_module_ok(name, file) then return refused(name, file) end
  return std_croot(name)
end
-- Modules of a luarocks tree (the option rocks_tree): looked for before the
-- usual places, since it is the tree you named.
local function rocks_paths(tree)
  local v = _VERSION:match("%d+%.%d+")
  return ("%s/share/lua/%s/?.lua;%s/share/lua/%s/?/init.lua"):format(tree, v, tree, v), ("%s/lib/lua/%s/?.so"):format(tree, v)
end
table.insert(package.searchers, 2, function(name)
  local tree = lulibre.o.rocks_tree or ""
  if tree == "" then return nil end
  local lpath, cpath = rocks_paths(tree)
  local file = package.searchpath(name, lpath)
  if file then return loadfile(file), file end
  file = package.searchpath(name, cpath)
  if file then
    if not c_module_ok(name, file) then return refused(name, file) end
    local sym = "luaopen_" .. name:gsub("%.", "_")
    local f, err = package.loadlib(file, sym)
    if not f then return err end
    return f, file
  end
  return ("\n\tno module '%s' in the luarocks tree %s"):format(name, tree)
end)
--- Requires a module. If the module is missing, offers to install its rock
-- into `rocks_tree`. The offer is made only if `rocks_install` is true and
-- someone can be asked.
-- @tparam string module
-- @tparam[opt] string rock the rock's name, if it differs from the module's
-- @return the module
-- @raise if the module is missing and is not installed
function lulibre.require_rock(module, rock)
  local ok, m = pcall(require, module)
  if ok then return m end
  local tree = lulibre.o.rocks_tree or ""
  if not lulibre.o.rocks_install or tree == "" then
    error(("the Lua module %s is not installed (luarocks install %s%s)"):format(module, rock or module,
      tree ~= "" and (" --tree " .. tree) or ""), 2)
  end
  if lulibre.headless or not lulibre.task_id() or
      not lulibre.confirm(("install the rock %s into %s? luarocks fetches it from luarocks.org"):format(rock or module, tree)) then
    error(("the Lua module %s is not installed"):format(module), 2)
  end
  lulibre.progress("luarocks: " .. (rock or module))
  local r, err = lulibre.system({ "luarocks", "--lua-version", _VERSION:match("%d+%.%d+"), "--tree", tree, "install", rock or module },
    { timeout = 900000 })
  lulibre.progress(nil)
  if not r or r.code ~= 0 then error("luarocks could not install " .. (rock or module) .. ": " .. tostring(err or (r and r.stderr)), 2) end
  return require(module)
end
-- around init.lua (read at start, and again by :reload-cfg)
function lulibre._before_init()
  require("lulibre.options").forget_file()
end
function lulibre._after_init()
  -- options nobody has put in init.lua yet go in on their own when the options say "auto"
  local add_core, add_scripts = lulibre.o.config_add_core == "auto", lulibre.o.config_add_scripts == "auto"
  if (add_core or add_scripts) and lulibre.settings.paths().init then
    local cf = require "lulibre.config_file"
    local ok, missing = pcall(cf.missing)
    if ok then
      local items = {}
      if add_core then for _, n in ipairs(missing.core) do items[#items + 1] = { name = n } end end
      if add_scripts then for _, it in ipairs(missing.scripts) do items[#items + 1] = it end end
      if #items > 0 then pcall(cf.add, items) end
    end
  end
  -- lulibre's systemd units, as server_hook, opf_writer and server_restart_at
  -- ask (lulibre.units): a user unit's are made now, in the interface only
  if not lulibre.headless then lulibre.spawn(function() pcall(require("lulibre.units").on_start) end) end
  -- your files used in place of lulibre's own: said in the console, and
  -- pointed to on the message line in the interface (lulibre.overrides)
  lulibre.spawn(function()
    local ok, new = pcall(require("lulibre.overrides").warn)
    if not ok then return lulibre.log("checking for files of yours used in place of lulibre's: " .. tostring(new), "warn") end
    if #new > 0 and not lulibre.headless then
      lulibre.notify(#new == 1 and "1 file of yours is used in place of lulibre's own: the console (`) says which"
        or ("%d files of yours are used in place of lulibre's own: the console (`) says which"):format(#new))
    end
  end)
end
-- each command's function by its name, as it is defined, for :new
do
  local command, fns = lulibre.command, {}
  function lulibre.command(name, fn, help)
    fns[name] = fn
    return command(name, fn, help)
  end
  lulibre.command("new", function(args)
    local name, rest = (args or ""):match("^%s*(%S+)%s*(.-)%s*$")
    local fn = name and fns[name]
    if not fn then error(name and ("no command " .. name .. " to open another of") or "new: which command? (:new review)", 0) end
    require("lulibre.ui.panels").again(fn, rest ~= "" and rest or nil)
  end, "command [args]  run a command that opens a screen, as another one when that screen is open already")
end
-- the commands (lulibre/commands/*.lua)
require "lulibre.commands.screens"
require "lulibre.commands.library"
require "lulibre.commands.scripts"

-- backup_restart's "next" is spent until it is set to next again: note the
-- value lulibre starts with (lulibre.backup), once the library is open
-- (only with a library to open: looking would otherwise end lulibre. Asked
-- in the task, once -L and init.lua have had their say)
lulibre.spawn(function()
  local here = io.open("metadata.db")
  if here then here:close() end
  if lulibre.o.library ~= "" or os.getenv("LULIBRE_LIBRARY") or here then pcall(require("lulibre.backup").observe) end
end)
