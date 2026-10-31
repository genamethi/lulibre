--- The packaged commands (design 12): each a module function run as a
-- task, called through the module's table, so a redefinition in init.lua
-- takes effect (design 6).
--
-- @library cmd
local bookman = require "bookman"
local iter = require "iter"
local propose = require "lulib._propose"
local review = require "lulib._review"
local verify = require "lulib._verify"

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

--- :review [deep] [filter]: the current review, or its proposals for the
-- books; deep shows what it otherwise doesn't.
function M.review(ids, o)
  review.open(ids, o)
end

--- :verify [filter]: the books' records held against their files.
function M.verify(ids)
  verify.open(ids)
end

-- a command's leading word, if it is that word, and the command with it gone
local function flagged(o, word)
  local args = o.args or ""
  local rest = args:match("^" .. word .. "%s+(.*)$") or (args == word and "")
  return rest ~= nil and rest ~= false and true or false, { args = rest or args, selection = o.selection }
end

-- a rewrite over the books; says how many proposals it made
local function rewritten(name, ids, o)
  local n = require("lulib._rewrites").run(name, ids, o)
  uiman.notify(("%d proposal%s in the review: :review shows %s"):format(n, n == 1 and "" or "s", n == 1 and "it" or "them"))
  return n
end

--- :titlecase [all] [filter]: titles in capitals, or with all any title, in
-- title case, as proposals.
function M.titlecase(ids, o) return rewritten("titlecase", ids, o) end
--- :notation [filter]: titles with their mathematics in Unicode, as proposals.
function M.notation(ids) return rewritten("notation", ids) end
--- :split-authors [filter]: one "author" that is several people, as proposals.
function M.split_authors(ids) return rewritten("split-authors", ids) end
--- :normalize-tags [filter]: tags under their canonical name, as proposals.
function M.normalize_tags(ids) return rewritten("normalize-tags", ids) end

--- :clear FIELDS [filter]: blank fields, as proposals.
function M.clear(fields, ids)
  local n, err = require("lulib._rewrites").clear(fields, ids)
  if not n then return uiman.notify(err, "error") end
  uiman.notify(("%d proposal%s in the review"):format(n, n == 1 and "" or "s"))
  return n
end

--- :junk [filter]: marks and lists the books whose title or authors are
-- plainly not one (a file's name, a number, a program's name).
function M.junk(ids)
  local junk, names = require "lulib._junk", require "lulib._names"
  uiman.exec("mark none")
  local n = 0
  for _, id in ipairs(ids) do
    local title, authors = bookman.get(id, "title") or "", bookman.get(id, "authors") or ""
    local bad = title == "" or junk.unlikely_title(title)
    if not bad and authors ~= "" then
      bad = true
      for a in (authors .. " & "):gmatch("(.-) & ") do
        if not (junk.author(a) or names.never(a) or a:find("%.%a%a%a?$") or a:find("%d%d")) then bad = false end
      end
    end
    if bad then
      uiman.mark(id, true)
      n = n + 1
    end
  end
  if n > 0 then uiman.filter("is:marked") end
  uiman.notify(n == 0 and "no title or author of these books looks like junk"
               or ("marked %d books whose title or author is not one; :propose proposes for them"):format(n))
  return n
end

