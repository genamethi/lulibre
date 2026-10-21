--- Changing the library.
-- Every change goes to calibre through calibredb (through the content
-- server when one answers), is recorded in the journal with the old value,
-- and can be undone.
--
-- A change is `{ id=, field=, value=, op= }`. op is "set" (the default),
-- or for the list fields authors, tags and identifiers (and a custom field
-- of the type list), "add" or "remove", which leave a book's other values
-- alone. A field is one of `fields`, or a custom field ("#partof",
-- `lulibre.custom`).
--
-- @module lulibre.edit
-- @usage
-- local edit = require "lulibre.edit"
-- local r = edit.apply({ { id = 12, field = "tags", value = "math/topology", op = "add" } },
--   { label = "a subject" })
-- print(edit.summary(r))          --> "changed 1 book  (u undoes)"
-- edit.undo()                     --> puts that batch back
local M = {}

--- calibre's fields a change can name, in the order forms show them.
M.fields = { "title", "authors", "tags", "series", "series_index", "publisher", "pubdate", "identifiers", "languages" }
--- How the items of a list field are separated when shown and typed,
-- by field: authors " & ", tags and identifiers ", ".
M.separator = { authors = " & ", tags = ", ", identifiers = ", " }

--- How an empty value is shown where one is about to be written.
M.BLANK = "(blank)"

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Is this calibre's placeholder for no author ("Unknown", or nothing)?
-- @function is_unknown
-- @tparam string|nil author
-- @treturn boolean
local function is_unknown(author)
  return author == nil or author == "" or author == "Unknown" or author == "()"
end
M.is_unknown = is_unknown

