--- The packaged commands (design 12): each a module function run as a
-- task, called through the module's table, so a redefinition in init.lua
-- takes effect (design 6).
--
-- @library cmd
local bookman = require "bookman"
local iter = require "iter"
local propose = require "lulib._propose"
local review = require "lulib._review"

local M = {}

--- The books a command is for: the filter it was given, else the
-- selection at the time it was invoked (`selection` says so outright).
function M.books(o, otherwise)
  local args = o.args or ""
  if args ~= "" and args ~= "selection" then return bookman.ids(args) end
  if o.selection and #o.selection > 0 then return o.selection end
  return otherwise and bookman.ids(otherwise) or {}
end

-- fn(book) for each book: how many books it gave a count above 0 for,
-- and the sum of the counts
local function tally(ids, fn)
  local counts = iter(ids):map(fn):filter(function(n) return n > 0 end):totable()
  return #counts, iter(counts):fold(0, function(sum, n) return sum + n end)
end

--- :propose [filter]: proposals for the books, for :review.
function M.propose(ids)
  local w <const> = propose.settings()
  local books, fields = tally(ids, function(id) return propose.propose(id, w) end)
  print(("proposals for %d fields of %d books"):format(fields, books))
end

--- :review [filter]: the books' proposals.
function M.review(ids)
  review.open(ids)
end

--- :enrich [filter]: ask the online services about the books, by their
-- identifiers; each new answer posts "source_arrived", which proposes for
-- the book again.
function M.enrich(ids)
  local net = require "net"
  local books, answers = tally(ids, net.enrich)
  print(("%d new answers for %d books"):format(answers, books))
end

