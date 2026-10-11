-- The sync folder (lulibre.o.sync_dir): files waiting to be added to calibre.
--   gS  or  :sync            look at the folder and show it as the list; gl goes back
--   S   or  :sync add        add the selection to the library; the files stay
--   X   or  :sync move       add the selection, then delete those files from the folder
--   lulibre sync             list the folder
--   lulibre sync add  [filter | all]
--   lulibre sync move [filter | all]
-- In the list a staged file is like a book: e edits it, gc captures from its
-- name, :run propose reads its title page, gr reviews. None of that touches
-- calibre until the file is added. "=" marks a file the library already
-- holds, byte for byte; adding it adds nothing, moving it just deletes it.
local sync = require "lulibre.sync"

local args = { ... }
local what = args[1] or ""
local rest = table.concat(args, " ", 2)

local function state(row)
  return row.twin and ("= book " .. row.twin) or "new"
end

if what == "" or what == "scan" then
  local r = sync.scan()
  local msg = ("%s: %d files, %d new, %d already in the library%s"):format(r.dir, r.total, r.new, r.held,
    r.gone > 0 and (", %d gone"):format(r.gone) or "")
  if lulibre.headless then
    for _, row in ipairs(lulibre.sql("SELECT id, path, title, authors, twin FROM staged ORDER BY id DESC")) do
      io.write(("%6d  %-10s %-40s | %-24s | %s\n"):format(-row.id, state(row), (row.title or ""):sub(1, 40),
        (row.authors or ""):sub(1, 24), row.path:sub(#r.dir + 2)))
    end
    print(msg)
    return
  end
  lulibre.source("sync")
  lulibre.notify(msg .. "   (S adds the selection, X adds and removes; gl is the library)")
  -- read the new files' title pages, if wanted
  if r.new > 0 and lulibre.policy("sync_propose", ("propose metadata for the %d new files from their title pages?"):format(r.new)) then
    lulibre.exec("index")
    for _ = 1, 1200 do -- the indexer works in the background; wait for it
      local left = lulibre.sql("SELECT count(*) AS n FROM files WHERE book < 0 AND status = 0")[1].n
      if left == 0 then break end
      lulibre.sleep(100)
    end
    lulibre.exec("run propose in:sync")
  end
  return
end

if what ~= "add" and what ~= "move" then error("sync: add, move, or nothing to look at the folder", 0) end

local ids
if lulibre.headless then sync.scan() end -- nobody has looked at the folder yet
if lulibre.headless or rest ~= "" then
  ids = lulibre.ids("in:sync " .. (rest == "all" and "" or rest))
else
  if lulibre.source() ~= "sync" then
    lulibre.notify("the list is showing the library; gS shows the sync folder", "error")
    return
  end
  ids = lulibre.selection()
end
if #ids == 0 then
  print("nothing staged matches")
  return
end
if what == "move" and not lulibre.headless then
  if not lulibre.confirm(("add %d file%s to the library and delete %s from the sync folder?"):format(#ids,
      #ids == 1 and "" or "s", #ids == 1 and "it" or "them")) then
    return
  end
end
local out = sync.add(ids, { remove = what == "move" })
print(sync.summary(out))
if #out.failed > 0 then error(out.failed[1], 0) end
