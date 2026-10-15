-- Orphans: what the library's records and the library's folder disagree on.
--   records with no file   the book is in calibre but its file is gone
--   files with no record   a file sits in one of calibre's folders that
--                          calibre does not know about
--   broken links           a symbolic link in a folder of your own inside the
--                          library (a reading list, say) points at a book file
--                          that has moved; calibre renames a book's folder
--                          whenever its title or author changes
--   empty folders          reported, never touched
-- Each gets a verdict and a suggested action; nothing happens until apply().
-- Folders in the library that are not calibre's are otherwise left alone.
local dupes = require "lulibre.dupes"
local edit = require "lulibre.edit"
local uv = require "luv"

local M = {}

-- calibre's own files inside a book's folder
local OWN = { ["cover.jpg"] = true, ["metadata.opf"] = true }

local function norm(s)
  return (lulibre.fold(s or ""):gsub("[^%w]+", " "):gsub("^ +", ""):gsub(" +$", ""))
end

local function library()
  return (uv.fs_realpath(lulibre.o.library) or lulibre.o.library):gsub("/+$", "")
end

-- What is in the library folder. Calibre's folders (those some book's path
-- starts with) are searched for regular files; other folders only for
-- symbolic links that lead nowhere.
local function walk(root, calibres)
  local files, links, empty = {}, {}, {}
  local function visit(dir, depth, own)
    local req = uv.fs_scandir(dir)
    if not req then return end
    local n = 0
    while true do
      local name, kind = uv.fs_scandir_next(req)
      if not name then break end
      n = n + 1
      local path = dir .. "/" .. name
      if kind == "directory" then
        if depth > 0 then visit(path, depth + 1, own)
        elseif name:sub(1, 1) ~= "." then visit(path, 1, calibres[name] or false) end -- not .caltrash, .calnotes
      elseif kind == "link" then
        if not own and not uv.fs_stat(path) then links[#links + 1] = path end
      elseif kind == "file" and own and depth > 0 and not OWN[name] then
        files[#files + 1] = path
      end
    end
    if n == 0 and depth > 0 then empty[#empty + 1] = dir end
  end
  visit(root, 0, false)
  table.sort(files)
  table.sort(links)
  table.sort(empty)
  return files, links, empty
end

-- link target relative to the link's own folder, both being under root
local function relative(from_dir, to)
  local a, b = {}, {}
  for part in from_dir:gmatch("[^/]+") do a[#a + 1] = part end
  for part in to:gmatch("[^/]+") do b[#b + 1] = part end
  local i = 1
  while a[i] and a[i] == b[i] do i = i + 1 end
  local out = {}
  for _ = i, #a do out[#out + 1] = ".." end
  for k = i, #b do out[#out + 1] = b[k] end
  return table.concat(out, "/")
end

-- What became of each dangling link: calibre's folder names end in the
-- book's id, which says where the file is now.
function M.describe_links(root, dangling)
  local links = {}
  for _, path in ipairs(dangling) do
    local l = { path = path, rel = path:sub(#root + 2), target = uv.fs_readlink(path) or "" }
    l.book = tonumber(l.target:match("%((%d+)%)/[^/]*$"))
    local now = l.book and lulibre.sql("SELECT path FROM files WHERE book = ? ORDER BY id LIMIT 1", l.book)[1]
    if now and uv.fs_stat(now.path) then
      l.to = relative(path:match("^(.*)/[^/]*$"), now.path)
      l.verdict = ("book %d's file has moved"):format(l.book)
      l.action = "relink"
      l.actions = { "relink", "keep", "unlink" }
    else
      l.verdict = l.book and ("book %d is gone or has no file"):format(l.book) or "points at nothing in the library"
      l.action = "keep"
      l.actions = { "keep", "unlink" }
    end
    links[#links + 1] = l
  end
  return links
end

local function calibre_folders()
  local calibres = {}
  for _, b in ipairs(lulibre.sql("SELECT DISTINCT path FROM books WHERE id > 0 AND path IS NOT NULL")) do
    calibres[b.path:match("^[^/]+") or ""] = true
  end
  return calibres
end

--- Only the links: every symbolic link in a folder of your own inside the
-- library that leads nowhere, described as in scan().links.
function M.broken_links()
  local root = library()
  local _, dangling = walk(root, calibre_folders())
  return M.describe_links(root, dangling)
end

--- Point links (as described above, with .to set) at their files again.
-- Returns how many were repaired.
function M.relink(links)
  local n = 0
  for _, l in ipairs(links) do
    if l.to and uv.fs_unlink(l.path) and uv.fs_symlink(l.to, l.path) then n = n + 1 end
  end
  return n
end

--- Look. Returns
-- (verdict says what was found; brief, where there is one, is a shorter
-- wording for a narrow column)
-- { records = { {book=, verdict=, brief=, action=, actions=, stray=, twin=}, ... },
--   strays  = { {path=, rel=, size=, verdict=, action=, actions=, twin=}, ... },
--   links   = { {path=, rel=, target=, book=, to=, verdict=, action=, actions=}, ... },
--   empty   = { path, ... }, root = }
-- action is one of "keep", "remove" (the record), "reattach" (give the record
-- the file found for it), "move" (take the stray file out of the library),
-- "add" (make the stray file a book), "relink" (point the link at where the
-- book's file is now) or "unlink" (delete the link).
function M.scan()
  local root = library()
  local known = {}
  for _, f in ipairs(lulibre.sql("SELECT path FROM files WHERE book > 0")) do known[f.path] = true end
  local calibres = calibre_folders()
  local on_disk, dangling, empty = walk(root, calibres)
  local strays, by_book_dir = {}, {}
  for _, path in ipairs(on_disk) do
    if not known[path] then
      local st = uv.fs_stat(path)
      local s = { path = path, rel = path:sub(#root + 2), size = st and st.size or 0 }
      strays[#strays + 1] = s
      -- calibre names a book's folder "Title (id)"
      local id = tonumber(path:match("%((%d+)%)/[^/]*$"))
      if id then
        by_book_dir[id] = by_book_dir[id] or {}
        table.insert(by_book_dir[id], s)
      end
    end
  end

  -- Which books have a file on disk. The disk is asked directly, so this
  -- holds even for books the indexer has not been run over yet.
  local has_file = {}
  for _, f in ipairs(lulibre.sql("SELECT book, path FROM files WHERE book > 0")) do
    if not has_file[f.book] and uv.fs_stat(f.path) then has_file[f.book] = true end
  end
  local with_file, missing = {}, {}
  for _, b in ipairs(lulibre.books("in:library")) do
    if has_file[b.id] then
      local k = norm(b.title)
      if k ~= "" then
        with_file[k] = with_file[k] or {}
        table.insert(with_file[k], b)
      end
    else
      missing[#missing + 1] = b
    end
  end

  local records = {}
  for _, book in ipairs(missing) do
    local r = { book = book }
    local mine = by_book_dir[book.id]
    if mine and #mine == 1 then
      r.stray = mine[1]
      mine[1].claimed = book.id
      r.verdict = "its file is at " .. mine[1].rel
      r.brief = "its file is on disk"
      r.action, r.actions = "reattach", { "reattach", "keep", "remove" }
    else
      -- another book with the same title and author is the same work; with
      -- the same title and no author to compare it only might be
      local maybe
      for _, other in ipairs(with_file[norm(book.title)] or {}) do
        if edit.is_unknown(book.author) or edit.is_unknown(other.author) then
          maybe = maybe or other
        elseif lulibre.fold(book.author) == lulibre.fold(other.author) then
          r.twin = r.twin or other
        end
      end
      if r.twin then
        r.verdict = ("book %d is the same work and has its file"):format(r.twin.id)
        r.brief = ("same work as book %d"):format(r.twin.id)
        r.action = "remove"
      elseif maybe then
        r.twin = maybe
        r.verdict = ("book %d has this title, but one of the two has no author to compare"):format(maybe.id)
        r.brief = ("book %d has this title"):format(maybe.id)
        r.action = "keep"
      else
        r.verdict = "no other copy in the library"
        r.action = "keep"
      end
      r.actions = { "keep", "remove" }
    end
    records[#records + 1] = r
  end

  -- what the unclaimed stray files are; hashing runs in parallel
  local loose = {}
  for _, s in ipairs(strays) do
    if not s.claimed then loose[#loose + 1] = s end
  end
  lulibre.each(loose, function(s)
    s.twin = dupes.twin(s.path)
    if s.twin then
      s.verdict = ("identical to book %d's file"):format(s.twin)
      s.action = "move"
    else
      s.verdict = "not in calibre"
      s.action = "keep"
    end
    s.actions = { "keep", "move", "add" }
  end, { progress = "checking" })

  local links = M.describe_links(root, dangling)

  return { records = records, strays = loose, links = links, empty = empty, root = root }
end

--- How many of each action a scan result now holds.
function M.counts(found)
  local n = { keep = 0, remove = 0, reattach = 0, move = 0, add = 0, relink = 0, unlink = 0 }
  for _, r in ipairs(found.records) do n[r.action] = n[r.action] + 1 end
  for _, s in ipairs(found.strays) do n[s.action] = n[s.action] + 1 end
  for _, l in ipairs(found.links) do n[l.action] = n[l.action] + 1 end
  return n
end

--- What the records about to be removed know that their surviving copies
-- do not, as changes to the survivors (see dupes.gather).
function M.gather(found)
  local groups = {}
  for _, r in ipairs(found.records) do
    if r.action == "remove" and r.twin and not edit.is_unknown(r.twin.author) then
      groups[#groups + 1] = { keep = r.twin.id, books = { r.twin, r.book } }
    end
  end
  return dupes.gather(groups)
end

local function mkdir_p(dir)
  local at = ""
  for part in dir:gmatch("[^/]+") do
    at = at .. "/" .. part
    uv.fs_mkdir(at, 493) -- 0755; exists already is fine
  end
end

-- Take a file out of the library into the holding folder, keeping its path
-- below the library so it can be put back by hand.
local function set_aside(path, rel, holding)
  local to = holding .. "/" .. rel
  mkdir_p(to:match("^(.*)/[^/]*$"))
  local ok, err = uv.fs_rename(path, to)
  if not ok then -- another filesystem: copy, then delete
    ok, err = uv.fs_copyfile(path, to)
    if ok then ok, err = uv.fs_unlink(path) end
  end
  if not ok then return nil, err end
  uv.fs_rmdir(path:match("^(.*)/[^/]*$")) -- only succeeds if that left it empty
  return to
end

--- Carry out the actions. Waits. Returns { reattached=, removed=, moved=,
-- added=, relinked=, unlinked=, failed = { "what: why", ... }, holding = folder or nil }.
function M.apply(found)
  local out = { reattached = 0, removed = 0, moved = 0, added = 0, relinked = 0, unlinked = 0, failed = {} }
  local base = lulibre.o.orphans_dir
  if base == "" then
    base = (os.getenv("XDG_DATA_HOME") or ((os.getenv("HOME") or "") .. "/.local/share")) .. "/lulibre/orphans"
  end
  local holding = ("%s/%s"):format(base, os.date("%Y%m%d-%H%M%S"))
  local function aside(s)
    local to, err = set_aside(s.path, s.rel, holding)
    if to then out.holding = holding else table.insert(out.failed, s.rel .. ": " .. tostring(err)) end
    return to
  end
  local function calibredb(...)
    local args = edit.calibredb()
    for _, a in ipairs({ ... }) do args[#args + 1] = a end
    local r, err = lulibre.system(args, { timeout = 300000 })
    if r and r.code == 0 then return true, r.stdout .. r.stderr end
    return false, err or ((r.stderr ~= "" and r.stderr or r.stdout):match("[^\n]*%s*$") or "calibredb failed")
  end

  local remove = {}
  for _, r in ipairs(found.records) do
    if r.action == "reattach" and r.stray then
      lulibre.progress(("giving book %d its file"):format(r.book.id))
      local ok, why = calibredb("add_format", tostring(r.book.id), r.stray.path)
      if ok then
        out.reattached = out.reattached + 1
        aside(r.stray) -- calibre has stored its own copy
      else
        table.insert(out.failed, ("book %d: %s"):format(r.book.id, why))
      end
    elseif r.action == "remove" then
      remove[#remove + 1] = r.book.id
    end
  end
  for _, s in ipairs(found.strays) do
    if s.action == "add" then
      lulibre.progress("adding " .. s.rel)
      local ok, why = calibredb("add", "--duplicates", s.path)
      if ok and why:find("Added book ids") then
        out.added = out.added + 1
        local id = tonumber(why:match("Added book ids:%s*(%d+)"))
        if id then require("lulibre.snapshots").added(id, s.path, "orphans") end
        aside(s)
      else
        table.insert(out.failed, s.rel .. ": " .. tostring(why))
      end
    elseif s.action == "move" then
      if aside(s) then out.moved = out.moved + 1 end
    end
  end
  for _, l in ipairs(found.links) do
    if l.action == "relink" or l.action == "unlink" then
      local ok, err = uv.fs_unlink(l.path)
      if ok and l.action == "relink" then ok, err = uv.fs_symlink(l.to, l.path) end
      if not ok then table.insert(out.failed, l.rel .. ": " .. tostring(err))
      elseif l.action == "relink" then out.relinked = out.relinked + 1
      else out.unlinked = out.unlinked + 1 end
    end
  end
  lulibre.progress(nil)
  if #remove > 0 then
    local n, err = edit.remove(remove, { label = "orphans" })
    out.removed = n
    if err then table.insert(out.failed, err) end
  elseif out.reattached + out.added > 0 then
    lulibre.reload()
  end
  return out
end

--- One line about what apply() did.
function M.summary(out)
  local parts = {}
  local function say(n, what)
    if n > 0 then parts[#parts + 1] = ("%d %s"):format(n, what) end
  end
  say(out.reattached, "given their files back")
  say(out.removed, "records removed")
  say(out.added, "files added as books")
  say(out.moved, "stray files moved out")
  say(out.relinked, "links repaired")
  say(out.unlinked, "links deleted")
  local s = #parts > 0 and table.concat(parts, ", ") or "nothing done"
  if out.holding then s = s .. "; files set aside in " .. out.holding end
  if #out.failed > 0 then s = s .. ("; %d failed: %s"):format(#out.failed, out.failed[1]) end
  return s
end

return M
