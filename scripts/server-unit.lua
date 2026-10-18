-- calibre's content server with calibre's own metadata backup, so that each
-- book's metadata.opf is kept current while the server runs, as calibre's
-- program keeps it (contrib/calibre-server-opf.py; docs/workflows.md, "The
-- opf files"). This finds the systemd unit that runs calibre-server and
-- changes its ExecStart, by a drop-in beside it, to run the server through
-- that launcher; the unit's own file is left as it is.
--   lulibre server-unit           what runs calibre-server, and what would change
--   lulibre server-unit apply     make the change (a user unit only, and a
--                                 plain one; otherwise it says what to add)
--   lulibre server-unit remove    take it back
--   :server-unit [apply | remove] the same, in the interface
-- A unit of the system's (/etc/systemd/system), or one with sandboxing or
-- hardening settings, is not changed: the drop-in to add is printed, with
-- the commands, to be added by whoever looks after it.
local uv = require "luv"
local json = require "lulibre.json"

local args = { ... }
local what = args[1] or ""
local DROPIN = "lulibre-opf.conf"

local function say(lines, title)
  if type(lines) == "string" then lines = { lines } end
  if lulibre.headless then
    for _, l in ipairs(lines) do print(l) end
  else
    lulibre.show(lines, title or "calibre's server and the opf files")
  end
end

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

-- where the launcher is: the installed copy when there is one (a unit should
-- not depend on a source tree), else the one beside this script
local function launcher()
  local here = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*)/scripts/[^/]*$")
  here = here and (uv.fs_realpath(here) or here)
  local installed = lulibre.settings.paths().installed .. "/contrib/calibre-server-opf.py"
  if exists(installed) and not (here and installed:find(here, 1, true) == 1) then return installed, false end
  local p = here and (here .. "/contrib/calibre-server-opf.py")
  if p and exists(p) then return p, true end
  return nil
end

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

