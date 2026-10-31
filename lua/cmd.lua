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

-- what a finding command says, as rows: uiman.list's, or printed by its ls
local function say(rows)
  for _, r in ipairs(rows) do print(r[1]) end
end

local function dupe_rows(groups, nfiles)
  local rows, spare = {}, 0
  for _, g in ipairs(groups) do
    spare = spare + g.size * (#g.files - 1)
    rows[#rows + 1] = { ("%s  %d bytes  %d copies"):format(g.md5, g.size, #g.files), style = "head" }
    for _, f in ipairs(g.files) do
      local b = bookman.get(f.book)
      rows[#rows + 1] = { ("  %5d  %s  —  %s"):format(f.book, b.title or "", b.author or ""), id = f.book }
    end
  end
  rows[#rows + 1] = { ("%d files, %d groups of the same bytes, %d bytes in the copies past the first"):format(nfiles, #groups, spare), style = "note" }
  return rows
end

--- :dupes [ls]: books whose files hold the same bytes. Files of the same
-- size are hashed (MD5; the index keeps each hash while the file is
-- unchanged), and those with the same hash are a group, the most space
-- taken by copies first. Changes nothing.
-- @tparam[opt] table o `{ ls = true }`: returns what it found, and shows nothing
-- @treturn {table,...} with ls, `{ {md5=, size=, files = { {book=, path=, size=}, ... }}, ... }`, and how many files
function M.dupes(o)
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
  if o and o.ls then return groups, #files end
  local rows = dupe_rows(groups, #files)
  uiman.list { title = "dupes", help = rows[#rows][1], follow = true, items = rows }
end

local function orphan_rows(found)
  local function rel(path) return path:sub(#found.root + 2) end
  local rows = {}
  local function head(text) rows[#rows + 1] = { text, style = "head" } end
  head(("files a record names that are not on disk: %d"):format(#found.gone))
  for _, f in ipairs(found.gone) do rows[#rows + 1] = { ("  %5d  %s"):format(f.book, rel(f.path)), id = f.book } end
  head(("files no record names: %d"):format(#found.strays))
  for _, f in ipairs(found.strays) do rows[#rows + 1] = { "         " .. rel(f.path) } end
  head(("empty folders: %d"):format(#found.empty))
  for _, dir in ipairs(found.empty) do rows[#rows + 1] = { "         " .. rel(dir) } end
  return rows
end

--- :orphans [ls]: the records against the library's folders: files a record
-- names that are not on disk, files in the books' folders no record names,
-- and empty folders. Changes nothing.
-- @tparam[opt] table o `{ ls = true }`: returns what it found, and shows nothing
-- @treturn table with ls, `{ gone = { {book=, path=}, ... }, strays = { {path=}, ... }, empty = { dir, ... }, root= }`
function M.orphans(o)
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
  local found = { gone = iter(named):diff(on_disk, path):totable(), strays = iter(on_disk):diff(named, path):totable(),
    empty = empty, root = root }
  if o and o.ls then return found end
  uiman.list { title = "orphans", follow = true, items = orphan_rows(found) }
end

local function tag_rows(found)
  local rows = {}
  for _, f in ipairs(found) do rows[#rows + 1] = { ("%5d  %s  →  %s"):format(f.book, f.tag, f.dotted), id = f.book } end
  rows[#rows + 1] = { ("%d tags with \"/\" in %d books; :tags write rewrites them"):format(#found, #bookman.ids("tag:/")), style = "note" }
  return rows
end

--- :tags [ls | write]: tags whose levels are split with "/"
-- ("math/number-theory") as calibre writes levels, with "."
-- ("math.number-theory"), which it shows as a tree in the categories listed
-- under Preferences → Look & feel → "Categories with hierarchical items".
-- Shows them; with write, rewrites them, as one operation :undo puts back.
-- @tparam[opt] table o `{ ls = true }`: returns what it found, and shows nothing; `{ write = true }`: rewrites
-- @treturn {table,...} with ls, `{ {book=, tag=, dotted=}, ... }`
function M.tags(o)
  o = o or {}
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
  if o.ls then return found end
  if not o.write then
    local rows = tag_rows(found)
    uiman.list { title = "tags", help = rows[#rows][1], follow = true, items = rows }
    return
  end
  local summary = ("%d tags with \"/\" in %d books"):format(#found, #bookman.ids("tag:/"))
  if #changes == 0 then return print(summary) end
  local batch, err = require("store").apply(changes, "tags: / as .")
  if not batch then error(err or "nothing changed", 0) end
  print(("%s rewritten as operation %d; :undo puts it back"):format(summary, batch))
end

cmdman.create("dupes", function(c)
  if c.args == "ls" then say(dupe_rows(M.dupes { ls = true })) else M.dupes() end
end, { desc = "[ls]  books whose files hold the same bytes; ls prints them; changes nothing", complete = { "ls" } })
cmdman.create("orphans", function(c)
  if c.args == "ls" then say(orphan_rows(M.orphans { ls = true })) else M.orphans() end
end, { desc = "[ls]  files a record names that are not on disk, files no record names, empty folders; ls prints them", complete = { "ls" } })
cmdman.create("tags", function(c)
  if c.args == "ls" then say(tag_rows(M.tags { ls = true })) else M.tags { write = c.args == "write" } end
end, { desc = "[ls | write]  tags whose levels are split with \"/\", as calibre writes levels, with \".\"; write rewrites them", complete = { "ls", "write" } })
cmdman.create("enrich", function(o) M.enrich(M.books(o)) end, { desc = "[filter]  ask the online services about the books, by their identifiers", complete = "filter" })
cmdman.create("propose", function(o) M.propose(M.books(o)) end, { desc = "[filter]  propose metadata from the files, for :review", complete = "filter" })
cmdman.create("review", function(o) M.review(M.books(o, "is:proposed")) end, { desc = "[filter]  the books' proposals: accept, edit, reject", complete = "filter" })

return M
