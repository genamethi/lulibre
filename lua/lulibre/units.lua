-- lulibre's part in the systemd units around calibre's content server, as
-- three options ask for it:
--
--   server_hook = "on"          lulibre.service, run before each start of the
--                               server's unit (lulibre offline: the copy of
--                               calibre's database, the opf files, the changes
--                               that wait for the server to be stopped)
--   opf_writer = "server"       a drop-in on the server's unit,
--                               lulibre-opf-writer.conf, that starts the server
--                               through calibre-server-opf.py, so calibre's own
--                               opf writer runs in it
--   server_restart_at = "HH:MM" lulibre-restart.timer: the server restarted
--                               every day at that time
--
-- M.plan() compares what the options ask for with what is installed, and
-- M.apply() makes the difference: the files of a user unit lulibre writes
-- itself; a system unit's are written with sudo, in the terminal, after
-- asking. A unit with sandboxing or hardening settings is not given the
-- drop-in (it changes how the server starts): the change is shown instead.
-- The interface applies a user unit's changes when it starts and when one of
-- the three options is changed in the configuration window; `lulibre units`
-- shows the plan, `lulibre units apply` makes it.
--
--   local units = require "lulibre.units"
--   local p = units.plan()        --> { server = {name=, user=, pid=}, changes = {...} }
--   units.describe(p)             --> lines
--   units.apply(p, confirm)       --> lines; confirm(question) answers a question
local M = {}

local uv = require "luv"

M.HOOK = "lulibre.service"
M.DROPIN = "lulibre-opf-writer.conf"
M.OLD_DROPIN = "lulibre-opf.conf" -- `lulibre server-unit`'s, before these options
M.TIMER, M.TIMER_SERVICE = "lulibre-restart.timer", "lulibre-restart.service"

local function readfile(path)
  local f = io.open(path)
  if not f then return nil end
  local s = f:read("a")
  f:close()
  return s
end

local function exists(path)
  return uv.fs_stat(path) ~= nil
end

-- ---- the server's unit ----

-- the systemd unit a process runs in, from its cgroup: name and whether the
-- user's manager runs it (user@UID.service in the path) or the system's
local function unit_of(pid)
  local cg = readfile(("/proc/%d/cgroup"):format(pid)) or ""
  local path = cg:match("0::(%S+)") or ""
  local unit = path:match("([^/]+%.service)$")
  if not unit then return nil end
  return { name = unit, user = path:find("/user@%d+%.service/") ~= nil }
end

