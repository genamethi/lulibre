-- Books whose files hold the same bytes. Files of the same size are hashed
-- (MD5; the index keeps each hash while the file is unchanged), and those
-- with the same hash are a group, shown in a list (printed by lulibre
-- run). Nothing is changed.
--   :run dupes        lulibre run dupes
local bookman = require "bookman"
local iter = require "iter"
local luv = require "luv"

local function several(_, list) return #list > 1 end

-- every file the records name, that is on disk and not empty
local files = {}
for _, id in ipairs(bookman.ids("")) do
  for _, f in ipairs(bookman.files(id)) do
    local st = luv.fs_stat(f.path)
    if st and st.size > 0 then files[#files + 1] = { book = id, path = f.path, size = st.size } end
  end
end

local groups = {}
for _, same_size in iter(files):group(function(f) return f.size end):filter(several) do
  for md5, same in iter(same_size):group(function(f) return utils.md5(f.path) end):filter(several) do
    groups[#groups + 1] = { md5 = md5, size = same[1].size, files = same }
  end
end
-- the most space taken by copies first
table.sort(groups, function(a, b) return a.size * (#a.files - 1) > b.size * (#b.files - 1) end)

local rows, spare = {}, 0
for _, g in ipairs(groups) do
  spare = spare + g.size * (#g.files - 1)
  rows[#rows + 1] = { ("%s  %d bytes  %d copies"):format(g.md5, g.size, #g.files), style = "head" }
  for _, f in ipairs(g.files) do
    local b = bookman.get(f.book)
    rows[#rows + 1] = { ("  %5d  %s  —  %s"):format(f.book, b.title or "", b.author or ""), id = f.book }
  end
end
local total = ("%d files, %d groups of the same bytes, %d bytes in the copies past the first"):format(#files, #groups, spare)
rows[#rows + 1] = { total, style = "note" }
uiman.list { title = "dupes", help = total, follow = true, items = rows }
