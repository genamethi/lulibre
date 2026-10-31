--- lulibre's systemd units around calibre's content server. Three settings
-- say which units there are:
--
-- - `server_hook = true`: lulibre.service, run before each start of the
--   server's unit: `lulibre offline`, which reads calibre's records and
--   makes the changes that wait for nothing to hold the library.
-- - `opf_writer = "server"`: a drop-in on the server's unit,
--   lulibre-opf-writer.conf, starting the server through
--   contrib/calibre-server-opf.py, so that calibre's own opf writer runs in
--   the server. Not made on a unit with sandboxing or hardening settings:
--   the change is shown instead.
-- - `server_restart_at = "HH:MM"`: lulibre-restart.timer, which restarts the
--   server every day at that time.
--
-- `plan` compares what the settings ask with what is installed, and
-- `apply` makes the difference: a user unit's files directly, a system
-- unit's with sudo in the terminal, after asking. In the interface, as it
-- starts, a user unit is kept as the settings say when one of them has
-- been set (left at their defaults, nothing is touched); the Configuration
-- tab applies a change to one at once; `:units [apply]` shows or makes the
-- plan.
--
-- @library units
-- @usage
-- local units = require "units"
-- local p = units.plan()        --> { server = {name=, user=, pid=}, changes = {...} }
-- units.describe(p)             --> lines
-- units.apply(p, confirm)       --> lines; confirm(question) answers a question
local M = {}

local uv = require "luv"

local here = select(2, ...) -- this file, as require found it: the packaged modules' folder is its own

M.HOOK = "lulibre.service"
M.DROPIN = "lulibre-opf-writer.conf"
M.OLD_DROPIN = "lulibre-opf.conf" -- as `lulibre server-unit` wrote it, before these settings
M.TIMER, M.TIMER_SERVICE = "lulibre-restart.timer", "lulibre-restart.service"
M.SYSTEM_DIR = "/etc/systemd/system"
--- The settings the units follow.
M.SETTINGS = { server_hook = true, opf_writer = true, server_restart_at = true }

setman.create("server_hook", { default = false,
  help = "lulibre's unit runs `lulibre offline` before each start of calibre's content server's unit (:units)" })
setman.create("opf_writer", { default = "off", choices = { "off", "server" },
  help = "server: calibre's content server starts with calibre's own opf writer, through a drop-in on its unit (:units)" })
setman.create("server_restart_at", { default = "",
  help = "HH:MM: a timer restarts calibre's content server every day at that time; empty for none (:units)" })

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