--- :enrich [filter]: ask the online services about the books, by their
-- identifiers; each new answer posts "source_arrived", which proposes for
-- the book again.
function M.enrich(ids, o)
  local net = require "net"
  local books, answers = net.enrich_many(ids, o)
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
  if not lulib.headless then return require("lulib._dupes").open(groups) end
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
  if o and o.write then
    local orphans = require "lulib._orphans"
    local out = orphans.apply(orphans.scan())
    return uiman.notify(orphans.summary(out), #out.failed > 0 and "error" or nil)
  end
  if not lulib.headless then return require("lulib._orphans").open() end
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
  if c.args == "ls" then say(orphan_rows(M.orphans { ls = true })) else M.orphans { write = c.args == "write" } end
end, { desc = "[ls | write]  files a record names that are not on disk, files no record names, links, empty folders; ls prints them; write does what is suggested", complete = { "ls", "write" } })
cmdman.create("tags", function(c)
  if c.args == "ls" then say(tag_rows(M.tags { ls = true })) else M.tags { write = c.args == "write" } end
end, { desc = "[ls | write]  tags whose levels are split with \"/\", as calibre writes levels, with \".\"; write rewrites them", complete = { "ls", "write" } })
cmdman.create("enrich", function(o)
  local titles, rest = flagged(o, "titles")
  local offline, rest2 = flagged(rest, "offline")
  M.enrich(M.books(rest2), { titles = titles, offline = offline })
end, { desc = "[titles] [offline] [filter]  ask the online services about the books, by their identifiers", complete = "filter" })
cmdman.create("propose", function(o) M.propose(M.books(o)) end, { desc = "[filter]  propose metadata from the files, for :review", complete = "filter" })
cmdman.create("titlecase", function(o)
  local all, rest = flagged(o, "all")
  M.titlecase(M.books(rest), { all = all })
end, { desc = "[all] [filter]  propose titles in CAPITALS, or with all any title, in title case", complete = "filter" })
cmdman.create("notation", function(o) M.notation(M.books(o)) end, { desc = "[filter]  propose titles with their mathematics in Unicode (SL₂(ℤ))", complete = "filter" })
cmdman.create("split-authors", function(o) M.split_authors(M.books(o, "is:listauthor")) end, { desc = "[filter]  propose author lists where one author is several people", complete = "filter" })
cmdman.create("normalize-tags", function(o) M.normalize_tags(M.books(o, "")) end, { desc = "[filter]  propose tags under their canonical names", complete = "filter" })
cmdman.create("clear", function(o)
  local fields, rest = (o.args or ""):match("^(%S*)%s*(.*)$")
  M.clear(fields, M.books { args = rest, selection = o.selection })
end, { desc = "FIELDS [filter]  propose blanking fields (title authors tags identifiers pubdate publisher series, or t a s i d p e)" })
cmdman.create("junk", function(o) M.junk(M.books(o, "")) end, { desc = "[filter]  mark and list the books whose title or author is plainly not one", complete = "filter" })
cmdman.create("capture", function(o) require("lulib._capture").open(o.selection or {}, (o.args or "") ~= "" and o.args or nil) end,
  { desc = "[pattern]  pull fields out of the selected books with a pattern, and propose them" })
