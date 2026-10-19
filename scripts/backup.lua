-- Copies of calibre's database (lulibre.backup): the copies, making one,
-- calibre's database checked, and a copy put back.
--   lulibre backup                    the copies, and when they are made
--   lulibre backup now [WHY]          make one
--   lulibre backup check              calibre's database: SQLite's integrity check (read only)
--   lulibre backup compare COPY       what putting COPY back would change (writes nothing)
--   lulibre backup restore COPY       shows that, asks, and puts it back once nothing has
--                                     the library open (lulibre.offline); --yes: do not ask
--   lulibre backup always | next | never | DAYS   before the server starts (backup_restart)
--   lulibre backup prune [KEEP]       remove all but the newest KEEP
-- COPY is a copy's place in the list (1, the newest) or its folder's name.
-- In the interface: :backup, with the same words.
local backup = require "lulibre.backup"

local args, flags = {}, {}
for _, a in ipairs { ... } do
  local flag = a:match("^%-%-(.+)$")
  if flag then
    if flag ~= "yes" then error("backup: --" .. flag .. "? (only --yes)", 0) end
    flags[flag] = true
  else
    args[#args + 1] = a
  end
end
local verb = table.remove(args, 1) or ""

local function say(lines, title, level)
  if type(lines) == "string" then lines = { lines } end
  if lulibre.headless then
    for _, l in ipairs(lines) do (level == "error" and io.stderr or io.stdout):write(l, "\n") end
  elseif #lines == 1 and not title then
    lulibre.notify(lines[1], level)
  else
    lulibre.show(lines, title)
  end
end

local function when(ts) return os.date("%Y-%m-%d %H:%M", ts) end

local function find()
  local which = args[1]
  if not which then error(("backup %s COPY (1 is the newest: `backup` lists them)"):format(verb), 0) end
  local b = backup.find(which)
  if not b then error(("no copy %s, or more than one by that name (`backup` lists them)"):format(which), 0) end
  return b
end

local function check_line(ok, problems)
  if ok then return "calibre's database passes SQLite's integrity check" end
  return ("calibre's database FAILS SQLite's integrity check (%d problem%s): put a copy back (`backup restore`), or "
    .. "have calibre rebuild it from the books' metadata.opf files (calibredb restore_database)")
    :format(#problems, #problems == 1 and "" or "s")
end

if verb == "now" then
  local b = backup.take(#args > 0 and table.concat(args, " ") or "asked for")
  if b.check == "ok" then
    say(("calibre's database copied to %s"):format(b.path))
  else
    say({ ("calibre's database copied to %s; the copy FAILS SQLite's integrity check:"):format(b.path),
      table.unpack(b.problems or {}) }, "a copy of calibre's database", "error")
  end
elseif verb == "check" then
  local ok, problems = backup.check()
  local lines = { check_line(ok, problems) }
  for i, p in ipairs(problems or {}) do
    if i > 20 then
      lines[#lines + 1] = ("  ... and %d more"):format(#problems - 20)
      break
    end
    lines[#lines + 1] = "  " .. p
  end
  say(lines, not ok and "calibre's database" or nil, not ok and "error" or nil)
  if not ok and lulibre.headless then error("the integrity check failed", 0) end
elseif verb == "compare" then
  local b = find()
  say(backup.describe(b, backup.compare(b)), "putting a copy back   (nothing has been changed)")
elseif verb == "restore" then
  local b = find()
  local lines = backup.describe(b, backup.compare(b))
  lines[#lines + 1] = ""
  lines[#lines + 1] = "calibre's database as it is now is copied first (put that copy back to undo this)."
  if lulibre.headless then
    if not flags.yes then lines[#lines + 1] = "(add --yes to do it)" end
    say(lines)
    if not flags.yes then return end
  elseif not flags.yes then
    lulibre.show(lines, "putting a copy back")
    if not lulibre.confirm(("put back the copy of %s?"):format(when(b.ts))) then
      lulibre.notify("nothing changed")
      return
    end
  end
  local id = backup.restore(b)
  if lulibre.headless then print(("queued (offline job %d)"):format(id)) end
  require("lulibre.offline").ask()
elseif verb == "prune" then
  say(("%d copies removed"):format(backup.prune(tonumber(args[1]))))
elseif verb ~= "" then
  backup.set(tonumber(verb) or verb)
  say(("backup_restart = %s"):format(verb))
else
  local out = {}
  for i, b in ipairs(backup.list()) do
    out[#out + 1] = ("%2d  %s  %5s books  %-6s  %s"):format(i, when(b.ts), tostring(b.books or "?"),
      b.check == "failed" and "FAILED" or b.check or "", b.reason or "")
  end
  if #out == 0 then out[1] = "no copies of calibre's database yet (backup now makes one)" end
  out[#out + 1] = ""
  out[#out + 1] = ("before the server starts: %s%s;  kept: %d;  too old after %d days (%s)"):format(
    tostring(lulibre.o.backup_restart), backup.policy() == "next" and (backup.due() and ", not yet spent" or ", spent") or "",
    lulibre.o.backup_keep, lulibre.o.backup_max_age, tostring(lulibre.o.backup_too_old))
  out[#out + 1] = ("in %s"):format(backup.dir())
  local opf = require("lulibre.calibre").opf()
  out[#out + 1] = ("the books' metadata.opf files: %s%s"):format(opf.why,
    opf.behind and (";  %d behind their record now"):format(opf.behind) or "")
  say(out, "copies of calibre's database   (backup compare N, backup restore N)")
end
