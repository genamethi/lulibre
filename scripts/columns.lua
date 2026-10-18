-- calibre columns for lulibre's own fields: #partof (the whole a book is a
-- part of), #part (its number in it) and #parts (how many there are), so
-- that calibre shows them and can sort and search by them too. An example
-- of lulibre.custom and lulibre.offline: calibre makes a column only while
-- the content server is stopped, so the columns are queued, and made the
-- next time it is (lulibre.service), or now if you say so.
--   :run columns               queue the columns; restart now, or not now
--   :run columns push          once they are there: copy lulibre's values into them
--   :run columns remove        take them out of calibre again (lulibre keeps its values)
--   lulibre columns            the same, from the shell
local custom = require "lulibre.custom"
local offline = require "lulibre.offline"

local COLUMNS = {
  { "#partof", { heading = "Part of" } },
  { "#part", { heading = "Part" } },
  { "#parts", { heading = "Parts", datatype = "int" } }, -- a count: calibre's int, not the float a number becomes
}

local function say(msg, level)
  if lulibre.headless then print(msg) else lulibre.notify(msg, level) end
end

local args = { ... }
if args[1] == "remove" then
  for _, c in ipairs(COLUMNS) do
    if custom.state(c[1]).state ~= "lulibre" then assert(custom.remove_column(c[1])) end
  end
  return offline.ask()
end
if args[1] == "push" then
  for _, c in ipairs(COLUMNS) do
    local st = custom.state(c[1])
    if st.state == "calibre" and st.differ > 0 then
      local r = custom.push(c[1])
      say(("%s: %d copied%s"):format(c[1], r.copied, #r.failed > 0 and (", %d failed: %s"):format(#r.failed, r.failed[1].error) or ""),
        #r.failed > 0 and "error" or nil)
    elseif st.state ~= "calibre" then
      say(("%s: calibre has no column for it yet (:run columns)"):format(c[1]))
    end
  end
  return
end

local queued = 0
for _, c in ipairs(COLUMNS) do
  local st = custom.state(c[1])
  if st.state == "lulibre" then
    assert(custom.add_column(c[1], c[2]))
    queued = queued + 1
  end
end
if queued == 0 and #offline.jobs() == 0 then
  return say("calibre has the columns already (:run columns push copies lulibre's values into them)")
end
offline.ask()
