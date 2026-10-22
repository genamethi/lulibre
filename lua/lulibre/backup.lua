--- Makes, checks and restores copies of calibre's database.
-- A copy holds metadata.db and the preferences calibre keeps beside it, in
-- a folder under `~/.local/share/lulibre/backups/<the index's name>/`.
-- lulibre keeps the newest `backup_keep` copies, and checks each copy when
-- it makes the copy.
--
-- lulibre makes a copy before the content server starts (from
-- lulibre.service or `:offline restart`) if `backup_restart` says so, and
-- whenever you ask. `restore` puts a copy back once nothing has the library
-- open.
--
-- @library lulibre.backup
-- @usage
-- local backup = require "lulibre.backup"
-- local b = backup.take("before rebuilding")  --> { path=, ts=, check= }
-- backup.list()[1]                            --> the newest
-- backup.check()                              --> true, or false and the problems
-- backup.describe(b, backup.compare(b))       --> what putting it back would change
local M = {}

local uv = require "luv"
local json = require "lulibre.json"

local FILES = { "metadata.db", "metadata_db_prefs_backup.json" }
local ABOUT = "about.json"

local function live()
  if lulibre.o.library == "" then error("no library (lulibre.o.library)", 0) end
  return lulibre.o.library .. "/metadata.db"
end

local function exists(path)
  return uv.fs_stat(path) ~= nil
end

-- A file removed when the variable holding this goes out of scope, however
-- it goes (an error, or the task cancelled while it waits).
local function removed_after(path)
  return setmetatable({}, { __close = function() uv.fs_unlink(path) end })
end

local function mkdirs(path)
  local at = ""
  for part in path:gmatch("[^/]+") do
    at = at .. "/" .. part
    if not exists(at) then
      local ok, err = uv.fs_mkdir(at, 448) -- 0700
      if not ok and not exists(at) then error(("cannot make %s: %s"):format(at, err), 0) end
    end
  end
end

--- Returns the folder that holds this library's copies.
-- @treturn string a folder
function M.dir()
  local p = lulibre.settings.paths()
  local name = (p.index or "index"):match("([^/]+)$"):gsub("%.db$", "")
  return ("%s/backups/%s"):format(p.data_dir, name)
end

local function read_about(dir)
  local f = io.open(dir .. "/" .. ABOUT)
  if not f then return nil end
  local ok, v = pcall(json.decode, f:read("a"))
  f:close()
  return ok and type(v) == "table" and v or nil
end

--- Returns the copies, newest first.
-- @treturn {table,...} each `{ path=, ts=, reason=, books=, check=, problems= }`
function M.list()
  local out, base = {}, M.dir()
  local h = uv.fs_scandir(base)
  if not h then return out end
  while true do
    local name, kind = uv.fs_scandir_next(h)
    if not name then break end
    if kind == "directory" and name:match("^%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d") then
      local about = read_about(base .. "/" .. name)
      if about and about.ts then
        out[#out + 1] = { path = base .. "/" .. name, ts = about.ts, reason = about.reason, books = about.books,
          check = about.check, problems = about.problems, raw = about.raw }
      end
    end
  end
  table.sort(out, function(a, b) return a.path > b.path end)
  return out
end

--- Returns the newest copy.
-- @treturn table|nil
function M.last()
  return M.list()[1]
end

--- Returns the age of the newest copy in days.
-- @treturn number|nil nil if there is no copy
function M.age()
  local l = M.last()
  return l and (os.time() - l.ts) / 86400 or nil
end

--- Returns true if there is no copy, or the newest is older than `days`.
-- @tparam[opt] number days `backup_max_age` if not given
-- @treturn boolean
function M.too_old(days)
  days = days or lulibre.o.backup_max_age
  local age = M.age()
  return age == nil or age > days
end