--- A list field's text as items: authors by " & " (or ";"), the others by commas.
-- @tparam string field
-- @tparam string|nil text
-- @treturn {string,...}
function M.split(field, text)
  local out = {}
  text = text or ""
  if field == "authors" then
    text = text:gsub("%s*;%s*", " & ")
    for item in (text .. " & "):gmatch("(.-)%s+&%s+") do
      if trim(item) ~= "" then out[#out + 1] = trim(item) end
    end
  else
    for item in text:gmatch("[^,]+") do
      if trim(item) ~= "" then out[#out + 1] = trim(item) end
    end
  end
  return out
end

--- A book's current value of a field, as text in the form changes use:
-- a list field joined by its separator, identifiers as "type:value", sorted;
-- "" for an unknown author, and for a series index without a series.
-- @tparam table book from `lulibre.book(id)`
-- @tparam string field
-- @treturn string
function M.current(book, field)
  -- a custom field (#partof): kept by lulibre.custom, not calibre
  if field:sub(1, 1) == "#" then return require("lulibre.custom").get(book.id, field) end
  if field == "title" then return book.title or "" end
  if field == "authors" then return is_unknown(book.author) and "" or book.author end
  if field == "tags" then return table.concat(book.tags, ", ") end
  if field == "series" then return book.series or "" end
  if field == "series_index" then
    -- calibre gives every book an index, 1 by default; it means nothing without a series
    if not book.series or not book.series_index then return "" end
    return ("%.10g"):format(book.series_index)
  end
  if field == "publisher" then return book.publisher or "" end
  if field == "pubdate" then return book.pubdate or "" end
  if field == "languages" then return book.lang or "" end
  if field == "identifiers" then
    local keys = {}
    for k in pairs(book.idents) do keys[#keys + 1] = k end
    table.sort(keys)
    for i, k in ipairs(keys) do keys[i] = k .. ":" .. book.idents[k] end
    return table.concat(keys, ", ")
  end
  error("unknown field " .. tostring(field))
end

local function key_of(field, item)
  if field == "identifiers" then return (item:match("^([^:]+):") or item):lower() end
  return lulibre.fold(item)
end

--- The value a field ends up with after a change. A bare year for pubdate
-- is the first of January; an add or remove keeps the other items.
-- @tparam table book
-- @tparam string field
-- @tparam[opt] string op "set" when not given
-- @tparam string value
-- @treturn string in the form `current` gives
-- @raise when the op does not apply to the field, or the value cannot be one (a malformed date)
function M.resolve(book, field, op, value)
  op = op or "set"
  local custom = field:sub(1, 1) == "#" and require("lulibre.custom")
  if custom then
    local spec = custom.field(field) or { type = "text" }
    if spec.type ~= "list" then
      if op ~= "set" then error(field .. " holds one value; only op = \"set\" applies") end
      return custom.resolve(field, value)
    end
  end
  local sep = M.separator[field] or (custom and ", ")
  if not sep then
    if op ~= "set" then error(field .. " holds one value; only op = \"set\" applies") end
    value = trim(value or "")
    -- dates are kept as YYYY-MM-DD; a bare year means the first of January
    if field == "pubdate" then
      if value:match("^%d%d%d%d$") then value = value .. "-01-01" end
      if value ~= "" and not value:match("^%d%d%d%d%-%d%d%-%d%d$") then
        error("a date is written YYYY or YYYY-MM-DD", 0)
      end
    end
    if field == "series_index" and value ~= "" then
      if not tonumber(value) then error("a series index is a number", 0) end
      value = ("%.10g"):format(tonumber(value))
    end
    return value
  end
  if field == "identifiers" then
    for _, item in ipairs(M.split(field, value)) do
      if not item:match("^[%w_%-]+:.") and not (op == "remove" and item:match("^[%w_%-]+$")) then
        error("identifiers are written type:value, for example doi:10.1000/xyz", 0)
      end
    end
  end
  -- calibre keeps tags and identifiers as sets; sorting gives each set one
  -- spelling, so "is this a change?" and undo can compare text
  local function finish(items)
    if field ~= "authors" then table.sort(items) end
    return table.concat(items, sep)
  end
  if op == "set" then return finish(M.split(custom and "tags" or field, value)) end
  local items, seen = M.split(custom and "tags" or field, M.current(book, field)), {}
  for i, item in ipairs(items) do seen[key_of(field, item)] = i end
  for _, item in ipairs(M.split(custom and "tags" or field, value)) do
    local k = key_of(field, item)
    if op == "add" then
      if seen[k] then items[seen[k]] = item -- same tag, or a new value for that identifier
      else
        items[#items + 1] = item
        seen[k] = #items
      end
    elseif op == "remove" then
      for i = #items, 1, -1 do
        if key_of(field, items[i]) == k then table.remove(items, i) end
      end
    else
      error("unknown op " .. tostring(op))
    end
  end
  return finish(items)
end

--- Turn what was typed for a field into changes. For a list field,
-- "+x, -y" adds and removes; anything else replaces the value.
-- @tparam integer id the book
-- @tparam string field
-- @tparam string text
-- @treturn {table,...} changes
function M.typed(id, field, text)
  if M.separator[field] and text:find("^%s*[+-]") then
    local out = {}
    for _, item in ipairs(M.split(field == "authors" and "tags" or field, text)) do
      local sign, rest = item:match("^([+-])%s*(.+)$")
      if sign then
        out[#out + 1] = { id = id, field = field, value = rest, op = sign == "+" and "add" or "remove" }
      end
    end
    return out
  end
  return { { id = id, field = field, value = text, op = "set" } }
end

-- calibredb's spelling of a value
local function wire(field, value)
  if field:sub(1, 1) == "#" then return require("lulibre.custom").wire(field, value) end
  if field == "tags" or field == "identifiers" then
    return (value:gsub("%s*,%s*", ","))
  end
  if field == "series_index" and value == "" then return "1" end -- calibre's default
  if field == "pubdate" then
    -- Give calibre a complete UTC timestamp. Left to fill in a missing time
    -- of day it uses the current one, which can land on the next day; and
    -- at midnight UTC the day is the one before wherever calibre shows it
    -- west of Greenwich. Noon UTC is the same day everywhere.
    if value == "" then return "0101-01-01T00:00:00+00:00" end -- calibre's "no date"
    if value:match("^%d%d%d%d%-%d%d%-%d%d$") then return value .. "T12:00:00+00:00" end
  end
  return value
end

-- ---- how changes reach calibre ----
-- Through the content server, or straight to the library folder ("offline").
-- calibre itself allows the second only while no calibre program has the
-- library open; with the server running, everything must go through it.

local probe = { at = 0 }

--- Whether something is listening where the content server should be.
-- Waits up to 400 ms; true when it cannot tell (no luv).
-- @tparam string url "http://host:port"
-- @treturn boolean
function M.server_up(url)
  local ok, uv = pcall(require, "luv")
  if not ok then return true end -- cannot tell; let calibredb find out
  local scheme, host, port = (url or ""):match("^(%a+)://%[?([^/%]:]+)%]?:?(%d*)")
  if not host then return false end
  port = tonumber(port) or (scheme == "https" and 443 or 80)
  local addrs = uv.getaddrinfo(host, nil, { socktype = "stream" })
  local addr = addrs and addrs[1] and addrs[1].addr
  if not addr then return false end
  local tcp, done, up = uv.new_tcp(), false, false
  tcp:connect(addr, port, function(err)
    up, done = not err, true
  end)
  for _ = 1, 40 do
    if done then break end
    lulibre.sleep(10)
  end
  tcp:close()
  return up
end

--- How a change would reach calibre right now, as `write_via` says: with
-- "auto", the server when it answers (asked at most every 5 seconds).
-- @treturn string "server" or "direct"
-- @raise when `write_via` is "server" and no server is set
function M.route()
  local o = lulibre.o
  local via = o.write_via
  if via == "server" then
    if o.server == "" then error('write_via is "server" but lulibre.o.server is not set', 0) end
    return "server"
  end
  if via == "direct" or o.server == "" then return "direct" end
  -- auto: the server when it answers. Asked at most every few seconds.
  local now = os.time()
  if probe.up == nil or probe.url ~= o.server or now - probe.at >= 5 then
    local was = probe.up
    probe.up, probe.at, probe.url = M.server_up(o.server), now, o.server
    if not probe.up and was ~= false then
      lulibre.log(("the content server at %s does not answer; changing the library folder directly"):format(o.server))
    end
  end
  return probe.up and "server" or "direct"
end

--- How many calibredb processes may run at once: `write_jobs`, or one
-- straight to the folder, where they would contend for the same database.
-- @treturn integer
function M.write_jobs()
  return M.route() == "direct" and 1 or math.max(1, lulibre.o.write_jobs)
end

local warned = {}
--- Is a file that holds a secret readable by its owner alone? lulibre never
-- reads the password itself (calibredb is handed the file's name), but it
-- can tell when others on the machine could: said once, as a warning.
-- @tparam string path
-- @treturn boolean|nil false when others can read it; nil when it was said already
function M.check_secret(path)
  if warned[path] then return end
  local ok, uv = pcall(require, "luv")
  local st = ok and uv.fs_stat(path)
  if st and st.mode and st.mode % 64 ~= 0 then -- any permission for group or others
    warned[path] = true
    lulibre.log(("%s can be read by other users of this machine (mode %o): chmod 600 %s"):format(path, st.mode % 512, path),
      "warn")
    return false
  end
  return true
end

--- The start of every calibredb command for this library: through the
-- server (user, password file) or straight to the folder, as `route` says.
-- Straight to the folder, it first waits for calibre's program to close.
-- @treturn {string,...} the command's words so far, to add calibredb's own to
-- @raise when the password file is missing
function M.calibredb()
  -- every change to the library starts here: the first says so when the
  -- newest copy of calibre's database is too old (lulibre.backup)
  require("lulibre.backup").warn()
  local o, a = lulibre.o, { "calibredb" }
  if M.route() == "server" then
    a[#a + 1] = "--with-library"
    a[#a + 1] = o.server
    if o.user ~= "" then
      a[#a + 1] = "--username"
      a[#a + 1] = o.user
    end
    if o.password_file ~= "" then
      -- say so now: handed a file that is not there, calibredb asks the terminal for a password
      local f = io.open(o.password_file)
      if not f then
        error(("the password file %s does not exist (lulibre.o.password_file)"):format(o.password_file), 0)
      end
      f:close()
      M.check_secret(o.password_file)
      a[#a + 1] = "--password"
      a[#a + 1] = "<f:" .. o.password_file .. ">"
    end
  else
    -- straight to the folder: calibre's program, if it is open, could be
    -- changing the same library; wait until it is closed
    require("lulibre.calibre").wait_for_program("writing to the library")
    a[#a + 1] = "--with-library"
    a[#a + 1] = o.library
  end
  return a
end

--- After lulibre has changed the library straight in its folder (no
-- server, no program open): calibre's backup_metadata writes the opf files
-- of the books changed, as nothing else will (option `backup_metadata`).
-- Errors are logged, not raised: the change itself is made.
function M.after_direct()
  if not lulibre.o.backup_metadata or M.route() ~= "direct" then return end
  local ok, err = pcall(require("lulibre.backup").metadata)
  if not ok then lulibre.log("the books' opf files were not written: " .. tostring(err), "warn") end
end

--- What went wrong with a calibredb run, in words: the content server not
-- answering, a refused account, the library held by another calibre program.
-- @function failure
-- @tparam table|nil r `lulibre.system`'s result
-- @tparam[opt] string err its error when there is no result
-- @treturn string
local function failure(r, err)
  if not r then return err or "could not run calibredb" end
  if r.timed_out then return "calibredb timed out" end
  local msg = trim(r.stderr ~= "" and r.stderr or r.stdout)
  if msg:find("Another calibre program") then
    return "a calibre program (the content server?) has the library open, so it cannot be changed directly: "
      .. "set lulibre.o.server to go through the server, or stop it"
  elseif msg:find("Connection refused") or msg:find("Errno 111") then
    return "the content server at " .. lulibre.o.server .. " does not answer"
  end
  msg = msg:match("[^\n]*$") or msg -- the last line carries the reason
  if msg:find("403") or msg:lower():find("forbidden") then
    return "the content server refused the change: this account may be read-only"
  elseif msg:find("401") or msg:lower():find("unauthori") then
    return "the content server rejected the user name or password"
  end
  return msg ~= "" and msg or ("calibredb exited with status " .. r.code)
end
M.failure = failure

--- Apply changes, as one batch in the journal. Waits; shows progress.
-- @tparam {table,...} changes `{ id=, field=, value=, op= }`
-- @tparam[opt] table opts `label` (the batch's name in the history), `jobs` (calibredb processes
-- at once; `write_jobs` by default)
-- @treturn table `{ batch=, books=, applied=, unchanged=, failed = { {id=, error=}, ... }, links= }`
-- (links: symbolic links repaired after calibre renamed folders)
function M.apply(changes, opts)
  opts = opts or {}
  local by_book, order = {}, {}
  for _, c in ipairs(changes) do
    if not by_book[c.id] then
      by_book[c.id] = {}
      order[#order + 1] = c.id
    end
    table.insert(by_book[c.id], c)
  end

  -- anything that would stop every write stops it here, before the journal has a batch
  for _, c in ipairs(changes) do
    if c.id > 0 then
      M.calibredb()
      break
    end
  end
  -- changes made outside lulibre since it last looked are logged before this one
  local snapshots = require "lulibre.snapshots"
  if #changes > 0 then snapshots.observe() end
  local batch = lulibre.store("SELECT coalesce(max(batch), 0) + 1 AS n FROM journal")[1].n
  local now = os.time()
  local queue, unchanged = {}, 0
  for _, id in ipairs(order) do
    local book = lulibre.book(id)
    if book then
      -- several changes to one field build on each other
      local values, touched = {}, {}
      for _, c in ipairs(by_book[id]) do
        if values[c.field] == nil then
          values[c.field] = M.resolve(book, c.field, c.op, c.value)
          touched[#touched + 1] = c.field
        else
          values[c.field] = M.resolve_from(values[c.field], c.field, c.op, c.value)
        end
      end
      local fields = {}
      for _, field in ipairs(touched) do
        local old = M.current(book, field)
        if values[field] ~= old then
          fields[#fields + 1] = { field = field, old = old, new = values[field] }
        else
          unchanged = unchanged + 1
        end
      end
      if #fields > 0 then
        for _, f in ipairs(fields) do
          lulibre.store("INSERT INTO journal(batch, book, field, old, new, ts, label) VALUES(?, ?, ?, ?, ?, ?, ?)",
            batch, id, f.field, f.old, f.new, now, opts.label or "edit")
        end
        queue[#queue + 1] = { id = id, fields = fields }
      end
    end
  end

  local total, failed = #queue, {}
  local staged, renamed = false, false
  local ran, trouble = pcall(lulibre.each, queue, function(job)
    if job.id < 0 then
      -- a file staged from the sync folder: its metadata is lulibre's own
      -- (custom fields too, which follow it into the library when it is added)
      local calibre_fields, custom_ok = {}, true
      for _, f in ipairs(job.fields) do
        if f.field:sub(1, 1) == "#" then
          custom_ok = pcall(require("lulibre.custom").put, job.id, f.field, f.new, opts.label or "edit") and custom_ok
        else
          calibre_fields[#calibre_fields + 1] = f
        end
      end
      local ok, why = true, nil
      if #calibre_fields > 0 then ok, why = pcall(require("lulibre.sync").write, job.id, calibre_fields) end
      if not custom_ok then ok, why = false, why or "a custom field could not be written" end
      lulibre.store("UPDATE journal SET status = ?, error = ? WHERE batch = ? AND book = ?",
        ok and "applied" or "failed", not ok and tostring(why) or nil, batch, job.id)
      if not ok then table.insert(failed, { id = job.id, error = tostring(why) }) end
      staged = true
      return
    end
    -- custom fields (#partof) are lulibre's own, and calibre's too where
    -- it has a column of that name; the rest go to calibre
    local own, theirs, cleared = {}, {}, {}
    for _, f in ipairs(job.fields) do
      if f.field:sub(1, 1) == "#" then
        own[#own + 1] = f
        if require("lulibre.custom").column(f.field) then
          -- set_metadata cannot empty a number's or a date's column; set_custom can
          if f.new == "" then cleared[#cleared + 1] = f else theirs[#theirs + 1] = f end
        end
      else
        theirs[#theirs + 1] = f
      end
    end
    local good, why = true, nil
    for _, f in ipairs(cleared) do
      local args = M.calibredb()
      for _, a in ipairs { "set_custom", f.field:sub(2), tostring(job.id), "" } do args[#args + 1] = a end
      local r, e = lulibre.system(args, { timeout = 120000 })
      if not (r and r.code == 0) then
        good, why = false, failure(r, e)
        break
      end
    end
    if good and #theirs > 0 then
      local args = M.calibredb()
      args[#args + 1] = "set_metadata"
      args[#args + 1] = tostring(job.id)
      for _, f in ipairs(theirs) do
        args[#args + 1] = "--field"
        args[#args + 1] = f.field .. ":" .. wire(f.field, f.new)
      end
      local r, e = lulibre.system(args, { timeout = 120000 })
      good = r ~= nil and r.code == 0
      why = not good and failure(r, e) or nil
    end
    if good then
      local custom = #own > 0 and require("lulibre.custom")
      for _, f in ipairs(own) do
        local ok, err = pcall(custom.put, job.id, f.field, f.new, opts.label or "edit")
        if not ok then good, why = false, tostring(err) end
      end
    end
    lulibre.store("UPDATE journal SET status = ?, error = ? WHERE batch = ? AND book = ?",
      good and "applied" or "failed", why, batch, job.id)
    if not good then table.insert(failed, { id = job.id, error = why }) end
    for _, f in ipairs(job.fields) do
      -- calibre names a book's folder after its author and title
      if good and (f.field == "title" or f.field == "authors") then renamed = true end
    end
  end, { jobs = opts.jobs or M.write_jobs(), progress = "writing" })
  if not ran then
    lulibre.progress(nil)
    lulibre.notify(tostring(trouble), "error")
  end
  if staged then lulibre.stage_refresh() end
  local links = 0
  if total > 0 then
    M.after_direct()
    lulibre.reload()
    if renamed then links = M.repair_links() end
    -- Record what calibre actually stored (it may normalise a value), so
    -- undo can tell whether a field has been changed again since.
    for _, row in ipairs(lulibre.store("SELECT id, book, field FROM journal WHERE batch = ? AND status = 'applied'", batch)) do
      local book = lulibre.book(row.book)
      if book then lulibre.store("UPDATE journal SET new = ? WHERE id = ?", M.current(book, row.field), row.id) end
    end
    snapshots.observe()
  end
  return { batch = batch, books = total, applied = total - #failed, unchanged = unchanged, failed = failed,
    links = links }
end

--- Symbolic links in folders of your own inside the library break when
-- calibre renames the folder they point into. Point them at the files
-- again, as the option `repair_links` allows (asking when it says "ask").
-- @treturn integer how many were repaired
function M.repair_links()
  if lulibre.o.repair_links == "never" then return 0 end
  local orphans = require "lulibre.orphans"
  local ok, broken = pcall(orphans.broken_links)
  if not ok then return 0 end
  local fixable = {}
  for _, l in ipairs(broken) do
    if l.to then fixable[#fixable + 1] = l end
  end
  if #fixable == 0 then return 0 end
  if not lulibre.policy("repair_links", ("%d link%s in your folders point%s at books that have just moved; repair?"):format(
      #fixable, #fixable == 1 and "" or "s", #fixable == 1 and "s" or "")) then
    if lulibre.o.repair_links == "ask" and lulibre.headless then
      print(("%d links now point at folders calibre has renamed; `lulibre orphans --apply` repairs them"):format(#fixable))
    end
    return 0
  end
  return orphans.relink(fixable)
end

--- `resolve`, starting from a value instead of a book.
-- @tparam string current the field's value now
-- @tparam string field
-- @tparam[opt] string op
-- @tparam string value
-- @treturn string
function M.resolve_from(current, field, op, value)
  local fake = { title = current, author = current, tags = M.split("tags", current), series = current,
    series_index = tonumber(current), publisher = current, pubdate = current, lang = current, idents = {} }
  if field == "identifiers" then
    for _, item in ipairs(M.split(field, current)) do
      local k, v = item:match("^([^:]+):(.*)$")
      if k then fake.idents[k] = v end
    end
  end
  return M.resolve(fake, field, op, value)
end

-- The journal's field name for a removed book; `old` holds what it was.
local REMOVED = "(removed)"

--- What a book's record says, field by field, as the journal keeps it for a
-- removed book: `{ title=, formats=, <each of fields>= }`.
-- @function state
-- @tparam table book
-- @treturn table
local function snapshot(book)
  local snap = { title = book.title, formats = book.formats }
  for _, field in ipairs(M.fields) do snap[field] = M.current(book, field) end
  return snap
end
M.state = snapshot

--- Remove books from the library. Waits. calibre moves them to its recycle
-- bin (.caltrash in the library folder) rather than deleting them, and each
-- removal is journaled with what the record said, so `undo` can bring the
-- book back for as long as calibre keeps it there.
-- @tparam {integer,...} ids library books (not files staged from the sync folder)
-- @tparam[opt] table opts `label`: the batch's name in the history
-- @treturn integer how many were removed
-- @treturn[opt] string why not all, when calibredb failed
function M.remove(ids, opts)
  local removed = 0
  for _, id in ipairs(ids) do
    if id < 0 then
      return 0, "files staged from the sync folder are not in calibre; :sync drop takes them out of the folder"
    end
  end
  if #ids == 0 then return 0 end
  M.calibredb() -- stops here if the password file is missing
  require("lulibre.snapshots").observe()
  local json = require "lulibre.json"
  local batch = lulibre.store("SELECT coalesce(max(batch), 0) + 1 AS n FROM journal")[1].n
  local label, now = opts and opts.label or "remove", os.time()
  for from = 1, #ids, 200 do
    local chunk = {}
    for i = from, math.min(from + 199, #ids) do
      local book = lulibre.book(ids[i])
      if book then
        chunk[#chunk + 1] = tostring(ids[i])
        lulibre.store("INSERT INTO journal(batch, book, field, old, new, ts, label) VALUES(?, ?, ?, ?, '', ?, ?)",
          batch, ids[i], REMOVED, json.encode(snapshot(book)), now, label)
      end
    end
    lulibre.progress(("removing %d/%d"):format(from + #chunk - 1, #ids))
    local args = M.calibredb()
    args[#args + 1] = "remove"
    args[#args + 1] = table.concat(chunk, ",")
    local r, e = lulibre.system(args, { timeout = 600000 })
    local good = r ~= nil and r.code == 0
    for _, id in ipairs(chunk) do
      lulibre.store("UPDATE journal SET status = ?, error = ? WHERE batch = ? AND book = ?",
        good and "applied" or "failed", not good and failure(r, e) or nil, batch, tonumber(id))
    end
    if not good then
      lulibre.progress(nil)
      if removed > 0 then lulibre.reload() end
      return removed, failure(r, e)
    end
    removed = removed + #chunk
  end
  lulibre.progress(nil)
  if removed > 0 then
    lulibre.reload()
    require("lulibre.snapshots").observe()
  end
  return removed
end

-- Bring one removed book back out of calibre's recycle bin: its files and
-- cover are added again and its metadata (calibre's own record of it, kept
-- beside the files) restored. The book gets a new id. Returns the id, or
-- nil and why not.
local function restore(id, snap)
  local ok, uv = pcall(require, "luv")
  if not ok then return nil, "putting a removed book back needs the luv rock" end
  local dir = ("%s/.caltrash/b/%d"):format(lulibre.o.library, id)
  local files, opf, cover = {}, nil, nil
  local req = uv.fs_scandir(dir)
  while req do
    local name, kind = uv.fs_scandir_next(req)
    if not name then break end
    if name == "metadata.opf" then opf = dir .. "/" .. name
    elseif name == "cover.jpg" then cover = dir .. "/" .. name
    elseif kind == "file" then files[#files + 1] = dir .. "/" .. name end
  end
  table.sort(files)
  local had_files = snap.formats and #snap.formats > 0
  if #files == 0 and (had_files or not req) and not opf then
    return nil, ("calibre's recycle bin no longer holds book %d (%s)"):format(id, snap.title or "?")
  end

  local args = M.calibredb()
  args[#args + 1] = "add"
  args[#args + 1] = "--duplicates"
  args[#args + 1] = "--title"
  args[#args + 1] = snap.title or "Unknown"
  if snap.authors and snap.authors ~= "" then
    args[#args + 1] = "--authors"
    args[#args + 1] = snap.authors
  end
  if cover then
    args[#args + 1] = "--cover"
    args[#args + 1] = cover
  end
  if #files > 0 then args[#args + 1] = files[1] else args[#args + 1] = "--empty" end
  local r, e = lulibre.system(args, { timeout = 300000 })
  local new = r and r.code == 0 and tonumber((r.stdout .. r.stderr):match("Added book ids:%s*(%d+)"))
  if not new then return nil, failure(r, e) end
  for i = 2, #files do
    local more = M.calibredb()
    more[#more + 1] = "add_format"
    more[#more + 1] = tostring(new)
    more[#more + 1] = files[i]
    lulibre.system(more, { timeout = 300000 })
  end
  -- the record: calibre's own copy of it if the bin has one, else what the journal kept
  local meta = M.calibredb()
  meta[#meta + 1] = "set_metadata"
  meta[#meta + 1] = tostring(new)
  if opf then
    meta[#meta + 1] = opf
  else
    for _, field in ipairs(M.fields) do
      local value = snap[field]
      if value and value ~= "" and not (field == "series_index" and (snap.series or "") == "") then
        meta[#meta + 1] = "--field"
        meta[#meta + 1] = field .. ":" .. wire(field, value)
      end
    end
  end
  local mr, me = lulibre.system(meta, { timeout = 120000 })
  if not mr or mr.code ~= 0 then return new, "the book is back, but not all of its metadata: " .. failure(mr, me) end
  return new
end

--- Bring back a book a journal row says was removed, and log it: the row
-- is marked undone and says which book it came back as, and a "(restored)"
-- row for the new book says which one it was.
-- @tparam table row the journal's row
-- @tparam[opt] string label the batch's name
-- @treturn[1] integer the new id
-- @treturn[1] string|nil a warning, when not all of its metadata came back
-- @treturn[2] nil
-- @treturn[2] string why not
function M.restore_removed(row, label)
  local new, why = restore(row.book, require("lulibre.json").decode(row.old))
  if new then
    -- its custom fields come back with it
    require("lulibre.custom").move(row.book, new)
    lulibre.store("UPDATE journal SET undone = 1, new = ? WHERE id = ?", "restored as book " .. new, row.id)
    local batch = lulibre.store("SELECT coalesce(max(batch), 0) + 1 AS n FROM journal")[1].n
    lulibre.store([[INSERT INTO journal(batch, book, field, old, new, status, ts, label)
      VALUES(?, ?, '(restored)', ?, ?, 'applied', ?, ?)]], batch, new, tostring(row.book), row.old, os.time(),
      label or "restore")
  end
  return new, why
end

--- One line for the message area about what `apply` did.
-- @tparam table r `apply`'s result
-- @treturn string
function M.summary(r)
  if r.books == 0 then return "nothing to change" end
  local s = ("changed %d book%s"):format(r.applied, r.applied == 1 and "" or "s")
  if (r.links or 0) > 0 then s = s .. (", repaired %d link%s"):format(r.links, r.links == 1 and "" or "s") end
  if #r.failed > 0 then
    s = s .. (", %d failed: %s"):format(#r.failed, r.failed[1].error or "?")
  end
  return r.applied > 0 and s .. ("  (%s undoes)"):format(lulibre.hint("undo")) or s
end

--- Recent batches, newest first.
-- @tparam[opt] integer limit 50 when not given
-- @treturn {table,...} `{ batch=, label=, ts=, books=, fields=, failed=, undone=, removed= }`
function M.history(limit)
  return lulibre.store([[SELECT batch, max(label) AS label, max(ts) AS ts, count(DISTINCT book) AS books,
      count(*) AS fields, sum(status = 'failed') AS failed, min(undone) AS undone,
      sum(field = '(removed)') AS removed
    FROM journal GROUP BY batch ORDER BY batch DESC LIMIT ?]], limit or 50)
end

--- Put back what a batch changed: fields, removed books (out of calibre's
-- recycle bin), a PDF replaced by OCR, a file dropped from the sync folder.
-- A field someone has changed again since is left alone and counted.
-- @tparam[opt] integer batch the latest one not yet undone when not given
-- @treturn[1] table `apply`'s result, with `skipped=`, `undid=` (the batch) and `restored=` (ids)
-- @treturn[2] nil
-- @treturn[2] string why not ("nothing to undo")
function M.undo(batch)
  if not batch then
    local last = lulibre.store([[SELECT batch FROM journal WHERE undone = 0 AND status = 'applied'
      AND label NOT LIKE 'undo%' ORDER BY batch DESC LIMIT 1]])[1]
    if not last then return nil, "nothing to undo" end
    batch = last.batch
  end
  local rows = lulibre.store("SELECT id, book, field, old, new FROM journal WHERE batch = ? AND status = 'applied' AND undone = 0", batch)
  if #rows == 0 then return nil, "batch " .. batch .. " has nothing left to undo" end
  local changes, skipped = {}, 0
  local restored, lost, staged_back = {}, {}, false
  for _, row in ipairs(rows) do
    if row.field == REMOVED then
      -- a removed book comes back out of calibre's recycle bin
      lulibre.progress(("putting back %d"):format(#restored + #lost + 1))
      local new, why = M.restore_removed(row, "undo of " .. batch)
      if new then
        restored[#restored + 1] = new
        if why then lost[#lost + 1] = { id = row.book, error = why } end
      else
        lost[#lost + 1] = { id = row.book, error = why }
      end
      goto next_row
    elseif row.field == "(format)" then
      -- a PDF replaced (by OCR): the original goes back, if it was kept
      if row.old and row.old ~= "" then
        local cmd = M.calibredb()
        cmd[#cmd + 1] = "add_format"
        cmd[#cmd + 1] = tostring(row.book)
        cmd[#cmd + 1] = row.old
        local r, e = lulibre.system(cmd, { timeout = 600000 })
        if r and r.code == 0 then
          restored[#restored + 1] = row.book
          lulibre.store("UPDATE journal SET undone = 1 WHERE id = ?", row.id)
        else
          lost[#lost + 1] = { id = row.book, error = failure(r, e) }
        end
      else
        lost[#lost + 1] = { id = row.book, error = "the PDF it replaced was not kept (ocr_write = \"replace\")" }
      end
      goto next_row
    elseif row.field == "(dropped)" then
      -- a file dropped from the sync folder goes back, with its staged metadata
      local back, why = require("lulibre.sync").undrop(require("lulibre.json").decode(row.old))
      if back then
        restored[#restored + 1] = row.book
        lulibre.store("UPDATE journal SET undone = 1, new = 'put back' WHERE id = ?", row.id)
        staged_back = true
      else
        lost[#lost + 1] = { id = row.book, error = why }
      end
      goto next_row
    end
    local book = lulibre.book(row.book)
    if book and M.current(book, row.field) == (row.new or "") then
      changes[#changes + 1] = { id = row.book, field = row.field, value = row.old or "", op = "set" }
    else
      skipped = skipped + 1
    end
    ::next_row::
  end
  lulibre.progress(nil)
  if staged_back then lulibre.stage_refresh() end
  if #restored + #lost > 0 then lulibre.reload() end
  local r = M.apply(changes, { label = "undo of " .. batch })
  lulibre.store("UPDATE journal SET undone = 1 WHERE batch = ? AND field NOT IN (?, '(dropped)', '(format)')", batch, REMOVED)
  r.skipped, r.undid, r.restored = skipped, batch, restored
  r.applied = r.applied + #restored
  for _, l in ipairs(lost) do table.insert(r.failed, l) end
  return r
end

return M
