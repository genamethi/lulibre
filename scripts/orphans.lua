-- The records against the library's folders: files a record names that
-- are not on disk, files in the books' folders that no record names, and
-- empty folders. Nothing is changed.
--   :run orphans      lulibre run orphans
local bookman = require "bookman"
local iter = require "iter"
local luv = require "luv"

-- what calibre keeps in a book's folder beside its formats
local calibre_own = { ["cover.jpg"] = true, ["metadata.opf"] = true }

local root = assert(luv.fs_realpath(setman.get("library")))

-- the files in the books' folders (author/title (id)/file), and the folders
-- with nothing in them
local on_disk, empty = {}, {}
local function scan(dir, depth)
  local req = luv.fs_scandir(dir)
  local n = 0
  while req do
    local name, kind = luv.fs_scandir_next(req)
    if not name then break end
    n = n + 1
    local full = dir .. "/" .. name
    if kind == "directory" and depth < 2 and not name:find("^%.") then
      scan(full, depth + 1)
    elseif kind ~= "directory" and depth == 2 and not calibre_own[name] then
      on_disk[#on_disk + 1] = { path = full }
    end
  end
  if n == 0 and depth > 0 then empty[#empty + 1] = dir end
end
scan(root, 0)

local named = {}
for _, id in ipairs(bookman.ids("")) do
  for _, f in ipairs(bookman.files(id)) do named[#named + 1] = { book = id, path = f.path } end
end

local function rel(path) return path:sub(#root + 2) end
local function path(f) return f.path end

local gone = iter(named):diff(on_disk, path):totable()
print(("files a record names that are not on disk: %d"):format(#gone))
for _, f in ipairs(gone) do print(("  %5d  %s"):format(f.book, rel(f.path))) end

local strays = iter(on_disk):diff(named, path):totable()
print(("files no record names: %d"):format(#strays))
for _, f in ipairs(strays) do print("         " .. rel(f.path)) end

print(("empty folders: %d"):format(#empty))
for _, dir in ipairs(empty) do print("         " .. rel(dir)) end