-- the systemd unit a process runs in, from its cgroup: its name, and
-- whether the user's manager runs it (user@UID.service in the path)
local function unit_of(pid)
  local path = (readfile(("/proc/%d/cgroup"):format(pid)) or ""):match("0::(%S+)") or ""
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
    local cmd = pid and readfile(("/proc/%d/cmdline"):format(pid)) or ""
    local server = false
    for arg in cmd:gmatch("[^\0]+") do
      local base = arg:match("([^/]+)$")
      server = server or base == "calibre-server" or base == "calibre-server-opf.py"
    end
    local u = server and unit_of(pid)
    if u and not seen[u.name .. tostring(u.user)] then
      seen[u.name .. tostring(u.user)] = true
      u.pid = pid
      out[#out + 1] = u
    end
  end
  return out
end

--- Returns the folder where a user's units are written: ~/.config/systemd/user.
function M.user_dir()
  return (os.getenv("HOME") or "") .. "/.config/systemd/user"
end

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
        if text:find("calibre-server", 1, true) then out[#out + 1] = { name = name, user = d[2] } end
      end
    end
  end
  return out
end

--- Returns the units that run calibre-server: those running it now, or
-- else those whose files start it.
-- @treturn {table,...} `{ {name=, user=, pid=}, ... }`
function M.find()
  local units = running_units()
  if #units == 0 then units = unit_files() end
  return units
end

local function systemctl(user, ...)
  local a = { "systemctl" }
  if user then a[#a + 1] = "--user" end
  for _, x in ipairs { ... } do a[#a + 1] = x end
  return utils.exec(a, { timeout = 30000 })
end

-- the unit as systemd reads it: its files ("# /path" before each) and, for
-- [Service], every setting in order
local function read_unit(u)
  local r, why = systemctl(u.user, "cat", u.name)
  if not r or r.code ~= 0 then return nil, r and r.stderr or why end
  local unit, section = { files = {}, settings = {} }, nil
  for line in (r.stdout .. "\n"):gmatch("([^\n]*)\n") do
    local file = line:match("^# (/%S+)$")
    if file then
      unit.files[#unit.files + 1] = file
    else
      local s = line:match("^%[(.+)%]%s*$")
      if s then
        section = s
      elseif section == "Service" then
        local k, v = line:match("^%s*(%w+)%s*=%s*(.-)%s*$")
        if k then unit.settings[#unit.settings + 1] = { key = k, value = v, file = unit.files[#unit.files] } end
      end
    end
  end
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
      if s.key:match(pat) then
        found[#found + 1] = s.key
        break
      end
    end
  end
  return found
end

local function ours(file)
  local base = file and file:match("[^/]+$")
  return base == M.DROPIN or base == M.OLD_DROPIN
end

-- the ExecStart in effect, leaving out lulibre's own drop-ins: the last
-- list after the last empty reset
local function exec_start(unit)
  local list = {}
  for _, s in ipairs(unit.settings) do
    if s.key == "ExecStart" and not ours(s.file) then
      if s.value == "" then list = {} else list[#list + 1] = s end
    end
  end
  return list
end

local function setting(unit, key) -- a [Service] setting, the last given
  local v
  for _, s in ipairs(unit.settings) do
    if s.key == key then v = s.value end
  end
  return v
end

-- ---- what is written ----

-- this lulibre, as a unit runs it; and whether it is a source tree's
local function lulibre_exe()
  local exe = uv.exepath()
  exe = exe and (uv.fs_realpath(exe) or exe)
  return exe, exe and exists((exe:match("^(.*)/[^/]+$") or ".") .. "/../lua/lulib/_prelude.lua")
end

-- calibre-server-opf.py: beside the packaged modules' folder, installed or
-- in a source tree; and whether it is a tree's
local function launcher()
  local dir = here and here:match("^(.*)/[^/]+$")
  local p = dir and (uv.fs_realpath(dir .. "/../contrib/calibre-server-opf.py"))
  return p, p and select(2, lulibre_exe())
end

local function which(name)
  for dir in (os.getenv("PATH") or "/usr/bin:/bin"):gmatch("[^:]+") do
    if exists(dir .. "/" .. name) then return dir .. "/" .. name end
  end
  return "/usr/bin/" .. name
end

local function header(setting_)
  return ("# Written by lulibre (%s): `:units` keeps this as the setting says.\n"):format(setting_)
end

local function hook_text(server, as_user)
  local lines = {
    "[Unit]",
    "Description=lulibre: before calibre's content server starts (calibre's records read, waiting changes made)",
    "Before=" .. server.name,
    "",
    "[Service]",
    "Type=oneshot",
    "ExecStart=" .. lulibre_exe() .. " offline",
    -- the server waits for this one: a lulibre that never ended would hold it back for ever
    "TimeoutStartSec=30min",
  }
  if not server.user then lines[#lines + 1] = "User=" .. as_user end
  for _, l in ipairs { "", "[Install]", "WantedBy=" .. server.name, "" } do lines[#lines + 1] = l end
  return header("server_hook = true") .. table.concat(lines, "\n")
end

local function timer_texts(server, at)
  local h, m = at:match("^(%d%d?):(%d%d)$")
  local service = header("server_restart_at = " .. at) .. table.concat({
    "[Unit]",
    "Description=lulibre: restart calibre's content server (" .. server.name .. ")",
    "",
    "[Service]",
    "Type=oneshot",
    "ExecStart=" .. which("systemctl") .. (server.user and " --user" or "") .. " restart " .. server.name,
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
local function dropin(unit)
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
    .. ("[Service]\nExecStart=\nExecStart=%s -e %s -- %s\n"):format(debug_exe, path, rest), nil, from_tree
end

-- ---- the plan ----

local function valid_time(at)
  local h, m = tostring(at or ""):match("^(%d%d?):(%d%d)$")
  return h and tonumber(h) < 24 and tonumber(m) < 60
end

--- Compares what the settings ask with what is installed, and returns the
-- changes. A change with `manual` or `cannot` is shown, not made.
-- @treturn table `{ server=, why=, changes = { {feature=, setting=, files = { {path=, text=} },
-- remove = { path, ... }, before=, after = { {systemctl args}, ... }, restart=, manual=,
-- cannot=, from_tree= }, ... } }`
function M.plan()
  local p = { changes = {} }
  local found = M.find()
  if #found == 0 then
    p.why = "no systemd unit on this machine runs calibre-server"
    return p
  elseif #found > 1 then
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
  local dir = server.user and M.user_dir() or M.SYSTEM_DIR
  local as_user = setting(unit, "User") or os.getenv("USER") or ""
  local hook_want <const>, opf <const>, at <const> = setman.get("server_hook", "opf_writer", "server_restart_at")

  local hook, text = dir .. "/" .. M.HOOK, hook_text(server, as_user)
  local have = readfile(hook)
  if hook_want and have ~= text then
    p.changes[#p.changes + 1] = { feature = "lulibre.service", setting = "server_hook = true",
      files = { { path = hook, text = text } }, after = { { "daemon-reload" }, { "enable", M.HOOK } },
      from_tree = select(2, lulibre_exe()) and "this lulibre runs from a source tree: the unit would run it from there" or nil }
  elseif not hook_want and have and have:find("Written by lulibre", 1, true) then
    p.changes[#p.changes + 1] = { feature = "lulibre.service", setting = "server_hook = false",
      remove = { hook }, before = { { "disable", M.HOOK } }, after = { { "daemon-reload" } } }
  end

  local ddir = dir .. "/" .. server.name .. ".d"
  local path, old = ddir .. "/" .. M.DROPIN, ddir .. "/" .. M.OLD_DROPIN
  have = readfile(path)
  if opf == "server" then
    local dtext, why, from_tree = dropin(unit)
    if not dtext then
      p.changes[#p.changes + 1] = { feature = "the opf writer", setting = "opf_writer = server", cannot = why }
    elseif have ~= dtext or exists(old) then
      local hard = hardening(unit)
      p.changes[#p.changes + 1] = { feature = "the opf writer", setting = "opf_writer = server",
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
    p.changes[#p.changes + 1] = { feature = "the opf writer", setting = "opf_writer = off", remove = gone,
      after = { { "daemon-reload" } }, restart = server.pid ~= nil, rmdir = ddir }
  end

  local tpath, spath = dir .. "/" .. M.TIMER, dir .. "/" .. M.TIMER_SERVICE
  local thave = readfile(tpath)
  if at ~= "" then
    if not valid_time(at) then
      p.changes[#p.changes + 1] = { feature = "the daily restart", setting = "server_restart_at = " .. at,
        cannot = "server_restart_at is a time of day, HH:MM" }
    else
      local stext, ttext = timer_texts(server, at)
      if thave ~= ttext or readfile(spath) ~= stext then
        p.changes[#p.changes + 1] = { feature = "the daily restart", setting = "server_restart_at = " .. at,
          files = { { path = spath, text = stext }, { path = tpath, text = ttext } },
          after = { { "daemon-reload" }, { "enable", "--now", M.TIMER } } }
      end
    end
  elseif thave and thave:find("Written by lulibre", 1, true) then
    p.changes[#p.changes + 1] = { feature = "the daily restart", setting = "server_restart_at off",
      remove = { tpath, spath }, before = { { "disable", "--now", M.TIMER } }, after = { { "daemon-reload" } } }
  end
  return p
end

-- ---- making the changes ----

local function sc_line(user, args)
  return (user and "systemctl --user " or "sudo systemctl ") .. table.concat(args, " ")
end

--- Returns the plan as lines.
-- @tparam table p the plan
-- @treturn {string,...}
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
  out[1] = ("%s (a %s unit%s)"):format(s.name, s.user and "user" or "system", s.pid and (", running, process " .. s.pid) or "")
  if p.why then
    out[#out + 1] = p.why .. "."
    return out
  end
  if #p.changes == 0 then
    out[#out + 1] = "As the settings say: nothing to change (server_hook, opf_writer, server_restart_at)."
    return out
  end
  for _, c in ipairs(p.changes) do
    out[#out + 1] = ""
    out[#out + 1] = ("%s (%s):"):format(c.feature, c.setting)
    if c.cannot then
      out[#out + 1] = "  not possible: " .. c.cannot .. "."
    else
      for _, cmd in ipairs(c.before or {}) do out[#out + 1] = "  " .. sc_line(s.user, cmd) end
      for _, f in ipairs(c.files or {}) do out[#out + 1] = "  write " .. f.path end
      for _, r in ipairs(c.remove or {}) do out[#out + 1] = "  remove " .. r end
      for _, cmd in ipairs(c.after or {}) do out[#out + 1] = "  " .. sc_line(s.user, cmd) end
      if c.restart then out[#out + 1] = "  then a restart of " .. s.name .. " (asked)" end
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
  local r, why = systemctl(true, table.unpack(cmd))
  if not r or r.code ~= 0 then
    error(("systemctl --user %s: %s"):format(table.concat(cmd, " "), r and (r.stderr:gsub("%s+$", "")) or why), 0)
  end
end

-- a system unit's change: the files written here first, then put in place
-- and systemctl run with sudo, in the terminal (sudo asks for its password)
local function run_system(c)
  local function sudo(argv)
    local status, why = uiman.in_terminal({ "sudo", table.unpack(argv) })
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

--- Asks a yes or no question on the line; false unless the answer begins with y.
function M.confirm(question)
  local a = uiman.input { prompt = question .. " (y|N) " }
  return a ~= nil and a:match("^[yY]") ~= nil
end

--- Makes the plan's changes.
-- @tparam table p the plan
-- @tparam[opt] function confirm `confirm(question)` -> boolean, asked before a
-- system unit's changes (sudo) and before restarting the server. Without it,
-- nothing is asked and only a user unit's changes are made.
-- @treturn {string,...} the lines to show
function M.apply(p, confirm)
  local out = {}
  if not p.server or p.why then return M.describe(p) end
  local s, restart = p.server, false
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
      out[#out + 1] = ("%s: done (%s)"):format(c.feature, c.setting)
      restart = restart or c.restart
    elseif confirm and confirm(("%s (%s) changes a system unit: run the commands with sudo?"):format(c.feature, c.setting)) then
      run_system(c)
      out[#out + 1] = ("%s: done with sudo (%s)"):format(c.feature, c.setting)
      restart = restart or c.restart
    else
      out[#out + 1] = ("%s: waits (a system unit: `:units apply` makes it with sudo)"):format(c.feature)
    end
  end
  if restart then
    if confirm and confirm(("restart %s now, for the opf writer's change to take effect?"):format(s.name)) then
      if s.user then
        run_user({ "restart", s.name })
      else
        local status = uiman.in_terminal({ "sudo", "systemctl", "restart", s.name })
        if status ~= 0 then error("sudo systemctl restart " .. s.name .. " did not succeed", 0) end
      end
      out[#out + 1] = s.name .. " restarted."
    else
      out[#out + 1] = ("The opf writer's change takes effect when %s is next started."):format(s.name)
    end
  end
  return out
end

--- Shows the plan in the pager; with apply, makes it first (asking before
-- sudo or a restart).
function M.show(apply)
  local p = M.plan()
  local lines = apply and not (p.server and not p.why and #p.changes == 0) and M.apply(p, M.confirm) or M.describe(p)
  uiman.pager("calibre's server and lulibre's systemd units", table.concat(lines, "\n") .. "\n")
end

--- Runs as the interface starts. When one of the settings has been set
-- (init.lua, the command line, the saved state), a user unit's changes are
-- made as they say, and said in one line; left at their defaults, nothing
-- is touched. A system unit's changes wait for `:units apply`.
function M.on_start()
  local set = false
  for name in pairs(M.SETTINGS) do set = set or setman.info(name).from ~= "default" end
  if not set then return end
  local ok, p = pcall(M.plan)
  if not ok or not p.server or p.why or #p.changes == 0 then return end
  if not p.server.user then
    uiman.log(("systemd units: %s is a system unit; `:units apply` makes the settings' changes with sudo"):format(p.server.name))
    return
  end
  local said = M.apply(p, nil)
  uiman.log("systemd units: " .. table.concat(said, "; "))
  uiman.notify("systemd units changed as the settings say: " .. table.concat(said, "; "))
end

--- Called by the Configuration tab after it changes a setting: one the
-- units follow is applied at once, asking before sudo or a restart.
function M.follow(name)
  if M.SETTINGS[name] then M.show(true) end
end

cmdman.create("units", function(o) M.show(o.args == "apply") end,
  { desc = "[apply]  lulibre's systemd units around calibre's content server, as server_hook, opf_writer and server_restart_at say", complete = { "apply" } })

return M
