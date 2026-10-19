-- Changes calibre makes only while the content server is stopped (adding a
-- custom column, check_library ...), queued until it is (lulibre.offline).
--   lulibre offline            do them now: the server must be stopped
--                              (lulibre.service runs this before each start)
--   lulibre offline list       what waits, and what failed
--   lulibre offline cancel ID  drop one
--   :offline                   in the interface: what waits
--   :offline restart           stop the server, do them, start it again
--                              (needs the server_stop and server_start options)
--   :offline cancel ID
local offline = require "lulibre.offline"

local args = { ... }
local what = args[1] or ""

local function list()
  local out = {}
  for _, status in ipairs { "waiting", "failed" } do
    for _, j in ipairs(offline.jobs(status)) do
      out[#out + 1] = ("%4d  %-8s %s  %s%s"):format(j.id, status, os.date("%Y-%m-%d %H:%M", j.ts), offline.describe(j),
        j.error and ("  " .. j.error) or "")
    end
  end
  if #out == 0 then out[1] = "nothing waits for the content server to be stopped" end
  return out
end

if what == "list" or (what == "" and not lulibre.headless) then
  local out = list()
  if lulibre.headless then
    for _, l in ipairs(out) do print(l) end
  else
    lulibre.show(out, "waiting for the content server to be stopped")
  end
elseif what == "cancel" then
  local id = tonumber(args[2])
  if not id then error("offline cancel ID (the number offline list gives)", 0) end
  local msg = offline.cancel(id) and ("job %d cancelled"):format(id) or ("no job %d waits"):format(id)
  if lulibre.headless then print(msg) else lulibre.notify(msg) end
elseif what == "restart" then
  local r = offline.restart()
  lulibre.notify(offline.summary(r), #r.failed > 0 and "error" or nil)
elseif what == "" or what == "run" then
  local r = offline.run()
  local msg = offline.summary(r)
  if lulibre.headless then
    print(msg)
    for _, f in ipairs(r.failed) do io.stderr:write(("job %d (%s): %s\n"):format(f.id, f.label or "", f.error)) end
    if #r.failed > 0 then error(("%d failed"):format(#r.failed), 0) end
  else
    lulibre.notify(msg, #r.failed > 0 and "error" or nil)
  end
else
  error("offline [list | cancel ID | restart | run]", 0)
end