--- :dupes: books whose files hold the same bytes. Files of the same size
-- are hashed (MD5; the index keeps each hash while the file is unchanged),
-- and those with the same hash are a group, the most space taken by copies
-- first. Changes nothing.
-- @treturn {table,...} `{ {md5=, size=, files = { {book=, path=, size=}, ... }}, ... }`, and how many files
function M.duplicates()
  local luv = require "luv"
  local files = {}
  for _, id in ipairs(bookman.ids("")) do
    for _, f in ipairs(bookman.files(id)) do
      local st = luv.fs_stat(f.path)
      if st and st.size > 0 then files[#files + 1] = { book = id, path = f.path, size = st.size } end
    end
  end
  local function several(_, list) return #list > 1 end
  local groups = {}
  for _, same_size in iter(files):group(function(f) return f.size end):filter(several) do
    for md5, same in iter(same_size):group(function(f) return utils.md5(f.path) end):filter(several) do
      groups[#groups + 1] = { md5 = md5, size = same[1].size, files = same }
    end
  end
  table.sort(groups, function(a, b) return a.size * (#a.files - 1) > b.size * (#b.files - 1) end)
  return groups, #files
end

function M.dupes()
  local groups, nfiles = M.duplicates()
  local rows, spare = {}, 0
  for _, g in ipairs(groups) do
    spare = spare + g.size * (#g.files - 1)
    rows[#rows + 1] = { ("%s  %d bytes  %d copies"):format(g.md5, g.size, #g.files), style = "head" }
    for _, f in ipairs(g.files) do
      local b = bookman.get(f.book)
      rows[#rows + 1] = { ("  %5d  %s  —  %s"):format(f.book, b.title or "", b.author or ""), id = f.book }
    end
  end
  local total = ("%d files, %d groups of the same bytes, %d bytes in the copies past the first"):format(nfiles, #groups, spare)
  rows[#rows + 1] = { total, style = "note" }
  uiman.list { title = "dupes", help = total, follow = true, items = rows }
end

--- :orphans: the records against the library's folders. Changes nothing.
-- @treturn table `{ gone = { {book=, path=}, ... }, strays = { {path=}, ... }, empty = { dir, ... }, root= }`:
-- files a record names that are not on disk, files in the books' folders no
-- record names, and empty folders
function M.orphaned()
  local luv = require "luv"
  local calibre_own = { ["cover.jpg"] = true, ["metadata.opf"] = true } -- kept beside a book's formats
  local root = assert(luv.fs_realpath(setman.get("path.library")))
  local on_disk, empty = {}, {}
  -- the files in the books' folders (author/title (id)/file), and the folders with nothing in them
  local function scan(dir, depth)
    local req, n = luv.fs_scandir(dir), 0
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
  local function path(f) return f.path end
  return { gone = iter(named):diff(on_disk, path):totable(), strays = iter(on_disk):diff(named, path):totable(),
    empty = empty, root = root }
end

function M.orphans()
  local o = M.orphaned()
  local function rel(path) return path:sub(#o.root + 2) end
  local rows = {}
  local function head(text) rows[#rows + 1] = { text, style = "head" } end
  head(("files a record names that are not on disk: %d"):format(#o.gone))
  for _, f in ipairs(o.gone) do rows[#rows + 1] = { ("  %5d  %s"):format(f.book, rel(f.path)), id = f.book } end
  head(("files no record names: %d"):format(#o.strays))
  for _, f in ipairs(o.strays) do rows[#rows + 1] = { "         " .. rel(f.path) } end
  head(("empty folders: %d"):format(#o.empty))
  for _, dir in ipairs(o.empty) do rows[#rows + 1] = { "         " .. rel(dir) } end
  uiman.list { title = "orphans", follow = true, items = rows }
end

--- :tag-dots [write]: tags whose levels are split with "/"
-- ("math/number-theory") rewritten with calibre's "." ("math.number-theory"),
-- which calibre shows as a tree in the categories listed under Preferences →
-- Look & feel → "Categories with hierarchical items". Without write, the
-- list of what it would change; with it, one operation :undo puts back.
-- @treturn {table,...} the changes, as store.apply takes them, and the rows `{book=, tag=, dotted=}`
function M.dotted()
  local changes, found = {}, {}
  for _, b in ipairs(bookman.books("tag:/")) do
    for _, tag in ipairs(b.tags) do
      if tag:find("/", 1, true) then
        local dotted = tag:gsub("%s*/%s*", ".")
        changes[#changes + 1] = { book = b.id, field = "tags", value = tag, op = "remove" }
        changes[#changes + 1] = { book = b.id, field = "tags", value = dotted, op = "add" }
        found[#found + 1] = { book = b.id, tag = tag, dotted = dotted }
      end
    end
  end
  return changes, found
end

function M.tag_dots(write)
  local changes, found = M.dotted()
  local summary = ("%d tags with \"/\" in %d books"):format(#found, #bookman.ids("tag:/"))
  if not write then
    local rows = {}
    for _, f in ipairs(found) do rows[#rows + 1] = { ("%5d  %s  →  %s"):format(f.book, f.tag, f.dotted), id = f.book } end
    rows[#rows + 1] = { summary .. "; :tag-dots write rewrites them", style = "note" }
    uiman.list { title = "tag-dots", help = summary, follow = true, items = rows }
    return
  end
  if #changes == 0 then return print(summary) end
  local batch, err = require("store").apply(changes, "tags: / as .")
  if not batch then error(err or "nothing changed", 0) end
  print(("%s rewritten as operation %d; :undo puts it back"):format(summary, batch))
end

cmdman.create("dupes", function() M.dupes() end, { desc = "books whose files hold the same bytes; changes nothing" })
cmdman.create("orphans", function() M.orphans() end,
  { desc = "files a record names that are not on disk, files no record names, empty folders; changes nothing" })
cmdman.create("tag-dots", function(o) M.tag_dots(o.args == "write") end,
  { desc = "[write]  tags whose levels are split with \"/\", as calibre writes levels, with \".\"", complete = { "write" } })
cmdman.create("enrich", function(o) M.enrich(M.books(o)) end, { desc = "[filter]  ask the online services about the books, by their identifiers", complete = "filter" })
cmdman.create("propose", function(o) M.propose(M.books(o)) end, { desc = "[filter]  propose metadata from the files, for :review", complete = "filter" })
cmdman.create("review", function(o) M.review(M.books(o, "is:proposed")) end, { desc = "[filter]  the books' proposals: accept, edit, reject", complete = "filter" })

return M
