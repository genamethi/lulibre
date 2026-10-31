--- :sync beside: the sync folder beside the library. The files waiting are in a
-- column on the left; the library's list follows the file under the cursor:
-- it moves to the book with the same file if the library already has it, or
-- else narrows to the books that look like the file.
--
-- The screen "beside": a adds the file, m adds it and takes it out of the folder,
-- d drops it, e edits it, r reviews it, f says whether the list narrows, R reads
-- the folder again; q closes. keymap.set("beside", key, action) rebinds them.
--
-- @library lulib._beside
local bookman = require "bookman"
local expr = require "expr"
local store = require "store"
local sync = require "lulib._sync"

local M = {}

local SMALL = { the = 1, ["and"] = 1, ["for"] = 1, with = 1, from = 1, into = 1, over = 1, some = 1, notes = 1, lecture = 1,
                lectures = 1, introduction = 1, theory = 1, volume = 1, edition = 1 }

--- A filter for the library's books that look like a title: the title's three
-- longest words, which must all appear in a book's title, authors or tags; nil
-- if it has no usable words.
-- @tparam string title
-- @treturn string|nil
function M.likely(title)
  local words, seen = {}, {}
  -- (dashes and quotes that are not ASCII part words like any other punctuation)
  for w in expr.fold(title or ""):gsub("\226\128[\144-\159]", " "):gmatch("[%w\128-\255]+") do
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

scrnman.create("beside", {
  actions = {
    { "add", "a", "add the file to the library" },
    { "move", "m", "add the file, and take it out of the folder" },
    { "drop", "d", "take the file out of the folder without adding it (:undo puts it back)" },
    { "edit", "e", "edit the file's record" },
    { "review", "r", "propose for the file, and review" },
    { "match", "f", "say whether the library's list narrows to what looks like the file" },
    { "rescan", "R", "read the folder again" },
  },
  hint = { "add", "drop", "edit", "match" },
})

--- Opens the screen on the waiting files.
function M.open()
  if (setman.get("path.sync") or "") == "" then
    return uiman.notify('no sync folder is set: lulib.opt["path.sync"] = "~/some/folder" in init.lua', "error")
  end
  store.reload()
  local was = uiman.filter() -- the list is given back as it was found
  local files
  local function load()
    files = {}
    for _, id in ipairs(bookman.ids("in:sync")) do
      local row = sync.staged(id)
      if row then
        files[#files + 1] = { id = id, path = row.path, title = row.title, twin = row.twin,
                              authors = bookman.get(id, "authors") or "" }
      end
    end
  end
  local function rows()
    local out = {}
    for i, f in ipairs(files) do
      out[i] = { f.twin and ("= " .. f.twin) or "new", f.title or "", f.authors, (f.path:match("[^/]+$") or f.path),
                 id = f.id, style = f.twin and "dim" or nil }
    end
    return out
  end
  local function title()
    local new = 0
    for _, f in ipairs(files) do
      if not f.twin then new = new + 1 end
    end
    return ("sync folder beside the library   %d file%s, %d new"):format(#files, #files == 1 and "" or "s", new)
  end
  load()
  if #files == 0 then return uiman.notify("nothing is waiting in " .. setman.get("path.sync")) end
  local p <close> = uiman.panel {
    title = title(), screen = "beside", side = "left", width = 0.42, follow = true, moves = true, reloads = true,
    columns = { { "", 7 }, { "title", -1 }, { "author", 16 }, { "file", 22 } }, rows = rows(),
  }
  if not p then return end
  local narrowed, matching = nil, true
  -- brings the library's list beside the file under the cursor
  local function beside(f)
    if not f then return end
    if f.twin then
      if narrowed then
        uiman.filter(was or "")
        narrowed = nil
      end
      uiman.jump(f.twin)
      return
    end
    local like = matching and M.likely(f.title)
    if like and bookman.count(like) == 0 then like = nil end
    if like ~= narrowed then
      uiman.filter(like or was or "")
      narrowed = like
    end
  end
  local function refresh(keep)
    load()
    p:rows(rows())
    p:title(title())
    if keep then p:cursor(math.min(keep, math.max(1, #files))) end
    beside(files[p:cursor() or 1])
  end
  beside(files[1])
  while true do
    local act, row = p:wait()
    if not act then break end
    local f = files[row]
    if act == "<Move>" then
      beside(f)
    elseif act == "<Reload>" then
      refresh(row)
    elseif act == "match" then
      matching = not matching
      beside(f)
      uiman.notify(matching and "the library's list follows: books that look like the file under the cursor"
                   or "the library's list stays as it is, but for files it already holds")
    elseif act == "rescan" then
      store.reload()
      refresh(row)
    elseif f and act == "edit" then
      uiman.jump(f.id)
      uiman.exec("edit")
    elseif f and act == "review" then
      local propose = require "lulib._propose"
      propose.propose(f.id, propose.settings())
      require("lulib._review").open { f.id }
      refresh(row)
    elseif f and (act == "add" or act == "move") then
      local out = sync.add({ f.id }, { remove = act == "move" })
      uiman.notify(sync.summary(out), #out.failed > 0 and "error" or nil)
      refresh(row)
    elseif f and act == "drop" then
      local out = sync.drop { f.id }
      uiman.notify(#out.failed > 0 and out.failed[1] or "dropped; :undo puts it back", #out.failed > 0 and "error" or nil)
      refresh(row)
    end
    if #files == 0 then
      uiman.notify("nothing is left waiting in the sync folder")
      break
    end
  end
  if narrowed then uiman.filter(was or "") end
end

return M