-- units whose files start calibre-server, running or not
local function unit_files()
  local out = {}
  local home = os.getenv("HOME") or ""
  for _, d in ipairs { { home .. "/.config/systemd/user", true }, { home .. "/.local/share/systemd/user", true },
    { "/etc/systemd/system", false } } do
    local h = uv.fs_scandir(d[1])
    while h do
      local name = uv.fs_scandir_next(h)
      if not name then break end
      if name:match("%.service$") then
        local text = readfile(d[1] .. "/" .. name) or ""
        if text:find("calibre%-server") or text:find("calibre-server-opf.py", 1, true) then
          out[#out + 1] = { name = name, user = d[2] }
        end
      end
    end
  end
  return out
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
-- care for what it may touch, and is not changed here
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

-- the ExecStart in effect: the last list after the last empty reset
local function exec_start(unit)
  local list = {}
  for _, s in ipairs(unit.settings) do
    if s.key == "ExecStart" then
      if s.value == "" then list = {} else list[#list + 1] = s end
    end
  end
  return list
end

-- What would change, and whether lulibre may make the change itself.
local function assess(u)
  local unit, err = read_unit(u)
  if not unit then return { unit = u, why_not = "systemctl cannot read it: " .. tostring(err) } end
  local a = { unit = u, files = unit.files, fragment = unit.fragment }
  local exec = exec_start(unit)
  local dropin_dir = (u.user and ((os.getenv("HOME") or "") .. "/.config/systemd/user/") or "/etc/systemd/system/")
    .. u.name .. ".d"
  a.dropin = dropin_dir .. "/" .. DROPIN
  for _, f in ipairs(unit.files) do
    if f == a.dropin then a.applied = true end
  end
  if #exec ~= 1 then
    a.why_not = ("it has %d ExecStart lines in effect; one is expected"):format(#exec)
    return a
  end
  local line = exec[1].value
  a.exec = line
  if line:find("calibre-server-opf.py", 1, true) then
    a.done = true
    return a
  end
  if line:match("^[-@:+!]") then
    a.why_not = "its ExecStart has a prefix (" .. line:sub(1, 1) .. "): the line is not changed by hand here"
  end
  local exe, rest = line:match("^(%S+)%s*(.*)$")
  if not exe or not exe:match("calibre%-server$") then
    a.why_not = a.why_not or ("its ExecStart runs %s, not calibre-server itself"):format(exe or "?")
  else
    a.debug = exe:gsub("calibre%-server$", "calibre-debug")
    if not exists(a.debug) then a.why_not = a.why_not or ("there is no %s beside calibre-server"):format(a.debug) end
  end
  local path, from_tree = launcher()
  if not path then a.why_not = a.why_not or "calibre-server-opf.py is not installed (make install)" end
  a.launcher, a.from_tree = path, from_tree
  if path and a.debug then a.new_exec = ("%s -e %s -- %s"):format(a.debug, path, rest) end
  local hard = hardening(unit)
  if #hard > 0 then a.hardening = hard end
  if not u.user then
    a.manual = "it is a unit of the system's: it is for whoever looks after the system to change"
  elseif a.hardening then
    a.manual = "it has sandboxing or hardening settings (" .. table.concat(hard, ", ") .. "): it is left to you"
  elseif unit.fragment and not (unit.fragment:find("/.config/systemd/user/", 1, true)
        or unit.fragment:find("/.local/share/systemd/user/", 1, true)) then
    a.manual = "its file is not one of yours (" .. unit.fragment .. ")"
  end
  return a
end

local function dropin_text(a)
  return ("# Written by `lulibre server-unit`: calibre's content server with calibre's own\n"
    .. "# metadata backup (calibre-server-opf.py), so that each book's metadata.opf is\n"
    .. "# kept current while it runs. `lulibre server-unit remove` takes it away.\n"
    .. "[Service]\nExecStart=\nExecStart=%s\n"):format(a.new_exec)
end

local function describe(a)
  local u = a.unit
  local out = { ("%s (%s unit%s)"):format(u.name, u.user and "a user" or "a system", u.pid and (", running, pid " .. u.pid) or "") }
  for _, f in ipairs(a.files or {}) do out[#out + 1] = "  " .. f end
  if a.done then
    out[#out + 1] = ""
    out[#out + 1] = "It runs calibre-server through calibre-server-opf.py already."
    local st = require("lulibre.calibre").server()
    if st then
      out[#out + 1] = st.opf_thread and ("calibre's metadata backup is running (calibre %s)."):format(st.calibre or "?")
        or ("The server runs without the thread: %s"):format(st.error or "?")
    elseif u.pid then
      out[#out + 1] = "No status from it (a restart since the change? a read-only home?)."
    end
    return out
  end
  out[#out + 1] = ""
  if a.exec then out[#out + 1] = "now:   ExecStart=" .. a.exec end
  if a.new_exec then out[#out + 1] = "would: ExecStart=" .. a.new_exec end
  if a.from_tree then out[#out + 1] = "(the launcher is in a source tree: install lulibre first, so the unit does not depend on it)" end
  if a.why_not then
    out[#out + 1] = ""
    out[#out + 1] = "Not changed: " .. a.why_not .. "."
    return out
  end
  out[#out + 1] = ""
  if a.manual then
    out[#out + 1] = "Not changed by lulibre: " .. a.manual .. ". To make the change, add this as"
    out[#out + 1] = "  " .. a.dropin
    out[#out + 1] = ""
    for l in dropin_text(a):gmatch("[^\n]+") do out[#out + 1] = "    " .. l end
    out[#out + 1] = ""
    local sc = u.user and "systemctl --user" or "sudo systemctl"
    out[#out + 1] = ("  (%s edit %s opens such a drop-in), then: %s daemon-reload && %s restart %s"):format(sc, u.name, sc, sc, u.name)
    if a.hardening then
      out[#out + 1] = "  With the sandboxing it has, the service must be able to read the launcher, and"
      out[#out + 1] = "  calibre-debug beside calibre-server; the status file (~/.local/state/lulibre/) is"
      out[#out + 1] = "  optional: without it lulibre cannot tell that the files are being written."
    end
  else
    out[#out + 1] = "`lulibre server-unit apply` makes the change: a drop-in at"
    out[#out + 1] = "  " .. a.dropin
    out[#out + 1] = "(the unit's own file is left as it is), then systemctl --user daemon-reload."
  end
  return out
end

local function other_ways(path)
  return {
    "",
    "Not started by systemd? Wherever calibre-server is started (an OpenRC or runit service,",
    "a script, a container's command), start it as",
    ("  calibre-debug -e %s -- <the same calibre-server arguments>"):format(path or "<lulibre>/contrib/calibre-server-opf.py"),
    "with the calibre-debug of the same calibre. With calibre's program in use instead of the",
    "server, nothing is needed: the program keeps the files current itself.",
  }
end

local function find()
  local units = running_units()
  if #units == 0 then units = unit_files() end
  return units
end

local function confirm(question)
  if lulibre.headless then
    io.write(question .. " [y/N] ")
    io.flush()
    local answer = io.read("l") or ""
    return answer:lower():match("^y") ~= nil
  end
  return lulibre.confirm(question)
end

local units = find()
if #units == 0 then
  local out = { "No systemd unit runs calibre-server here (none running, none in ~/.config/systemd/user or /etc/systemd/system)." }
  for _, l in ipairs(other_ways(launcher())) do out[#out + 1] = l end
  return say(out)
end
if #units > 1 and what ~= "" then
  local names = {}
  for _, u in ipairs(units) do names[#names + 1] = u.name end
  error(("more than one unit runs calibre-server (%s): change it by hand, as `lulibre server-unit` shows"):format(
    table.concat(names, ", ")), 0)
end

if what == "" or what == "show" then
  local out = {}
  for i, u in ipairs(units) do
    if i > 1 then out[#out + 1] = "" end
    for _, l in ipairs(describe(assess(u))) do out[#out + 1] = l end
  end
  for _, l in ipairs(other_ways(launcher())) do out[#out + 1] = l end
  return say(out)
elseif what == "apply" then
  local a = assess(units[1])
  if a.done then return say(describe(a)) end
  if a.why_not or a.manual then return say(describe(a)) end
  if a.from_tree and not confirm("the launcher is in a source tree, not installed; point the unit at it anyway?") then return end
  if not confirm(("change %s to run calibre-server through calibre-server-opf.py (a drop-in, %s)?"):format(a.unit.name, a.dropin)) then
    return
  end
  local dir = a.dropin:match("^(.*)/[^/]+$")
  if not exists(dir) then
    local ok, err = uv.fs_mkdir(dir, 493) -- 0755
    if not ok and not exists(dir) then error(("cannot make %s: %s"):format(dir, err), 0) end
  end
  local f = assert(io.open(a.dropin, "w"))
  f:write(dropin_text(a))
  f:close()
  local r = systemctl(true, "daemon-reload")
  if not r or r.code ~= 0 then error("systemctl --user daemon-reload: " .. (r and r.stderr or "did not run"), 0) end
  local out = { ("%s now runs calibre-server through calibre-server-opf.py, from its next start (%s)."):format(a.unit.name, a.dropin) }
  if a.unit.pid then
    if confirm(("restart %s now?"):format(a.unit.name)) then
      r = systemctl(true, "restart", a.unit.name)
      if not r or r.code ~= 0 then error("systemctl --user restart: " .. (r and r.stderr or "did not run"), 0) end
      out[#out + 1] = "Restarted."
    else
      out[#out + 1] = "It takes effect when the server is next started."
    end
  end
  return say(out)
elseif what == "remove" then
  local a = assess(units[1])
  if not exists(a.dropin) then return say("There is no drop-in of lulibre's for " .. a.unit.name .. ".") end
  if not a.unit.user then return say({ "It is a unit of the system's; remove it with", "  sudo rm " .. a.dropin,
    "  sudo systemctl daemon-reload && sudo systemctl restart " .. a.unit.name }) end
  if not confirm(("remove %s (back to calibre-server as the unit has it)?"):format(a.dropin)) then return end
  assert(os.remove(a.dropin))
  uv.fs_rmdir(a.dropin:match("^(.*)/[^/]+$")) -- only if it is empty now
  local r = systemctl(true, "daemon-reload")
  if not r or r.code ~= 0 then error("systemctl --user daemon-reload: " .. (r and r.stderr or "did not run"), 0) end
  return say(("Removed; %s runs calibre-server as before from its next start."):format(a.unit.name))
else
  error("server-unit [show | apply | remove]", 0)
end