cmdman.create("sync", function(o)
  local sync = require "lulib._sync"
  local verb, rest = (o.args or ""):match("^(%a+)%s*(.*)$")
  if verb ~= "add" and verb ~= "move" and verb ~= "drop" then
    return require("lulib._dialogs").sync(M.books(o))
  end
  local ids = M.books({ args = rest ~= "" and "in:sync " .. rest or "", selection = o.selection })
  if verb == "drop" then
    local out = sync.drop(ids)
    uiman.notify(#out.failed > 0 and out.failed[1] or ("dropped %d; :undo puts them back"):format(out.dropped),
                 #out.failed > 0 and "error" or nil)
  else
    local out = sync.add(ids, { remove = verb == "move" })
    uiman.notify(sync.summary(out), #out.failed > 0 and "error" or nil)
  end
end, { desc = "[add | move | drop] [filter]  the sync folder's files: add the selection; add and take them out; drop without adding. Alone, a dialog", complete = { "add", "move", "drop" } })
cmdman.create("beside", function() require("lulib._beside").open() end, { desc = "the sync folder beside the library" })
cmdman.create("onboard", function(o)
  if (o.args or "") == "" then return uiman.notify("give the folder", "error") end
  local dir = o.args:gsub("^~", os.getenv("HOME") or "~")
  setman.set("path.sync", dir)
  require("store").reload()
  uiman.exec("source sync")
  uiman.notify(("%s is the sync folder for now: :sync adds its files, :propose proposes for them"):format(dir))
end, { desc = "DIR  take a folder as the sync folder for now, to bring its ebook files in" })
cmdman.create("change", function(o) require("lulib._dialogs").change(M.books(o)) end, { desc = "[filter]  one change to every selected book" })
cmdman.create("enrich-dialog", function(o) require("lulib._dialogs").enrich(M.books(o)) end, { desc = "[filter]  say what :enrich would ask, choose the services, then review", complete = "filter" })
cmdman.create("propose-review", function(o) require("lulib._dialogs").propose_review(M.books(o)) end, { desc = "a dialog for a whole round: which books, what to ask, which fields, then review" })
cmdman.create("browse", function(o) require("lulib._browse").open((o.args or "") ~= "" and o.args or nil) end,
  { desc = "[author | subject | series | publisher | year | format]  the library as a tree", complete = { "author", "subject", "series", "publisher", "year", "format" } })
cmdman.create("yank", function(o)
  local what = (o.args or "") ~= "" and o.args or "title"
  if what ~= "title" and what ~= "path" then return uiman.notify("yank path | title", "error") end
  local out = {}
  for _, id in ipairs(o.selection or {}) do
    if what == "path" then
      local f = (bookman.files(id) or {})[1]
      if f then out[#out + 1] = f.path end
    else
      out[#out + 1] = bookman.get(id, "title") or ""
    end
  end
  if uiman.clipboard(table.concat(out, "\n")) then
    uiman.notify(("copied %s for %d book%s"):format(what, #out, #out == 1 and "" or "s"))
  else
    uiman.notify("could not reach the terminal to copy", "error")
  end
end, { desc = "path | title  copy for the selection to the clipboard", complete = { "path", "title" } })
cmdman.create("addpages", function(o)
  local id, page = (o.args or ""):match("^(%-?%d+)%s+(%d+)$")
  if not id then return uiman.notify("addpages BOOK PAGE", "error") end
  uiman.progress(("reading book %s as far as page %s"):format(id, page))
  local r, err = utils.index { filter = (tonumber(id) < 0 and "in:sync " or "") .. "id:" .. math.abs(tonumber(id)),
                               pages = tonumber(page), force = true }
  uiman.progress(nil)
  if not r then return uiman.notify(err, "error") end
  uiman.notify(r.failed and r.failed > 0 and "the file could not be read" or ("read as far as page %s"):format(page))
end, { desc = "BOOK PAGE  read a file as far as that page (the preview's a does it for the page being shown)" })
cmdman.create("features", function()
  local features = {
    { "calibredb", "calibredb", "writing to the library" },
    { "calibre-server", "calibre-server", "the content server, through which writes reach an open library" },
    { "tesseract", "tesseract", "OCR: reading files with no text (the setting ocr)" },
    { "systemctl", "systemctl", ":units, lulibre's systemd units around the content server" },
    { "xdg-open", "xdg-open", "opening files in other programs" },
  }
  local out = {}
  for _, f in ipairs(features) do
    local found
    for dir in (os.getenv("PATH") or ""):gmatch("[^:]+") do
      local h = io.open(dir .. "/" .. f[2])
      if h then
        h:close()
        found = true
        break
      end
    end
    out[#out + 1] = ("%-15s %-10s %s"):format(f[1], found and "installed" or "missing", f[3])
  end
  uiman.pager("features and the programs they need", table.concat(out, "\n"))
end, { desc = "the features that need programs of their own: installed or not" })
cmdman.create("remove", function(o)
  local ids = M.books(o)
  if #ids == 0 then return end
  local what = #ids == 1 and ("book %d, %s,"):format(ids[1], bookman.get(ids[1], "title") or "?") or ("%d books"):format(#ids)
  local answer = uiman.input { prompt = ("remove %s from calibre? to its recycle bin (y/N) "):format(what) }
  if not (answer and answer:lower():sub(1, 1) == "y") then return end
  local n, err = require("lulib._remove").remove(ids)
  for _, id in ipairs(ids) do uiman.mark(id, false) end
  uiman.notify(err and ("removed %d, then: %s"):format(n, err) or ("removed %d book%s: :undo puts them back"):format(n, n == 1 and "" or "s"),
               err and "error" or nil)
end, { desc = "[filter]  remove the selected books from calibre, to its recycle bin; :undo puts them back", complete = "filter" })
cmdman.create("restore-removed", function(o)
  local new, why = require("lulib._remove").restore(tonumber(o.args))
  uiman.notify(why and ("%d back, then: %s"):format(#new, why) or ("%d book%s back"):format(#new, #new == 1 and "" or "s"),
               why and "error" or nil)
end, { desc = "BATCH  bring back the books a batch removed (what :undo does for it)" })
cmdman.create("embed", function(o)
  local ids = M.books(o)
  if #ids == 0 then return end
  local answer = uiman.input { prompt = ("write calibre's metadata into the files of %d book%s? this rewrites the files (y/N) "):format(#ids, #ids == 1 and "" or "s") }
  if not (answer and answer:lower():sub(1, 1) == "y") then return end
  local args = { "embed_metadata" }
  for _, id in ipairs(ids) do args[#args + 1] = tostring(id) end
  uiman.progress("embedding")
  local b, printed = require("store").command(args, { label = "embed", when = "any" })
  uiman.progress(nil)
  if b then require("store").reload() end
  uiman.notify(b and ("metadata embedded in %d book%s"):format(#ids, #ids == 1 and "" or "s") or tostring(printed), not b and "error" or nil)
end, { desc = "[filter]  write calibre's metadata into the selected books' own files (PDF, EPUB)", complete = "filter" })
cmdman.create("columns", function(o) require("lulib._columns").run(o.args or "") end,
  { desc = "[push | remove]  calibre columns for lulibre's own fields, #partof, #part and #parts; push copies lulibre's values into them", complete = { "push", "remove" } })
cmdman.create("offline", function(o)
  local offline = require "lulib._offline"
  local verb, rest = (o.args or ""):match("^(%a*)%s*(.*)$")
  if verb == "cancel" then
    local batch, err = offline.cancel(tonumber(rest) or 0)
    return uiman.notify(batch and ("job %s cancelled"):format(rest) or tostring(err), not batch and "error" or nil)
  elseif verb == "retry" then
    return uiman.notify(("%d tried again"):format(offline.retry()))
  elseif verb == "restart" then
    local left, why = offline.restart()
    return uiman.notify(left and (left == 0 and "done, and the server started again" or ("%d still wait"):format(left)) or why, not left and "error" or nil)
  end
  local rows = offline.rows()
  if #rows == 0 then rows[1] = { "", "", "", "nothing waits for the library to be closed", "", "" } end
  uiman.list { title = "waiting for nothing to hold the library", items = rows,
               columns = { { "Job", 6 }, { "State", 8 }, { "Since", 16 }, { "What", -1 }, { "Runs", -2 }, { "Why", -2 } } }
end, { desc = "[cancel JOB | retry | restart]  the changes waiting for nothing to hold the library; restart stops the content server for them", complete = { "cancel", "retry", "restart" } })
cmdman.create("history", function() require("lulib._history").open() end, { desc = "what lulibre changed, and what changed outside it, newest first; u puts a batch back" })
cmdman.create("snapshots", function() require("lulib._snapshots").open() end, { desc = "the snapshots: what going back to each would do; go back, take, retire" })
cmdman.create("snapshot", function(o)
  local snapshots = require "lulib._snapshots"
  local words, flags = {}, {}
  for w in (o.args or ""):gmatch("%S+") do
    if w == "exact" or w == "unsync" or w == "fields" or w == "all" then flags[w] = true else words[#words + 1] = w end
  end
  local verbs = { take = 1, list = 1, plan = 1, rollback = 1, retire = 1, unretire = 1, import = 1 }
  local verb = verbs[words[1] or ""] and table.remove(words, 1) or "take"
  local rest = table.concat(words, " ")
  local function find()
    local snap, why = snapshots.find(rest)
    if not snap then uiman.notify(why, "error") end
    return snap
  end
  if verb == "take" then
    local snap = snapshots.take(rest)
    uiman.notify(("took snapshot %d, \"%s\""):format(snap.id, snap.name))
  elseif verb == "list" then
    local out = {}
    for _, s in ipairs(snapshots.list(flags)) do
      out[#out + 1] = ("%4d  %s  %-44s %5d changes on %d books since%s%s"):format(s.id, os.date("%Y-%m-%d %H:%M", s.ts), s.name:sub(1, 44),
        s.changes, s.books, s.auto == 1 and "  (taken by a rollback)" or "", s.retired and "  retired" or "")
    end
    uiman.pager("snapshots", #out > 0 and table.concat(out, "\n") or "no snapshots yet: :snapshot NAME takes one")
  elseif verb == "plan" then
    local snap = find()
    if snap then uiman.pager("going back to a snapshot (nothing has been changed)", table.concat(snapshots.describe(snapshots.plan(snap, flags)), "\n")) end
  elseif verb == "rollback" then
    local snap = find()
    if not snap then return end
    local plan = snapshots.plan(snap, flags)
    if plan.books == 0 then return uiman.notify("the library is as it was then: nothing to do") end
    local answer = uiman.input { prompt = table.concat(snapshots.describe(plan), ";"):sub(1, 200) .. "  go back? (y/N) " }
    if answer and answer:lower():sub(1, 1) == "y" then
      local out = snapshots.rollback(snap, flags)
      uiman.notify(snapshots.summary(out), #out.failed > 0 and "error" or nil)
    end
  elseif verb == "retire" or verb == "unretire" then
    local snap = find()
    if snap then
      snapshots.retire(snap.id, verb == "retire")
      uiman.notify(("snapshot %d, \"%s\", %s"):format(snap.id, snap.name, verb == "retire" and "retired" or "back in the list"))
    end
  elseif verb == "import" then
    local path = table.remove(words, 1)
    if not path then return uiman.notify("snapshot import takes a copy of calibre's metadata.db", "error") end
    local snap, n = snapshots.import(path, #words > 0 and table.concat(words, " ") or nil)
    if not snap then return uiman.notify(n, "error") end
    uiman.notify(("snapshot %d, \"%s\": %d books, %d values the journal did not see"):format(snap.id, snap.name, n.books, n.values))
  end
end, { desc = "[take] NAME | list | plan SNAP | rollback SNAP | retire SNAP | unretire SNAP | import FILE [NAME]; exact, unsync, fields: how to go back", complete = { "take", "list", "plan", "rollback", "retire", "unretire", "import", "exact", "unsync", "fields", "all" } })
cmdman.create("rollback", function(o) uiman.exec("snapshot rollback " .. (o.args or "")) end, { desc = "SNAP [exact | unsync | fields]  put the library back to a snapshot (shows what it will do, then asks)" })
cmdman.create("datasets", function(o)
  local datasets = require "lulib._datasets"
  local verb, rest = (o.args or ""):match("^(%a*)%s*(.*)$")
  if verb == "list" then
    local out = {}
    for _, ds in ipairs(datasets.list) do
      out[#out + 1] = ("%-12s %s  [%s]\n    %s\n    %s; from %s."):format(ds.name, ds.title, datasets.state(ds), ds.useful, ds.size, ds.from)
    end
    return uiman.pager("datasets, kept in " .. datasets.dir(), table.concat(out, "\n\n"))
  elseif verb == "fetch" then
    local force = false
    for name in rest:gmatch("%S+") do
      if name == "force" then force = true end
    end
    for name in rest:gmatch("%S+") do
      if name ~= "force" then
        local ds = datasets.get(name)
        if not ds then return uiman.notify("no dataset is called " .. name, "error") end
        local ok, why = datasets.fetch(ds, { force = force, say = uiman.notify })
        if not ok then return uiman.notify(why, "error") end
      end
    end
    return
  elseif verb == "add" then
    for file in rest:gmatch("%S+") do
      local ds, name = datasets.adopt(file)
      if not ds then return uiman.notify(name, "error") end
      uiman.notify(("%s is %s's %s now"):format(file, ds.name, name))
    end
    return
  end
  require("lulib._dialogs").datasets()
end, { desc = "[list | fetch NAME... [force] | add FILE...]  databases for looking books up on this machine. Alone, a dialog", complete = { "list", "fetch", "add" } })
cmdman.create("arxiv-titles", function(o) require("net.datasets").arxiv_titles(M.books(o)) end, { desc = "[filter]  find books' arXiv numbers by their titles in arXiv's snapshot on this machine, as proposals", complete = "filter" })
cmdman.create("verify", function(o) M.verify(M.books(o, "")) end, { desc = "[filter]  the books' records held against their files; sends books to review", complete = "filter" })
cmdman.create("review", function(o)
  local deep, args = (o.args or ""):match("^(deep)%s*(.*)$")
  local given = { args = deep and args or o.args, selection = o.selection }
  M.review((given.args or "") ~= "" and M.books(given) or nil, { deep = deep ~= nil })
end, { desc = "[deep] [filter | selection]  the current review, or its proposals for those books: accept, edit, reject, then write", complete = "filter" })

return M
