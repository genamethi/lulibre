--- Where the library's records and its folder disagree, and fixing what you
-- choose (:orphans). It finds records with no file, files with no record, symbolic
-- links in your own folders inside the library that point at a book file calibre
-- has since moved, and empty folders (reported, never touched). Each gets a verdict
-- and a suggested action; nothing changes until `apply`. A file taken out of the
-- library goes to orphans/ beside the index, under its path in the library.
--
-- The screen "orphans": Space or Enter changes what will be done about the row (on
-- a heading, about all under it), x shows the row in full, X all of them, m marks the
-- records set to go, f narrows the list to books whose file is missing, t proposes a
-- record's values for the book with its file, e edits, r reviews, w does it; q closes.
-- keymap.set("orphans", key, action) rebinds them.
--
-- @library lulib._orphans
local bookman = require "bookman"
local expr = require "expr"
local luv = require "luv"
local sql = require "sql"
local sqlite3 = require "lsqlite3"
local store = require "store"

local M = {}

-- calibre's own files inside a book's folder
local OWN = { ["cover.jpg"] = true, ["metadata.opf"] = true }

local function norm(s)
  return (expr.fold(s or ""):gsub("[^%w]+", " "):gsub("^ +", ""):gsub(" +$", ""))
end

local function index_rows(query, ...)
  local db = sql.open(setman.get("path.indexdb"), sqlite3.OPEN_READONLY)
  local rows = sql.run(db, query, ...)
  db:close()
  return rows
end

local function calibre_folders()
  local out = {}
  for _, id in ipairs(bookman.ids("")) do
    for _, f in ipairs(bookman.files(id) or {}) do
      local top = f.path:match("^" .. setman.get("path.library"):gsub("%p", "%%%0") .. "/([^/]+)/")
      if top then out[top] = true end
    end
  end
  for _, r in ipairs(index_rows("SELECT DISTINCT path FROM books WHERE id > 0 AND path IS NOT NULL")) do
    out[r.path:match("^[^/]+") or ""] = true
  end
  return out
end

