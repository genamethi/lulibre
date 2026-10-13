-- The sync folder beside the library: the files waiting to be added in a
-- column on the left, and beside it the library's own list, which follows
-- the file under the cursor: to the book that is the very same file, when
-- the library holds it already, else narrowed to the books that look like
-- it. The preview shows the file under the cursor; Tab crosses to the
-- library's list, and the preview then shows the book there.
local sync = require "lulibre.sync"
local edit = require "lulibre.edit"

local M = {}

local keys = require("lulibre.ui.keys").of("beside")
local panels = require "lulibre.ui.panels"

local SMALL = { the = 1, ["and"] = 1, ["for"] = 1, with = 1, from = 1, into = 1, over = 1, some = 1, notes = 1, lecture = 1,
  lectures = 1, introduction = 1, theory = 1, volume = 1, edition = 1 }

--- A filter for the library's books that look like a title: its three
-- longest words, all of which must be in a book's title, authors or tags.
-- nil when the title has nothing to go by.
function M.likely(title)
  local words, seen = {}, {}
  -- (dashes and quotes that are not ASCII part words like any other punctuation)
  for w in lulibre.fold(title or ""):gsub("\226\128[\144-\159]", " "):gmatch("[%w\128-\255]+") do
    if #w >= 4 and not SMALL[w] and not seen[w] and not w:match("^%d+$") then
      seen[w] = true
      words[#words + 1] = w
    end
  end
  if #words == 0 then return nil end
  local by_length = { table.unpack(words) }
  table.sort(by_length, function(a, b) return #a > #b end)
  local take = {}
  for i = 1, math.min(3, #by_length) do take[by_length[i]] = true end
  local out = {}
  for _, w in ipairs(words) do
    if take[w] then out[#out + 1] = w end
  end
  return table.concat(out, " ")
end

function M.run()
  if (lulibre.o.sync_dir or "") == "" then
    lulibre.notify('no sync folder is set: lulibre.o.sync_dir = "~/some/folder" in init.lua', "error")
    return
  end
  local seen = sync.scan()
  if seen.new > 0 then lulibre.index { filter = "in:sync" } end -- so that the preview has their first pages to show
  if lulibre.source() ~= "library" then lulibre.source("library") end
  local was = lulibre.filter() -- the list is given back as it was found

  local files
  local function load()
    files = lulibre.sql("SELECT id, path, title, authors, twin FROM staged ORDER BY id DESC")
  end
  local function build()
    local rows = {}
    for i, f in ipairs(files) do
      rows[i] = { f.twin and ("= " .. f.twin) or "new", f.title or "", edit.is_unknown(f.authors) and "" or (f.authors or ""),
        (f.path:match("[^/]+$") or f.path), id = -f.id, style = f.twin and "dim" or nil }
    end
    return rows
  end
  local function title()
    local new = 0
    for _, f in ipairs(files) do
      if not f.twin then new = new + 1 end
    end
    return ("sync folder beside the library   %d file%s, %d new"):format(#files, #files == 1 and "" or "s", new)
  end

  load()
  if #files == 0 then
    lulibre.notify(("nothing is waiting in %s"):format(seen.dir))
    return
  end
  local p <close> = lulibre.panel {
    title = title(), help = keys:hint("add", "drop", "edit", "match"), side = "left", width = 0.42, follow = true, moves = true,
    reloads = true, keys = keys:own(), pass = panels.PASS,
    columns = { { "", 7 }, { "title", -1 }, { "author", 16 }, { "file", 22 } }, rows = build(),
  }

  local narrowed, matching = nil, true
  -- bring the library's list beside the file under the cursor
  local function beside(f)
    if not f then return end
    if f.twin then
      if narrowed then
        lulibre.filter(was or "")
        narrowed = nil
      end
      lulibre.jump(f.twin)
      return
    end
    local like = matching and M.likely(f.title)
    if like and lulibre.count(like) == 0 then like = nil end
    if like ~= narrowed then
      lulibre.filter(like or was or "")
      narrowed = like
    end
  end
  local function refresh(keep)
    load()
    p:rows(build())
    p:title(title())
    if keep then p:cursor(math.min(keep, math.max(1, #files))) end
    beside(files[p:cursor() or 1])
  end
  beside(files[1])

  while true do
    local key, row = p:wait()
    if not key then break end
    local f = files[row]
    local act = keys:action(key)
    if key == "<Move>" then
      beside(f)
    elseif key == "<Reload>" then
      refresh(row)
    elseif act == "help" then
      keys:show("the sync folder beside the library", panels.also())
    elseif act == "match" then
      matching = not matching
      beside(f)
      lulibre.notify(matching and "the library's list follows: books that look like the file under the cursor"
        or "the library's list stays as it is, but for files it already holds")
    elseif act == "rescan" then
      sync.scan()
      refresh(row)
    elseif f and act == "edit" then
      panels.over(p, require("lulibre.ui.edit").run, { ids = { -f.id } })
      refresh(row)
    elseif f and act == "review" then
      panels.over(p, require("lulibre.ui.review").run, { ids = { -f.id } })
      refresh(row)
    elseif f and (act == "add" or act == "move") then
      if act == "add" or lulibre.confirm(("add %s to the library and delete it from the sync folder?"):format(f.title or f.path)) then
        local out = sync.add({ -f.id }, { remove = act == "move" })
        lulibre.notify(sync.summary(out), #out.failed > 0 and "error" or nil)
        refresh(row)
      end
    elseif f and act == "drop" then
      if lulibre.confirm(("take %s out of the sync folder without adding it? (%s puts it back)"):format(f.title or f.path,
          lulibre.hint("undo"))) then
        local out = sync.drop { -f.id }
        lulibre.notify(#out.failed > 0 and out.failed[1] or ("dropped; kept in %s"):format(out.holding), #out.failed > 0 and "error" or nil)
        refresh(row)
      end
    end
    if #files == 0 then
      lulibre.notify("nothing is left waiting in the sync folder")
      break
    end
  end
  if narrowed then lulibre.filter(was or "") end
end

return M
