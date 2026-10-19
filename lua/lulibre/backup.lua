-- Copies of calibre's database (metadata.db, and the preferences calibre
-- keeps beside it), kept with lulibre's data: one folder per copy under
-- ~/.local/share/lulibre/backups/<the index's name>/, the newest
-- lulibre.o.backup_keep of them. They are made before the content server
-- starts (lulibre.service, :offline restart) as lulibre.o.backup_restart
-- says, or when asked.
--
--   local backup = require "lulibre.backup"
--   backup.take("before rebuilding")   -- { path=, ts=, reason= }; waits
--   backup.list()                      -- newest first: { {path=, ts=, reason=, books=}, ... }
--   backup.last()                      -- the newest, or nil
--   backup.age()                       -- days since the newest (nil when there is none)
--   backup.too_old([days])             -- none, or the newest older than days (backup_max_age)
--   backup.prune([keep])               -- remove all but the newest keep (backup_keep)
--   backup.policy()                    -- "always" | "next" | "never" | days
--   backup.due()                       -- would the server's next start make one?
--   backup.on_restart()                -- make one if due (lulibre.offline.run calls it)
--   backup.metadata()                  -- calibredb backup_metadata (the server stopped)
--   backup.check([path])               -- calibre's database whole? true; or false, { problems }
--   backup.find(which)                 -- a copy by its place in list() (1, the newest) or its folder's name
--   backup.compare(copy)               -- what putting it back would change (writes nothing)
--   backup.restore(copy)               -- put it back: queued (lulibre.offline), the server stopped
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

--- Where this library's copies are kept.
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

--- The copies, newest first.
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

function M.last()
  return M.list()[1]
end

function M.age()
  local l = M.last()
  return l and (os.time() - l.ts) / 86400 or nil
end

function M.too_old(days)
  days = days or lulibre.o.backup_max_age
  local age = M.age()
  return age == nil or age > days
end

--- Copy calibre's database now. Waits (the copy is made on a worker
-- thread). The server may be running: the copy is SQLite's own backup, so
-- it is whole even if calibre writes meanwhile. The copy is then checked
-- (M.check): b.check is "ok" or "failed" (b.problems says what), and since
-- the copy is the database page for page, a copy that fails says calibre's
-- database does. opts.raw: if SQLite cannot copy it (a database too
-- damaged), copy its files as they are (the server stopped: put_back).
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

--- Remove all but the newest `keep` copies. Only the files a copy is made
-- of are removed; a folder holding anything else is left. Never removed:
-- the newest copy that passed its check, when none of the newest `keep`
-- did (a damaged database copied over and over does not push out the last
-- good copy of it), and a copy waiting to be put back. Returns how many went.
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

--- backup_restart, read: "always", "next", "never", or a number of days.
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

--- Note the value of backup_restart (lulibre does at each start).
function M.observe()
  local v = tostring(lulibre.o.backup_restart)
  if v == "next" and kv("backup:seen") ~= "next" then kv("backup:next_spent", false) end
  kv("backup:seen", v)
end

function M.due()
  M.observe()
  local p = M.policy()
  if p == "never" then return false end
  if p == "always" then return true end
  if p == "next" then return kv("backup:next_spent") == nil end
  return M.too_old(p)
end

--- Set backup_restart, for now and in init.lua. "next" arms it again.
function M.set(value)
  lulibre.o.backup_restart = value
  M.policy() -- says so if it will not do
  if tostring(value) == "next" then kv("backup:next_spent", false) end
  kv("backup:seen", tostring(value))
  pcall(require("lulibre.config_file").write_value, { name = "backup_restart" }, value)
end

--- Before the server starts: a copy if one is due. Returns it, or nil.
function M.on_restart()
  if not M.due() then return nil end
  local b = M.take("before the content server started")
  if M.policy() == "next" then kv("backup:next_spent", tostring(b.ts)) end
  return b
end

--- calibre writes a book's metadata.opf (in its folder) only from its own
-- program; changes made through calibredb or the content server just mark
-- the book. This writes those books' files. The server must be stopped.
-- Returns how many books' files were written.
function M.metadata()
  require("lulibre.calibre").wait_for_program("writing the books' opf files")
  local r, err = lulibre.system({ "calibredb", "--with-library", lulibre.o.library, "backup_metadata" },
    { timeout = 3600000 })
  if not r or r.code ~= 0 then error("backup_metadata: " .. require("lulibre.offline").why(r, err), 0) end
  local n = 0
  for _ in r.stdout:gmatch("[^\n]*%%[^\n]*\n") do n = n + 1 end -- one progress line per book
  return n