--- Copies calibre's database now, on a worker thread, and waits for the
-- copy. The server may be running: the copy is made with SQLite's backup,
-- so it is complete even if calibre writes during it. The copy is then
-- checked with `check`. Since the copy matches the database page for page,
-- a copy that fails the check means calibre's database fails it too.
-- @tparam string reason what the copy is for, as the list shows it
-- @tparam[opt] table opts `raw`: if SQLite cannot copy the database because it is
-- too damaged, copy its files as they are. `put_back` passes `raw`, with the server stopped.
-- @treturn table the copy, `{ path=, ts=, reason=, books=, check=, problems= }`; `check` is "ok" or "failed"
function M.take(reason, opts)
  opts = opts or {}
  live()
  local lib = lulibre.o.library
  local base = M.dir()
  mkdirs(base)
  local stamp = os.date("!%Y%m%d-%H%M%S")
  local dir, n = base .. "/" .. stamp, 1
  while exists(dir) do
    n = n + 1
    dir = ("%s/%s-%d"):format(base, stamp, n)
  end
  mkdirs(dir)
  local ok, err = lulibre.copy_db(lib .. "/metadata.db", dir .. "/metadata.db")
  local raw
  if not ok and opts.raw then
    for _, name in ipairs { "metadata.db", "metadata.db-journal" } do
      if exists(lib .. "/" .. name) then
        local copied, cerr = uv.fs_copyfile(lib .. "/" .. name, dir .. "/" .. name)
        if not copied then error(("backup: %s; and copying the file: %s"):format(err, cerr), 0) end
      end
    end
    ok, raw = true, err
  end
  if not ok then error("backup: " .. err, 0) end
  local prefs = lib .. "/" .. FILES[2]
  if exists(prefs) then uv.fs_copyfile(prefs, dir .. "/" .. FILES[2]) end
  local whole, problems = lulibre.check_db(dir .. "/metadata.db")
  if whole == nil then problems = { problems } end
  local ts = os.time()
  local books = lulibre.sql("SELECT count(*) AS n FROM books WHERE id > 0")[1].n
  local b = { path = dir, ts = ts, reason = reason, books = books, check = whole and "ok" or "failed",
    problems = problems and { table.unpack(problems, 1, math.min(#problems, 10)) } or nil, raw = raw }
  local f = assert(io.open(dir .. "/" .. ABOUT, "w"))
  f:write(json.encode { ts = ts, reason = reason, library = lib, books = books, check = b.check,
    problems = b.problems, raw = raw })
  f:close()
  M.prune()
  return b
end

--- Removes all but the newest `keep` copies.
-- Only a copy's own files are removed, so a folder that holds anything else
-- stays. Two copies are never removed:
--
-- - the newest copy that passed its check, if none of the newest `keep`
--   passed. So a damaged database copied again and again does not push out
--   the last good copy.
-- - a copy waiting to be put back.
-- @tparam[opt] integer keep `backup_keep` if not given
-- @treturn integer how many were removed
function M.prune(keep)
  keep = keep or lulibre.o.backup_keep
  local spare = {}
  for _, j in ipairs(require("lulibre.offline").jobs()) do
    if j.argv[1] == "restore_copy" then spare[j.argv[2]] = true end
  end
  local copies = M.list()
  for i, b in ipairs(copies) do
    if b.check == "ok" then
      if i > keep then spare[b.path] = true end
      break
    end
  end
  local gone = 0
  for i, b in ipairs(copies) do
    if i > keep and not spare[b.path] then
      for _, name in ipairs(FILES) do uv.fs_unlink(b.path .. "/" .. name) end
      uv.fs_unlink(b.path .. "/metadata.db-journal")
      uv.fs_unlink(b.path .. "/" .. ABOUT)
      if uv.fs_rmdir(b.path) then gone = gone + 1 end
    end
  end
  return gone
end

--- Returns the value of `backup_restart`.
-- @treturn string|number "always", "next", "never", or a number of days
function M.policy()
  local v = tostring(lulibre.o.backup_restart or "always")
  if v == "always" or v == "next" or v == "never" then return v end
  local days = tonumber(v)
  if days and days >= 0 then return days end
  error(("backup_restart is always, next, never or a number of days, not %q"):format(v), 0)
end

-- "next" is spent once a copy is made for it, until backup_restart is set
-- to next again: lulibre notes the value it last saw (in kv), so a change
-- to something else and back re-arms it, whether made here or in init.lua.
local function kv(key, value)
  if value == nil then
    local r = lulibre.store("SELECT value FROM kv WHERE key = ?", key)[1]
    return r and r.value
  end
  if value == false then return lulibre.store("DELETE FROM kv WHERE key = ?", key) end
  lulibre.store("INSERT OR REPLACE INTO kv(key, value) VALUES(?, ?)", key, value)
end

--- Records the value of `backup_restart`. Then "next" works again once the
-- option is set to something else and back to "next". lulibre calls
-- `observe` at each start.
function M.observe()
  local v = tostring(lulibre.o.backup_restart)
  if v == "next" and kv("backup:seen") ~= "next" then kv("backup:next_spent", false) end
  kv("backup:seen", v)
end

--- Returns true if the server's next start would make a copy.
-- @treturn boolean
function M.due()
  M.observe()
  local p = M.policy()
  if p == "never" then return false end
  if p == "always" then return true end
  if p == "next" then return kv("backup:next_spent") == nil end
  return M.too_old(p)
end

--- Sets `backup_restart`, for this session and in init.lua. Setting "next"
-- re-arms "next".
-- @tparam string|number value "always", "next", "never", or days
function M.set(value)
  lulibre.o.backup_restart = value
  M.policy() -- says so if it will not do
  if tostring(value) == "next" then kv("backup:next_spent", false) end
  kv("backup:seen", tostring(value))
  pcall(require("lulibre.config_file").write_value, { name = "backup_restart" }, value)
end

--- Makes a copy if one is due. Called before the server starts.
-- @treturn table|nil the copy
function M.on_restart()
  if not M.due() then return nil end
  local b = M.take("before the content server started")
  if M.policy() == "next" then kv("backup:next_spent", tostring(b.ts)) end
  return b
end

--- Has calibre write the metadata.opf of every book whose opf file is older
-- than its record (`calibredb backup_metadata`). calibre writes these files
-- only from its own program. Changes made through calibredb or the content
-- server only mark the book as needing a new opf file. The server must be stopped.
-- @treturn integer how many books' files were written
function M.metadata()
  require("lulibre.calibre").wait_for_program("writing the books' opf files")
  local r, err = lulibre.system({ "calibredb", "--with-library", lulibre.o.library, "backup_metadata" },
    { timeout = 3600000 })
  if not r or r.code ~= 0 then error("backup_metadata: " .. require("lulibre.offline").why(r, err), 0) end
  local n = 0
  for _ in r.stdout:gmatch("[^\n]*%%[^\n]*\n") do n = n + 1 end -- one progress line per book
  return n
end

--- Checks that calibre's database is intact, with SQLite's integrity check.
-- The check only reads, so the server may be running. calibre's writes wait
-- while the check runs, which is well under a second for a few thousand books.
-- @tparam[opt] string path a database; calibre's if not given
-- @treturn boolean
-- @treturn {string,...}|nil the problems SQLite found
function M.check(path)
  local ok, problems = lulibre.check_db(path or live())
  if ok == nil then error("integrity check: " .. problems, 0) end
  return ok, problems
end

--- Finds a copy by its place in `list` (1 is the newest) or by its folder's
-- name (20260101-120000, or enough of the start to match only one).
-- @tparam integer|string which
-- @treturn table|nil nil if no copy matches, or more than one does
function M.find(which)
  local copies, n = M.list(), tonumber(which)
  if n and n >= 1 and n <= #copies and math.type(n) == "integer" then return copies[n] end
  which = tostring(which)
  local found
  for _, b in ipairs(copies) do
    if b.path:match("([^/]+)$"):sub(1, #which) == which then
      if found then return nil end -- more than one
      found = b
    end
  end
  return found
end

local function by_id(rows)
  local out = {}
  for _, r in ipairs(rows) do out[r.id] = r end
  return out
end

-- What the database at then_path holds that the one at now_path does not,
-- book by book (both read only, through lulibre.calibre_books).
local function differ(then_path, now_path)
  local snapshots = require "lulibre.snapshots"
  local lib = lulibre.o.library
  local was, is = lulibre.calibre_books(then_path), lulibre.calibre_books(now_path)
  local now = by_id(is)
  local out = { books_then = #was, books_now = #is, back = {}, gone = {}, changed = {}, fields = {}, moved = {},
    unfitted = {}, missing = 0 }
  local seen = {}
  for _, t in ipairs(was) do
    local n = now[t.id]
    seen[t.id] = true
    if not n then
      local folder = exists(lib .. "/" .. t.path)
      local trash = not folder and exists(("%s/.caltrash/b/%d"):format(lib, t.id))
      out.back[#out.back + 1] = { id = t.id, title = t.title, authors = t.authors, folder = folder, trash = trash }
      if not folder then out.missing = out.missing + 1 end
      if trash then out.trash = (out.trash or 0) + 1 end
    else
      if t.modified ~= n.modified then
        local vt, vn, fields = snapshots.values(t), snapshots.values(n), {}
        for _, f in ipairs(snapshots.fields) do
          if vt[f] ~= nil and not snapshots.same(f, vt[f], vn[f]) then
            fields[#fields + 1] = f
            out.fields[f] = (out.fields[f] or 0) + 1
          end
        end
        if (t.formats or "") ~= (n.formats or "") then
          fields[#fields + 1] = "formats"
          out.fields.formats = (out.fields.formats or 0) + 1
        end
        out.changed[#out.changed + 1] = { id = t.id, title = t.title, now = n.title, fields = fields }
      end
      if t.path ~= n.path then
        -- calibre renamed the book's folder since (a new title or author):
        -- the copy's record names the old folder
        local m = { id = t.id, ["then"] = t.path, now = n.path }
        if not exists(lib .. "/" .. t.path) and exists(lib .. "/" .. n.path) then
          out.moved[#out.moved + 1] = m
        else
          out.unfitted[#out.unfitted + 1] = m
        end
      end
    end
  end
  for _, n in ipairs(is) do
    if not seen[n.id] then out.gone[#out.gone + 1] = { id = n.id, title = n.title, authors = n.authors } end
  end
  return out
end

-- a copy of calibre's database as it is now, beside the copies, for as
-- long as fn needs it
local function with_now(fn)
  mkdirs(M.dir())
  local tmp = ("%s/.now-%d-%d.db"):format(M.dir(), uv.os_getpid(), uv.hrtime())
  local _ <close> = removed_after(tmp)
  local ok, err = lulibre.copy_db(live(), tmp)
  if not ok then error("reading calibre's database: " .. err, 0) end
  return fn(tmp)
end

--- Returns what putting a copy back would change, compared with calibre's
-- database now. Writes nothing.
-- @tparam table b a copy (from `list` or `find`)
-- @treturn table with these fields:
--
-- - `books_then`, `books_now`: how many books the copy and the database have
-- - `back`: books removed since the copy, whose records would come back:
--   `{ {id=, title=, authors=, folder=, trash=}, ... }`. `folder` is true if
--   the book's folder still exists, and `trash` if calibre's trash has it.
-- - `missing`, `trash`: how many of those have no folder, and how many are
--   in calibre's trash
-- - `gone`: books added since the copy, whose records would go:
--   `{ {id=, title=, authors=}, ... }`. Their folders stay, for `:orphans`.
-- - `changed`: books changed since the copy, by calibre's last-modified time:
--   `{ {id=, title=, now=, fields={...}}, ... }`. `fields` names the
--   lulibre fields that differ. `fields` is empty for a book changed only in its
--   comments, custom columns or cover.
-- - `fields`: how many books differ in each field
-- - `moved`: folders calibre renamed since the copy: `{ {id=, then=, now=}, ... }`.
--   `put_back` points the records at the current folders.
-- - `unfitted`: folders renamed in a way that can't be followed
-- - `journal`: how many of the changes were made through lulibre
-- - `check`: "ok" or "failed", the result of checking the copy now
function M.compare(b)
  local whole = M.check(b.path .. "/metadata.db")
  local out = with_now(function(now) return differ(b.path .. "/metadata.db", now) end)
  out.check = whole and "ok" or "failed"
  out.journal = lulibre.sql("SELECT count(*) AS n FROM journal WHERE ts > ? AND status = 'applied'", b.ts)[1].n
  return out
end

--- Returns `compare`'s result as lines to show.
-- @tparam table b the copy
-- @tparam table d what `compare` returned
-- @treturn {string,...}
function M.describe(b, d)
  local function n(k, one, many) return k == 1 and one or (many):format(k) end
  local lines = {
    ("the copy of %s (%s): %d books then, %d now; its integrity: %s"):format(os.date("%Y-%m-%d %H:%M", b.ts),
      b.reason or "", d.books_then, d.books_now, d.check),
  }
  if #d.back > 0 then
    lines[#lines + 1] = "  " .. n(#d.back, "1 book removed since: its record comes back",
      "%d books removed since: their records come back")
      .. (d.missing > 0 and n(d.missing, ", 1 without its files", ", %d without their files") or "")
    if (d.trash or 0) > 0 then
      lines[#lines + 1] = "  " .. n(d.trash, "(calibre's trash has 1 of those: bring it back with calibre's program first, "
        .. "then put the copy back; calibre cannot once the copy has its record)",
        "(calibre's trash has %d of those: bring them back with calibre's program first, then put the copy back; "
        .. "calibre cannot once the copy has their records)")
    end
  end
  if #d.gone > 0 then
    lines[#lines + 1] = "  " .. n(#d.gone, "1 book added since: its record goes; its folder stays, for :orphans",
      "%d books added since: their records go; their folders stay, for :orphans")
  end
  if #d.changed > 0 then
    local fs = {}
    for f, k in pairs(d.fields) do fs[#fs + 1] = ("%s %d"):format(f, k) end
    table.sort(fs)
    lines[#lines + 1] = "  " .. n(#d.changed, "1 book changed since, back as it was", "%d books changed since, back as they were")
      .. (#fs > 0 and (": " .. table.concat(fs, ", ")) or "")
    if d.journal > 0 then
      lines[#lines + 1] = "  " .. n(d.journal, "(1 change made through lulibre since; :history has it)",
        "(%d changes made through lulibre since; :history has them)")
    end
  end
  if #d.moved > 0 then
    lines[#lines + 1] = "  " .. n(#d.moved, "1 book's folder renamed since: its record is pointed at the folder as it is",
      "%d books' folders renamed since: their records are pointed at the folders as they are")
  end
  if #d.unfitted > 0 then
    lines[#lines + 1] = "  " .. n(#d.unfitted,
      "1 book's folder renamed in a way that cannot be followed: its record names a folder that may not be there",
      "%d books' folders renamed in a way that cannot be followed: their records name folders that may not be there")
  end
  if #d.back + #d.gone + #d.changed == 0 then lines[#lines + 1] = "  no book differs" end
  return lines
end

--- Puts a copy back. The job is queued until nothing has the library open
-- (see `lulibre.offline`; `offline.ask` offers to run the job). The copy must
-- pass its check.
-- @tparam table b the copy
-- @treturn integer the job's id
function M.restore(b)
  if not M.check(b.path .. "/metadata.db") then
    error(("the copy of %s fails its integrity check: it is not put back"):format(os.date("%Y-%m-%d %H:%M", b.ts)), 0)
  end
  for _, j in ipairs(require("lulibre.offline").jobs()) do
    if j.argv[1] == "restore_copy" then error(("a copy waits to be put back already (offline job %d)"):format(j.id), 0) end
  end
  return require("lulibre.offline").queue({ "restore_copy", b.path },
    ("putting back the copy of %s"):format(os.date("%Y-%m-%d %H:%M", b.ts)))
end

-- fitting the copy to the library's folders as they are now (the copy is
-- staged; `now` is calibre's database as it was just before):
--   the books whose folder calibre renamed since: their record's path,
--   and their files' names (calibre renames those with the folder);
--   every book that differs: marked for its metadata.opf to be written
--   again (by calibre: the program, the server's launcher, backup_metadata);
--   ids: never one again that a book added since had (its folder, named
--   "Title (id)", stays)
-- No title changes and no book is added, so calibre's triggers that would
-- call its own title_sort() and uuid4() never do (copy_db's stubs).
local FIT = [[
UPDATE books SET path = (SELECT n.path FROM now.books n WHERE n.id = books.id)
 WHERE id IN (SELECT value FROM json_each(?1, '$.moved'));
UPDATE data SET name = (SELECT n.name FROM now.data n WHERE n.book = data.book AND n.format = data.format)
 WHERE book IN (SELECT value FROM json_each(?1, '$.moved'))
   AND EXISTS(SELECT 1 FROM now.data n WHERE n.book = data.book AND n.format = data.format);
INSERT OR IGNORE INTO metadata_dirtied(book)
 SELECT value FROM json_each(?1, '$.dirty') WHERE value IN (SELECT id FROM books);
UPDATE sqlite_sequence SET seq = max(seq, coalesce((SELECT n.seq FROM now.sqlite_sequence n
 WHERE n.name = sqlite_sequence.name), 0));
]]

--- Puts the copy in a folder back as calibre's database. Nothing may have
-- the library open, so `lulibre.offline` runs this as its job
-- `restore_copy`. calibre's current database is copied first and kept like
-- the other copies. Putting that copy back undoes the restore.
-- @tparam string path the copy's folder
-- @treturn table `{ before=, moved=, dirty=, unfitted=, how= }`
function M.put_back(path)
  local copy = path .. "/metadata.db"
  local whole = M.check(copy)
  if not whole then error("the copy fails its integrity check now: it is not put back", 0) end
  local calibre = require "lulibre.calibre"
  calibre.wait_for_program("putting a copy of calibre's database back")
  for _ = 1, 60 do -- a server that has just stopped lets go of the library a moment later
    local held = calibre.running()
    if not (held and held.db) then break end
    lulibre.sleep(500)
  end
  local held = calibre.running()
  if held and held.db then error("a calibre program has the library open: nothing was put back", 0) end
  local before = M.take(("before putting back the copy of %s"):format(path:match("([^/]+)$")), { raw = true })
  local staged = ("%s/.staged-%d.db"):format(M.dir(), uv.os_getpid())
  local _ <close> = removed_after(staged)
  local out = { before = before, moved = 0, dirty = 0 }
  -- fitted to the folders, if calibre's database as it was can be read
  local fitted, d = pcall(differ, copy, before.path .. "/metadata.db")
  local ok, err
  if fitted then
    local moved, dirty = {}, {}
    for _, m in ipairs(d.moved) do moved[#moved + 1] = m.id end
    for _, c in ipairs(d.changed) do dirty[#dirty + 1] = c.id end
    for _, m in ipairs(d.moved) do dirty[#dirty + 1] = m.id end
    for _, k in ipairs(d.back) do dirty[#dirty + 1] = k.id end
    out.moved, out.dirty, out.unfitted = #moved, #dirty, #d.unfitted
    ok, err = lulibre.copy_db(copy, staged, { attach = { now = before.path .. "/metadata.db" }, amend = FIT,
      value = json.encode { moved = moved, dirty = dirty }, stubs = { "title_sort", "uuid4" } })
  else
    out.unfitted_why = tostring(d)
    ok, err = lulibre.copy_db(copy, staged)
  end
  if not ok then error("staging the copy: " .. err, 0) end
  held = calibre.running()
  if held and held.db then error("a calibre program opened the library meanwhile: nothing was put back", 0) end
  local lib = lulibre.o.library
  -- SQLite's own backup, into calibre's database: what a journal left by a
  -- crash would undo is undone first, as SQLite does on opening
  ok, err = lulibre.copy_db(staged, lib .. "/metadata.db")
  out.how = "copied in"
  if not ok then
    -- a database SQLite cannot open to write into (damaged past that): the
    -- staged copy takes its place, and the journal beside it goes (the
    -- copy before has both)
    local tmp = lib .. "/metadata.db.lulibre-new"
    local copied, cerr = uv.fs_copyfile(staged, tmp)
    if not copied then
      error(("putting the copy back: %s; and copying it in: %s"):format(err, cerr), 0)
    end
    uv.fs_unlink(lib .. "/metadata.db-journal")
    local renamed, rerr = uv.fs_rename(tmp, lib .. "/metadata.db")
    if not renamed then
      error(("putting the copy back: %s; and in its place: %s"):format(err, rerr), 0)
    end
    out.how = "in place of the damaged file (" .. err .. ")"
  end
  return out
end

--- Returns `put_back`'s result as one line.
-- @tparam table r what `put_back` returned
-- @treturn string
function M.put_back_summary(r)
  local s = ("the copy is put back (%s); calibre's database before it is %s"):format(r.how, r.before.path)
  if r.moved > 0 then
    s = s .. ("; %d record%s pointed at the folder%s as renamed since"):format(r.moved, r.moved == 1 and "" or "s",
      r.moved == 1 and "" or "s")
  end
  if (r.unfitted or 0) > 0 then s = s .. ("; %d whose folders cannot be followed"):format(r.unfitted) end
  if r.unfitted_why then s = s .. "; not fitted to the folders (" .. r.unfitted_why .. ")" end
  return s
end

local said = {} -- said.warned: the session's one popup (lulibre.claim)

--- Offers to make a copy, once a session. The offer comes at the first
-- change to the library if the newest copy is older than `backup_max_age`
-- and `backup_too_old` is "warn". The offer comes only in the interface, so a
-- script's output is left alone. A replaceable function.
function M.warn()
  if said.warned or lulibre.headless or not lulibre.task_id() then return end
  if tostring(lulibre.o.backup_too_old) ~= "warn" or lulibre.o.library == "" or not M.too_old() then return end
  if not lulibre.claim(said, "warned") then return end -- another task has said it
  local age = M.age()
  local what = age and ("the newest copy of calibre's database is %d days old"):format(math.floor(age))
    or "there is no copy of calibre's database yet"
  local pick = lulibre.pick({ "back up now", "not now" }, { title = what .. " (backup_too_old)" })
  if pick == "back up now" then
    local ok, b = pcall(M.take, "asked for, before a change")
    lulibre.notify(ok and ("calibre's database copied to %s"):format(b.path) or tostring(b), not ok and "error" or nil)
  end
end

return M