-- calibre-server processes running now, and the units they run in
local function running_units()
  local out, seen = {}, {}
  local h = uv.fs_scandir("/proc")
  while h do
    local name = uv.fs_scandir_next(h)
    if not name then break end
    local pid = tonumber(name)
    local cmd = pid and readfile(("/proc/%d/cmdline"):format(pid))
    local is_server = false
    for arg in (cmd or ""):gmatch("[^\0]+") do
      local base = arg:match("([^/]+)$")
      if base == "calibre-server" or base == "calibre-server-opf.py" then is_server = true end
    end
    if is_server then
      local u = unit_of(pid)
      if u and not seen[u.name .. tostring(u.user)] then
        seen[u.name .. tostring(u.user)] = true
        u.pid = pid
        out[#out + 1] = u
      end
    end
  end
  return out
end

function M.user_dir()
  return (os.getenv("HOME") or "") .. "/.config/systemd/user"
end
M.SYSTEM_DIR = "/etc/systemd/system"

-- units whose files start calibre-server, running or not
local function unit_files()
  local out = {}
  for _, d in ipairs { { M.user_dir(), true }, { (os.getenv("HOME") or "") .. "/.local/share/systemd/user", true },
    { M.SYSTEM_DIR, false } } do
    local h = uv.fs_scandir(d[1])
    while h do
      local name = uv.fs_scandir_next(h)
      if not name then break end
      if name:match("%.service$") and name ~= M.HOOK and name ~= M.TIMER_SERVICE then
        local text = readfile(d[1] .. "/" .. name) or ""
        if text:find("calibre%-server") or text:find("calibre-server-opf.py", 1, true) then
          out[#out + 1] = { name = name, user = d[2] }
        end
      end
    end
  end
  return out
end

--- The units that run calibre-server: those running it now, else those
-- whose files start it. `{ {name=, user=, pid=}, ... }`.
function M.find()
  local units = running_units()
  if #units == 0 then units = unit_files() end
  return units
end

local function systemctl(user, ...)
  local a = { "systemctl" }
  if user then a[#a + 1] = "--user" end
  for _, x in ipairs { ... } do a[#a + 1] = x end
  return lulibre.system(a, { timeout = 30000 })
end

-- the unit as systemd reads it: its files ("# /path" before each) and, for
-- [Service], every setting in order
local function read_unit(u)
  local r = systemctl(u.user, "cat", u.name)
  if not r or r.code ~= 0 then return nil, (r and r.stderr or "systemctl did not run") end
  local unit = { files = {}, settings = {} }
  local section
  for line in (r.stdout .. "\n"):gmatch("([^\n]*)\n") do
    local file = line:match("^# (/%S+)$")
    if file then
      unit.files[#unit.files + 1] = file
    else
      local s = line:match("^%[(.+)%]%s*$")
      if s then
        section = s
      elseif section == "Service" then
        local k, v = line:match("^%s*([%w]+)%s*=%s*(.-)%s*$")
        if k then unit.settings[#unit.settings + 1] = { key = k, value = v, file = unit.files[#unit.files] } end
      end
    end
  end
  unit.fragment = unit.files[1]
  return unit
end

-- settings that sandbox or harden a service: such a unit was set up with
-- care for what it may touch, and its start is not changed here
local HARDENING = { "^Protect", "^Private", "^ReadOnly", "^ReadWrite", "^Inaccessible", "^Exec[A-Z]%w*Paths$",
  "^Restrict", "^SystemCall", "^Capability", "^AmbientCapabilities$", "^DynamicUser$", "^NoNewPrivileges$",
  "^Root", "^BindPaths$", "^BindReadOnlyPaths$", "^TemporaryFileSystem$", "^LockPersonality$",
  "^MemoryDenyWriteExecute$", "^IPAddress", "^SELinuxContext$", "^AppArmorProfile$", "^SmackProcessLabel$" }

local function hardening(unit)
  local found = {}
  for _, s in ipairs(unit.settings) do
    for _, pat in ipairs(HARDENING) do
      if s.key:match(pat) then found[#found + 1] = s.key break end
    end
  end
  return found
end

-- the ExecStart in effect: the last list after the last empty reset, leaving
-- out lulibre's own drop-ins (what the server's unit says by itself)
local function exec_start(unit)
  local list = {}
  for _, s in ipairs(unit.settings) do
    local ours = s.file and (s.file:match("/" .. M.DROPIN:gsub("%-", "%%-") .. "$") or s.file:match("/" .. M.OLD_DROPIN:gsub("%-", "%%-") .. "$"))
    if s.key == "ExecStart" and not ours then
      if s.value == "" then list = {} else list[#list + 1] = s end
    end
  end
  return list
end

-- a setting of [Service], the last given (User=, say)
local function setting(unit, key)
  local v
  for _, s in ipairs(unit.settings) do
    if s.key == key then v = s.value end
  end
  return v
end

-- ---- what is written ----

-- the installed copy of a file of lulibre's when there is one (a unit should
-- not depend on a source tree), else the one beside this module
local function source_root()
  local here = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*)/lua/lulibre/[^/]*$")
  return here and (uv.fs_realpath(here) or here)
end

local function launcher()
  local installed = lulibre.settings.paths().installed .. "/contrib/calibre-server-opf.py"
  local here = source_root()
  if exists(installed) and not (here and installed:find(here, 1, true) == 1) then return installed, false end
  local p = here and (here .. "/contrib/calibre-server-opf.py")
  if p and exists(p) then return p, true end
  return nil
end

-- this lulibre, as a unit should run it; and whether it is a source tree's
local function lulibre_exe()
  local exe = uv.exepath()
  exe = exe and (uv.fs_realpath(exe) or exe)
  local tree = exe and exists((exe:match("^(.*)/[^/]+$") or ".") .. "/../lua/lulibre/prelude.lua")
  return exe, tree
end

local function which(name)
  for dir in (os.getenv("PATH") or "/usr/bin:/bin"):gmatch("[^:]+") do
    if exists(dir .. "/" .. name) then return dir .. "/" .. name end
  end
  return "/usr/bin/" .. name
end

local function header(option)
  return ("# Written by lulibre (%s): `lulibre units` keeps this as the option says.\n"):format(option)
end

local function hook_text(server, user, as_user)
  local exe = lulibre_exe()
  local lines = {
    "[Unit]",
    "Description=lulibre: before calibre's content server starts (a copy of its database, the opf files, waiting changes)",
    "Before=" .. server.name,
    "",
    "[Service]",
    "Type=oneshot",
    "ExecStart=" .. exe .. " offline",
    -- the server waits for this one: a lulibre that never ended would hold it
    -- back for ever; writing every book's opf file the first time can take
    -- minutes, and this is far beyond that
    "TimeoutStartSec=30min",
  }
  -- (added, not left nil in the list: table.concat stops at a nil)
  if not user then lines[#lines + 1] = "User=" .. as_user end
  for _, l in ipairs { "", "[Install]", "WantedBy=" .. server.name, "" } do lines[#lines + 1] = l end
  return header("server_hook = on") .. table.concat(lines, "\n")
end

local function timer_texts(server, user, at)
  local h, m = at:match("^(%d%d?):(%d%d)$")
  local service = header("server_restart_at = " .. at) .. table.concat({
    "[Unit]",
    "Description=lulibre: restart calibre's content server (" .. server.name .. ")",
    "",
    "[Service]",
    "Type=oneshot",
    "ExecStart=" .. which("systemctl") .. (user and " --user" or "") .. " restart " .. server.name,
    "",
  }, "\n")
  local timer = header("server_restart_at = " .. at) .. table.concat({
    "[Unit]",
    "Description=lulibre: restart calibre's content server every day at " .. at,
    "",
    "[Timer]",
    ("OnCalendar=*-*-* %02d:%02d:00"):format(tonumber(h), tonumber(m)),
    "Unit=" .. M.TIMER_SERVICE,
    "",
    "[Install]",
    "WantedBy=timers.target",
    "",
  }, "\n")
  return service, timer
end

-- the drop-in: what the server's ExecStart becomes, or why it cannot be made
local function dropin(server, unit)
  local exec = exec_start(unit)
  if #exec ~= 1 then return nil, ("it has %d ExecStart lines in effect; one is expected"):format(#exec) end
  local line = exec[1].value
  if line:match("^[-@:+!]") then return nil, "its ExecStart has a prefix (" .. line:sub(1, 1) .. ")" end
  local exe, rest = line:match("^(%S+)%s*(.*)$")
  if not exe or not exe:match("calibre%-server$") then
    return nil, ("its ExecStart runs %s, not calibre-server itself"):format(exe or "?")
  end
  local debug_exe = exe:gsub("calibre%-server$", "calibre-debug")
  if not exists(debug_exe) then return nil, ("there is no %s beside calibre-server"):format(debug_exe) end
  local path, from_tree = launcher()
  if not path then return nil, "calibre-server-opf.py is not installed (make install)" end
  return header("opf_writer = server")
    .. "# calibre's content server with calibre's own opf writer (calibre-server-opf.py), so\n"
    .. "# that each book's metadata.opf is kept current while it runs.\n"
    .. ("[Service]\nExecStart=\nExecStart=%s -e %s -- %s\n"):format(debug_exe, path, rest), nil, from_tree, line
end

-- ---- the plan ----

local function valid_time(at)
  local h, m = tostring(at or ""):match("^(%d%d?):(%d%d)$")
  return h and tonumber(h) < 24 and tonumber(m) < 60
end

--- What the options ask for against what is installed: `{ server=, why=,
-- changes = { {feature=, option=, files = { {path=, text=} }, remove = { path, ... },
-- after = { {systemctl args}, ... }, restart=, manual=, cannot=, note=, from_tree= }, ... } }`.
-- A change with `manual` or `cannot` is not made: it is shown.
function M.plan()
  local p = { changes = {} }
  local found = M.find()
  if #found == 0 then
    p.why = "no systemd unit runs calibre-server here"
    return p
  end
  if #found > 1 then
    local names = {}
    for _, u in ipairs(found) do names[#names + 1] = u.name end
    p.why = ("more than one unit runs calibre-server (%s): set them up by hand"):format(table.concat(names, ", "))
    return p
  end
  local server = found[1]
  p.server = server
  local unit, err = read_unit(server)
  if not unit then
    p.why = ("systemctl cannot read %s: %s"):format(server.name, tostring(err))
    return p
  end
  p.fragment = unit.fragment
  local user = server.user
  local dir = user and M.user_dir() or M.SYSTEM_DIR
  local as_user = setting(unit, "User") or (os.getenv("USER") or "")
  local exe_tree = select(2, lulibre_exe())

  -- server_hook: lulibre.service
  local hook = dir .. "/" .. M.HOOK
  local want = lulibre.o.server_hook == "on"
  local text = hook_text(server, user, as_user)
  local have = readfile(hook)
  if want and have ~= text then
    p.changes[#p.changes + 1] = { feature = "lulibre.service", option = "server_hook = on",
      files = { { path = hook, text = text } }, after = { { "daemon-reload" }, { "enable", M.HOOK } },
      from_tree = exe_tree and "this lulibre runs from a source tree: the unit would run it from there" or nil }
  elseif not want and have and have:find("Written by lulibre", 1, true) then
    p.changes[#p.changes + 1] = { feature = "lulibre.service", option = "server_hook = off",
      remove = { hook }, before = { { "disable", M.HOOK } }, after = { { "daemon-reload" } } }
  end

  -- opf_writer: the drop-in on the server's unit
  local ddir = dir .. "/" .. server.name .. ".d"
  local path, old = ddir .. "/" .. M.DROPIN, ddir .. "/" .. M.OLD_DROPIN
  want = lulibre.o.opf_writer == "server"
  have = readfile(path)
  if want then
    local dtext, why, from_tree = dropin(server, unit)
    if not dtext then
      p.changes[#p.changes + 1] = { feature = "the opf writer", option = "opf_writer = server", cannot = why }
    elseif have ~= dtext or exists(old) then
      local hard = hardening(unit)
      p.changes[#p.changes + 1] = { feature = "the opf writer", option = "opf_writer = server",
        files = { { path = path, text = dtext } }, remove = exists(old) and { old } or nil,
        after = { { "daemon-reload" } }, restart = server.pid ~= nil,
        manual = #hard > 0 and ("it has sandboxing or hardening settings (" .. table.concat(hard, ", ")
          .. "): the service must still be able to read the launcher and run calibre-debug") or nil,
        from_tree = from_tree and "the launcher is in a source tree, not installed" or nil }
    end
  elseif have or exists(old) then
    local gone = {}
    if have then gone[#gone + 1] = path end
    if exists(old) then gone[#gone + 1] = old end
    p.changes[#p.changes + 1] = { feature = "the opf writer", option = "opf_writer = off", remove = gone,
      after = { { "daemon-reload" } }, restart = server.pid ~= nil, rmdir = ddir }
  end

  -- server_restart_at: the timer and the service it starts
  local at = lulibre.o.server_restart_at or ""
  local tpath, spath = dir .. "/" .. M.TIMER, dir .. "/" .. M.TIMER_SERVICE
  local thave = readfile(tpath)
  if at ~= "" then
    if not valid_time(at) then
      p.changes[#p.changes + 1] = { feature = "the daily restart", option = "server_restart_at = " .. at,
        cannot = "server_restart_at is a time of day, HH:MM" }
    else
      local stext, ttext = timer_texts(server, user, at)
      if thave ~= ttext or readfile(spath) ~= stext then
        p.changes[#p.changes + 1] = { feature = "the daily restart", option = "server_restart_at = " .. at,
          files = { { path = spath, text = stext }, { path = tpath, text = ttext } },
          after = { { "daemon-reload" }, { "enable", "--now", M.TIMER } } }
      end
    end
  elseif thave and thave:find("Written by lulibre", 1, true) then
    p.changes[#p.changes + 1] = { feature = "the daily restart", option = "server_restart_at off",
      remove = { tpath, spath }, before = { { "disable", "--now", M.TIMER } }, after = { { "daemon-reload" } } }
  end
  return p
end

-- ---- making the changes ----

local function sc_line(user, args)
  return (user and "systemctl --user " or "sudo systemctl ") .. table.concat(args, " ")
end

--- The plan, in lines.
function M.describe(p)
  local out = {}
  if not p.server then
    out[1] = (p.why or "no unit") .. "."
    out[#out + 1] = "Started some other way (an OpenRC or runit service, a script, a container)? Run"
    out[#out + 1] = "`lulibre offline` before each start of the server, and start the server as"
    out[#out + 1] = ("  calibre-debug -e %s -- <its calibre-server arguments>"):format(launcher()
      or "<lulibre>/share/lulibre/contrib/calibre-server-opf.py")
    out[#out + 1] = "for calibre's opf writer in it."
    return out
  end
  local s = p.server
  out[1] = ("%s (a %s unit%s)"):format(s.name, s.user and "user" or "system", s.pid and (", running, pid " .. s.pid) or "")
  if p.why then
    out[#out + 1] = p.why .. "."
    return out
  end
  if #p.changes == 0 then
    out[#out + 1] = "As the options say: nothing to change (server_hook, opf_writer, server_restart_at)."
    return out
  end
  for _, c in ipairs(p.changes) do
    out[#out + 1] = ""
    out[#out + 1] = ("%s (%s):"):format(c.feature, c.option)
    if c.cannot then
      out[#out + 1] = "  not possible: " .. c.cannot .. "."
    else
      for _, cmd in ipairs(c.before or {}) do out[#out + 1] = "  " .. sc_line(s.user, cmd) end
      for _, f in ipairs(c.files or {}) do out[#out + 1] = "  write " .. f.path end
      for _, r in ipairs(c.remove or {}) do out[#out + 1] = "  remove " .. r end
      for _, cmd in ipairs(c.after or {}) do out[#out + 1] = "  " .. sc_line(s.user, cmd) end
      if c.restart then out[#out + 1] = "  then a restart of " .. s.name .. " (offered)" end
      if c.from_tree then out[#out + 1] = "  (" .. c.from_tree .. ")" end
      if c.manual then
        out[#out + 1] = "  left to you: " .. c.manual .. ". The file:"
        for _, f in ipairs(c.files or {}) do
          for l in f.text:gmatch("[^\n]+") do out[#out + 1] = "    " .. l end
        end
      end
    end
  end
  if not s.user then
    out[#out + 1] = ""
    out[#out + 1] = "A system unit: these are made with sudo, in the terminal, after asking."
  end
  return out
end

local function ensure_dir(dir)
  local at = ""
  for part in dir:gmatch("[^/]+") do
    at = at .. "/" .. part
    if not exists(at) then
      local ok, err = uv.fs_mkdir(at, 493) -- 0755
      if not ok and not exists(at) then error(("cannot make %s: %s"):format(at, err), 0) end
    end
  end
end

local function run_user(cmd)
  local r = systemctl(true, table.unpack(cmd))
  if not r or r.code ~= 0 then
    error(("systemctl --user %s: %s"):format(table.concat(cmd, " "), r and (r.stderr:gsub("%s+$", "")) or "did not run"), 0)
  end
end

-- a system unit's change: the files written here first, then put in place
-- and systemctl run with sudo, in the terminal (sudo asks for its password)
local function run_system(c)
  local function sudo(argv)
    local a = { "sudo" }
    for _, x in ipairs(argv) do a[#a + 1] = x end
    local status, why = lulibre.in_terminal(a)
    if status ~= 0 then error(("sudo %s: %s"):format(table.concat(argv, " "), why or ("exit " .. tostring(status))), 0) end
  end
  for _, cmd in ipairs(c.before or {}) do sudo({ "systemctl", table.unpack(cmd) }) end
  for _, f in ipairs(c.files or {}) do
    local tmp = os.tmpname()
    local fh = assert(io.open(tmp, "w"))
    fh:write(f.text)
    fh:close()
    local ok, err = pcall(sudo, { "install", "-D", "-m", "644", tmp, f.path })
    os.remove(tmp)
    if not ok then error(err, 0) end
  end
  for _, r in ipairs(c.remove or {}) do sudo({ "rm", "-f", r }) end
  for _, cmd in ipairs(c.after or {}) do sudo({ "systemctl", table.unpack(cmd) }) end
end

--- Make the plan's changes. confirm(question) is asked before a system
-- unit's changes (sudo) and before restarting the server; nil: nothing is
-- asked, and only a user unit's changes are made. Returns the lines said.
function M.apply(p, confirm)
  local out = {}
  if not p.server or p.why then
    for _, l in ipairs(M.describe(p)) do out[#out + 1] = l end
    return out
  end
  local s = p.server
  local restart = false
  for _, c in ipairs(p.changes) do
    if c.cannot or c.manual then
      out[#out + 1] = ("%s: not made (%s)"):format(c.feature, c.cannot or c.manual)
    elseif s.user then
      for _, cmd in ipairs(c.before or {}) do run_user(cmd) end
      for _, f in ipairs(c.files or {}) do
        ensure_dir(f.path:match("^(.*)/[^/]+$"))
        local fh = assert(io.open(f.path, "w"))
        fh:write(f.text)
        fh:close()
      end
      for _, r in ipairs(c.remove or {}) do os.remove(r) end
      if c.rmdir then uv.fs_rmdir(c.rmdir) end -- (only when it is empty now)
      for _, cmd in ipairs(c.after or {}) do run_user(cmd) end
      out[#out + 1] = ("%s: done (%s)"):format(c.feature, c.option)
      restart = restart or c.restart
    elseif confirm and confirm(("%s (%s) changes a system unit: run the commands with sudo?"):format(c.feature, c.option)) then
      run_system(c)
      out[#out + 1] = ("%s: done with sudo (%s)"):format(c.feature, c.option)
      restart = restart or c.restart
    else
      out[#out + 1] = ("%s: waits (a system unit: `lulibre units apply` makes it with sudo)"):format(c.feature)
    end
  end
  if restart then
    if confirm and confirm(("restart %s now, for the opf writer's change to take effect?"):format(s.name)) then
      if s.user then
        run_user({ "restart", s.name })
      else
        local status = lulibre.in_terminal({ "sudo", "systemctl", "restart", s.name })
        if status ~= 0 then error("sudo systemctl restart " .. s.name .. " did not succeed", 0) end
      end
      out[#out + 1] = s.name .. " restarted."
    else
      out[#out + 1] = ("The opf writer's change takes effect when %s is next started."):format(s.name)
    end
  end
  return out
end

--- When the interface starts: a user unit's changes are made, as the options
-- ask (said in a line); a system unit's wait for `lulibre units apply`.
-- A replaceable function.
function M.on_start()
  local ok, p = pcall(M.plan)
  if not ok or not p.server or p.why or #p.changes == 0 then return end
  if not p.server.user then
    -- (said in the console only: not on every start)
    lulibre.log(("systemd units: %s is a system unit; `lulibre units apply` makes the options' changes with sudo")
      :format(p.server.name), "info")
    return
  end
  local said = M.apply(p, nil)
  lulibre.log("systemd units: " .. table.concat(said, "; "), "info")
  lulibre.notify("systemd units changed as the options say: " .. table.concat(said, "; "))
end

return M