end

--- PRAGMA integrity_check of calibre's database, or of the database at
-- path; read only, so the server may run (a read holds back calibre's
-- writes for as long as the check takes: well under a second for a few
-- thousand books). true; or false and the problems SQLite found.
function M.check(path)
  local ok, problems = lulibre.check_db(path or live())
  if ok == nil then error("integrity check: " .. problems, 0) end
  return ok, problems
end

--- A copy by its place in M.list() (1 is the newest) or by its folder's
-- name (20260101-120000, or as much of it as names one). nil if none.
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
  local ok, err = lulibre.copy_db(live(), tmp)
  if not ok then
    uv.fs_unlink(tmp)
    error("reading calibre's database: " .. err, 0)
  end
  local done, r = pcall(fn, tmp)
  uv.fs_unlink(tmp)
  if not done then error(r, 0) end
  return r
end

--- What putting a copy back would change, against calibre's database as
-- it is now. Writes nothing. Returns
--   { books_then=, books_now=,
--     back = { {id=, title=, authors=, folder=, trash=}, ... }  books removed since: their records come
--                                                       back (folder: their folder is still there;
--                                                       trash: calibre's trash has it)
--     missing = n, trash = n                           of those, with no folder; in calibre's trash
--     gone = { {id=, title=, authors=}, ... }          books added since: their records go; their
--                                                       folders stay (:orphans finds them)
--     changed = { {id=, title=, now=, fields={...}}, ... }  changed since (calibre's last-modified time):
--                                                       fields, those of lulibre's that differ; a book
--                                                       changed in others only (comments, custom
--                                                       columns, cover) has none
--     fields = { title = n, ... }                      how many books differ in each
--     moved = { {id=, then=, now=}, ... }              folders calibre renamed since: put_back points
--                                                       the records at them as they are now
--     unfitted = { ... }                               renamed, but not so that it can be followed
--     journal = n                                      of the changes, those made through lulibre
--     check = "ok" | "failed" }                        the copy's integrity, now
function M.compare(b)
  local whole = M.check(b.path .. "/metadata.db")
  local out = with_now(function(now) return differ(b.path .. "/metadata.db", now) end)
  out.check = whole and "ok" or "failed"
  out.journal = lulibre.sql("SELECT count(*) AS n FROM journal WHERE ts > ? AND status = 'applied'", b.ts)[1].n
  return out
end

--- compare()'s answer, in lines.
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

--- Put a copy back: queued until nothing has the library open (lulibre.offline;
-- offline.ask() offers to do it). The copy must pass its check. Returns
-- the job's id.
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

--- Put the copy in folder `path` back as calibre's database. Nothing may
-- have the library open: lulibre.offline runs this (job restore_copy).
-- calibre's database as it is goes first into a copy of its own (kept as
-- the others are: put that one back to undo this). Returns
-- { before=, moved=, dirty=, unfitted=, how= }.
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
  if not ok then
    uv.fs_unlink(staged)
    error("staging the copy: " .. err, 0)
  end
  held = calibre.running()
  if held and held.db then
    uv.fs_unlink(staged)
    error("a calibre program opened the library meanwhile: nothing was put back", 0)
  end
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
      uv.fs_unlink(staged)
      error(("putting the copy back: %s; and copying it in: %s"):format(err, cerr), 0)
    end
    uv.fs_unlink(lib .. "/metadata.db-journal")
    local renamed, rerr = uv.fs_rename(tmp, lib .. "/metadata.db")
    if not renamed then
      uv.fs_unlink(staged)
      error(("putting the copy back: %s; and in its place: %s"):format(err, rerr), 0)
    end
    out.how = "in place of the damaged file (" .. err .. ")"
  end
  uv.fs_unlink(staged)
  return out
end

--- put_back()'s answer, in a line.
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

-- The first change to the library in a session, with the newest copy too
-- old: said once, in a popup that offers one. A replaceable function.
-- (The interface only: a script's output stays its own.)
local said = {} -- said.warned: the session's one popup (lulibre.claim)
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