-- What is in the library folder. Calibre's folders are searched for regular files;
-- other folders only for symbolic links that lead nowhere.
local function walk(root, calibres)
  local files, links, empty = {}, {}, {}
  local function visit(dir, depth, own)
    local req = luv.fs_scandir(dir)
    if not req then return end
    local n = 0
    while true do
      local name, kind = luv.fs_scandir_next(req)
      if not name then break end
      n = n + 1
      local path = dir .. "/" .. name
      if kind == "directory" then
        if depth > 0 then visit(path, depth + 1, own)
        elseif name:sub(1, 1) ~= "." then visit(path, 1, calibres[name] or false) end -- not .caltrash, .calnotes
      elseif kind == "link" then
        if not own and not luv.fs_stat(path) then links[#links + 1] = path end
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

local function describe_links(root, dangling)
  local links = {}
  for _, path in ipairs(dangling) do
    local l = { path = path, rel = path:sub(#root + 2), target = luv.fs_readlink(path) or "" }
    l.book = tonumber(l.target:match("%((%d+)%)/[^/]*$"))
    local now = l.book and (bookman.files(l.book) or {})[1]
    if now and luv.fs_stat(now.path) then
      l.to = relative(path:match("^(.*)/[^/]*$"), now.path)
      l.verdict = ("book %d's file has moved"):format(l.book)
      l.action, l.actions = "relink", { "relink", "keep", "unlink" }
    else
      l.verdict = l.book and ("book %d is gone or has no file"):format(l.book) or "points at nothing in the library"
      l.action, l.actions = "keep", { "keep", "unlink" }
    end
    links[#links + 1] = l
  end
  return links
end

--- The library book that holds the bytes of a file, or nil.
function M.twin(path)
  local st = luv.fs_stat(path)
  if not st then return nil end
  local mine
  for _, f in ipairs(index_rows("SELECT book, path FROM files WHERE book > 0 AND size = ? AND path <> ? ORDER BY book", st.size, path)) do
    mine = mine or utils.md5(path)
    if mine and utils.md5(f.path) == mine then return f.book end
  end
  return nil
end

--- Finds orphans. An action is keep; remove, the record; reattach, give the
-- record the file found for it; move, the stray file out of the library; add, the
-- stray file as a book; relink, the link to the file's place now; unlink, delete it.
-- @treturn table `{ records = { {book=, title=, authors=, verdict=, brief=, action=, actions=, stray=, twin=}, ... },
-- strays = { {path=, rel=, size=, verdict=, action=, actions=, twin=}, ... },
-- links = { {path=, rel=, target=, book=, to=, verdict=, action=, actions=}, ... },
-- empty = { path, ... }, root= }`
function M.scan()
  local root = assert(luv.fs_realpath(setman.get("path.library")))
  local known, has_file = {}, {}
  for _, f in ipairs(index_rows("SELECT book, path FROM files WHERE book > 0")) do
    known[f.path] = true
    if not has_file[f.book] and luv.fs_stat(f.path) then has_file[f.book] = true end
  end
  local on_disk, dangling, empty = walk(root, calibre_folders())
  local strays, by_book_dir = {}, {}
  for _, path in ipairs(on_disk) do
    if not known[path] then
      local st = luv.fs_stat(path)
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
  local with_file, missing = {}, {}
  for _, id in ipairs(bookman.ids("in:library")) do
    local b = { id = id, title = bookman.get(id, "title") or "", authors = bookman.get(id, "authors") or "" }
    if has_file[id] then
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
  for _, b in ipairs(missing) do
    local r = { book = b.id, title = b.title, authors = b.authors }
    local mine = by_book_dir[b.id]
    if mine and #mine == 1 then
      r.stray = mine[1]
      mine[1].claimed = b.id
      r.verdict = "its file is at " .. mine[1].rel
      r.brief = "its file is on disk"
      r.action, r.actions = "reattach", { "reattach", "keep", "remove" }
    else
      -- another book with the same title and author is the same work; with
      -- the same title and no author to compare it only might be
      local maybe
      for _, other in ipairs(with_file[norm(b.title)] or {}) do
        if b.authors == "" or other.authors == "" then
          maybe = maybe or other
        elseif expr.fold(b.authors) == expr.fold(other.authors) then
          r.twin = r.twin or other.id
        end
      end
      if r.twin then
        r.verdict = ("book %d is the same work and has its file"):format(r.twin)
        r.brief = ("same work as book %d"):format(r.twin)
        r.action = "remove"
      elseif maybe then
        r.twin = maybe.id
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
  local loose = {}
  for _, s in ipairs(strays) do
    if not s.claimed then
      loose[#loose + 1] = s
      s.twin = M.twin(s.path)
      if s.twin then
        s.verdict = ("identical to book %d's file"):format(s.twin)
        s.action = "move"
      else
        s.verdict = "not in calibre"
        s.action = "keep"
      end
      s.actions = { "keep", "move", "add" }
    end
  end
  return { records = records, strays = loose, links = describe_links(root, dangling), empty = empty, root = root }
end

--- How many of each action a scan holds now.
function M.counts(found)
  local n = { keep = 0, remove = 0, reattach = 0, move = 0, add = 0, relink = 0, unlink = 0 }
  for _, list in ipairs { found.records, found.strays, found.links } do
    for _, r in ipairs(list) do n[r.action] = n[r.action] + 1 end
  end
  return n
end

-- A file out of the library into the holding folder, keeping its path below the
-- library so it can be put back by hand.
local function set_aside(path, rel, holding)
  local to = holding .. "/" .. rel
  local at = ""
  for part in to:match("^(.*)/[^/]*$"):gmatch("[^/]+") do
    at = at .. "/" .. part
    luv.fs_mkdir(at, 493)
  end
  local ok, err = luv.fs_rename(path, to)
  if not ok then -- another filesystem: copy, then delete
    ok, err = luv.fs_copyfile(path, to)
    if ok then ok, err = luv.fs_unlink(path) end
  end
  if not ok then return nil, err end
  luv.fs_rmdir(path:match("^(.*)/[^/]*$")) -- only succeeds if that left it empty
  return to
end

--- Carries out the chosen actions, and waits.
-- @tparam table found `scan`'s, with the actions chosen
-- @treturn table `{ reattached=, removed=, moved=, added=, relinked=, unlinked=, failed = { "what: why", ... }, holding= }`
function M.apply(found)
  local out = { reattached = 0, removed = 0, moved = 0, added = 0, relinked = 0, unlinked = 0, failed = {} }
  if store.holder() == "program" then
    table.insert(out.failed, "calibre's program has the library open: close it first")
    return out
  end
  local holding = ("%s/orphans/%s"):format(setman.get("path.indexdb"):gsub("/[^/]*$", ""), os.date("%Y%m%d-%H%M%S"))
  local function aside(s)
    local to, err = set_aside(s.path, s.rel, holding)
    if to then out.holding = holding else table.insert(out.failed, s.rel .. ": " .. tostring(err)) end
    return to
  end
  local remove = {}
  for _, r in ipairs(found.records) do
    if r.action == "reattach" and r.stray then
      uiman.progress(("giving book %d its file"):format(r.book))
      local b, why = store.command({ "add_format", tostring(r.book), r.stray.path }, { label = "orphans", when = "any" })
      if b then
        out.reattached = out.reattached + 1
        aside(r.stray) -- calibre has stored its own copy
      else
        table.insert(out.failed, ("book %d: %s"):format(r.book, tostring(why)))
      end
    elseif r.action == "remove" then
      remove[#remove + 1] = r.book
    end
  end
  for _, s in ipairs(found.strays) do
    if s.action == "add" then
      uiman.progress("adding " .. s.rel)
      local b, printed = store.command({ "add", "--duplicates", s.path }, { label = "orphans", when = "any" })
      local id = b and tonumber((printed or ""):match("Added book ids:%s*(%d+)"))
      if id then
        store.note(b, id, "(added)", s.path, "", "orphans")
        store.command_undo(b, { "remove", tostring(id) })
        out.added = out.added + 1
        aside(s)
      else
        table.insert(out.failed, s.rel .. ": " .. tostring(printed))
      end
    elseif s.action == "move" then
      if aside(s) then out.moved = out.moved + 1 end
    end
  end
  for _, l in ipairs(found.links) do
    if l.action == "relink" or l.action == "unlink" then
      local ok, err = luv.fs_unlink(l.path)
      if ok and l.action == "relink" then ok, err = luv.fs_symlink(l.to, l.path) end
      if not ok then table.insert(out.failed, l.rel .. ": " .. tostring(err))
      elseif l.action == "relink" then out.relinked = out.relinked + 1
      else out.unlinked = out.unlinked + 1 end
    end
  end
  uiman.progress(nil)
  if #remove > 0 then
    local n, err = require("lulib._remove").remove(remove, { label = "orphans" })
    out.removed = n
    if err then table.insert(out.failed, err) end
  elseif out.reattached + out.added > 0 then
    store.reload()
  end
  return out
end

--- One line about what `apply` did.
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

scrnman.create("orphans", {
  actions = {
    { "action", "<Space>", "change what will be done about this row; on a heading, about every row under it" },
    { "expand", "x", "show the row in full: the verdict, the whole path" },
    { "expand_all", "X", "show, or hide, every row in full" },
    { "mark", "m", "mark the records set to be removed" },
    { "filter", "f", "narrow the list to books whose file is missing" },
    { "take", "t", "propose this record's values for the book that has the file" },
    { "edit", "e", "open the edit form for the row's book" },
    { "review", "r", "the review, for the row's book" },
    { "write", "w", "carry out the actions" },
  },
  hint = { "action", "expand", "edit", "write" },
})

local SIGN = { keep = "", remove = "×", reattach = "↩", move = "→", add = "+", relink = "↩", unlink = "×" }
local WORD = { keep = "keep", remove = "remove record", reattach = "re-attach file", move = "move out", add = "add as book",
               relink = "repair link", unlink = "delete link" }

--- Opens the screen, and returns when it closes.
function M.open()
  local found = M.scan()
  if #found.records + #found.strays + #found.links + #found.empty == 0 then
    return uiman.notify("no orphans: every record has its file and every file has its record")
  end
  local human = require("lulib._dupes").human
  local at, section, open = {}, {}, {}
  local function build()
    local rows = {}
    at, section = {}, {}
    local function head(text, id, items)
      rows[#rows + 1] = { text, id = id, style = "head" }
      section[#rows] = items
    end
    local function details(item, id, lines)
      if not open[item] then return end
      for _, line in ipairs(lines) do
        if line and line ~= "" then
          rows[#rows + 1] = { "      " .. line, id = id, style = "note" }
          at[#rows] = item
        end
      end
    end
    if #found.records > 0 then
      head(("Records with no file  (%d)"):format(#found.records), found.records[1].book, found.records)
      for _, r in ipairs(found.records) do
        rows[#rows + 1] = { SIGN[r.action], WORD[r.action], tostring(r.book), r.title, r.authors, r.brief or r.verdict, id = r.book,
                            style = r.action == "remove" and "warn" or (r.action == "reattach" and "ok" or nil) }
        at[#rows] = r
        details(r, r.book, { r.title .. (r.authors ~= "" and "  —  " .. r.authors or ""), r.verdict })
      end
    end
    if #found.strays > 0 then
      head(("Files with no record  (%d)"):format(#found.strays), nil, found.strays)
      for _, s in ipairs(found.strays) do
        rows[#rows + 1] = { SIGN[s.action], WORD[s.action], "", s.rel, human(s.size), s.verdict, id = s.twin,
                            style = s.action == "move" and "warn" or (s.action == "add" and "ok" or nil) }
        at[#rows] = s
        details(s, s.twin, { s.rel, s.verdict })
      end
    end
    if #found.links > 0 then
      head(("Links that lead nowhere  (%d)"):format(#found.links), found.links[1].book, found.links)
      for _, l in ipairs(found.links) do
        rows[#rows + 1] = { SIGN[l.action], WORD[l.action], tostring(l.book or ""), l.rel, "", l.verdict, id = l.book,
                            style = l.action == "relink" and "ok" or (l.action == "unlink" and "warn" or nil) }
        at[#rows] = l
        details(l, l.book, { l.rel, "points at  " .. l.target, l.to and ("would point at  " .. l.to), l.verdict })
      end
    end
    if #found.empty > 0 then
      head(("Empty folders  (%d)   left alone"):format(#found.empty))
      for _, dir in ipairs(found.empty) do
        rows[#rows + 1] = { "", "", "", dir:sub(#found.root + 2), "", "", style = "dim" }
      end
    end
    return rows
  end
  local function title()
    local n, todo = M.counts(found), {}
    for _, a in ipairs { "reattach", "remove", "move", "add", "relink", "unlink" } do
      if n[a] > 0 then todo[#todo + 1] = ("%d %s"):format(n[a], WORD[a]) end
    end
    return "orphans  " .. (#todo > 0 and table.concat(todo, ", ") or "nothing to do as it stands")
  end
  local p <close> = uiman.panel {
    title = title(), screen = "orphans", follow = true, reloads = true,
    columns = { { "", 1 }, { "Action", 14 }, { "Id", 6 }, { "Title or file", -3 }, { "Authors", -2 }, { "Verdict", -3 } },
    rows = build(),
  }
  p:cursor(2)
  local function next_action(item, to)
    local i = 1
    for k, a in ipairs(item.actions) do
      if a == item.action then i = k end
    end
    item.action = to or item.actions[i % #item.actions + 1]
  end
  while true do
    local act, row = p:wait()
    if not act then return end
    local item = at[row]
    local id = item and (item.book or item.twin)
    if act == "<Reload>" then
      for i = #found.records, 1, -1 do
        if not bookman.get(found.records[i].book) then table.remove(found.records, i) end
      end
    elseif act == "take" then
      local to = item and item.title and item.twin
      if not to then
        uiman.notify("this works on a record with no file that has a copy in the library to give its values to")
      else
        local n = require("lulib._dupes").pull(item.book, to, { all = true })
        uiman.notify(n == 0 and ("book %d says nothing that book %d does not"):format(item.book, to)
                     or ("%d proposal%s for book %d: :review shows them"):format(n, n == 1 and "" or "s", to))
      end
    elseif act == "edit" or act == "review" then
      if not id or not bookman.get(id) then
        uiman.notify("this row has no book in the library to " .. act)
      elseif act == "edit" then
        uiman.jump(id)
        uiman.exec("edit")
      else
        require("lulib._review").open { id }
      end
    elseif section[row] and act == "action" then
      local items = section[row]
      local first, i = items[1], 1
      for k, a in ipairs(first.actions) do
        if a == first.action then i = k end
      end
      local to, n = first.actions[i % #first.actions + 1], 0
      for _, it in ipairs(items) do
        for _, a in ipairs(it.actions) do
          if a == to then
            it.action, n = to, n + 1
            break
          end
        end
      end
      uiman.notify(("%d of %d rows set to %s"):format(n, #items, WORD[to] or to))
    elseif item and act == "action" then
      next_action(item)
    elseif item and act == "expand" then
      open[item] = not open[item] or nil
    elseif act == "expand_all" then
      local any = next(open) ~= nil
      open = {}
      if not any then
        for _, list in ipairs { found.records, found.strays, found.links } do
          for _, it in ipairs(list) do open[it] = true end
        end
      end
    elseif act == "mark" then
      local n = 0
      for _, r in ipairs(found.records) do
        if r.action == "remove" then
          uiman.mark(r.book, true)
          n = n + 1
        end
      end
      uiman.notify(("marked the %d records set to be removed"):format(n))
    elseif act == "filter" then
      uiman.filter("is:missing")
    elseif act == "write" then
      local n, parts = M.counts(found), {}
      if n.reattach > 0 then parts[#parts + 1] = ("give %d records their files back"):format(n.reattach) end
      if n.remove > 0 then parts[#parts + 1] = ("remove %d records (to calibre's recycle bin)"):format(n.remove) end
      if n.add > 0 then parts[#parts + 1] = ("add %d files as books"):format(n.add) end
      if n.move > 0 then parts[#parts + 1] = ("move %d stray files out of the library"):format(n.move) end
      if n.relink > 0 then parts[#parts + 1] = ("repair %d links"):format(n.relink) end
      if n.unlink > 0 then parts[#parts + 1] = ("delete %d links"):format(n.unlink) end
      if #parts == 0 then
        uiman.notify("every row is set to keep; Space changes a row's action")
      else
        local answer = uiman.input { prompt = table.concat(parts, ", ") .. "? (y/N) " }
        if answer and answer:lower():sub(1, 1) == "y" then
          for _, r in ipairs(found.records) do
            if r.action == "remove" and r.twin then require("lulib._dupes").pull(r.book, r.twin) end
          end
          local out = M.apply(found)
          uiman.notify(M.summary(out), #out.failed > 0 and "error" or nil)
          return
        end
      end
    end
    p:rows(build())
    p:title(title())
  end
end

return M
