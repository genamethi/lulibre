-- Custom fields: metadata of your own beside calibre's, in a database of its
-- own beside the index (<index>.custom.db). It is additive: calibre's
-- database is never changed for it, and nothing in it is lost when the
-- index is built again. A field is named as calibre names a custom column
-- (#partof), so it could become one; it is written through lulibre.edit like
-- any field (so it is in the journal, and undo and snapshots take it back),
-- proposed and reviewed like any field, shown in the preview, and filtered
-- by: #partof:handbook, #part:none, has:#partof.
--
--   local custom = require "lulibre.custom"
--   custom.declare("#series2", { type = "text", help = "..." })   -- text | number | date | list
--   custom.fields()              -- { {name=, type=, help=, books=}, ... }
--   custom.get(id, "#partof")    -- its value as edits spell it ("" when none)
--   custom.all(id)               -- { ["#partof"] = "...", ... }
--   lulibre.apply{ { id = 12, field = "#partof", value = "Handbook of Algebra" } }   -- to change one
--
-- A field can be in calibre too, as a custom column of the same name. lulibre
-- keeps its values as before (filters, the journal and undo use them), and
-- every change is written to calibre's column as well. calibre adds a column
-- only while the content server is stopped, so asking for one queues it
-- (lulibre.offline); until it is there, and wherever calibre's values are
-- not lulibre's, the preview says so.
--   custom.add_column("#partof", { heading = "Part of" })   -- queue the column
--   custom.remove_column("#partof")   -- queue its removal (lulibre's values stay)
--   custom.state("#partof")      -- { state = "lulibre" | "waiting" | "calibre", differ = n, removing = id }
--   custom.differing("#partof")  -- { {book=, lulibre=, calibre=}, ... }
--   custom.push("#partof")       -- copy lulibre's values into calibre's column
local M = {}

M.TYPES = { text = true, number = true, date = true, list = true }

-- the fields lulibre itself uses
M.builtin = {
  ["#partof"] = { type = "text", help = "the whole this is a part of: the handbook a chapter is from, the Stacks project" },
  ["#part"] = { type = "number", help = "its number in that whole (a chapter's)" },
  ["#parts"] = { type = "number", help = "how many parts the whole has" },
}

local function norm(name)
  name = tostring(name or "")
  if name:sub(1, 1) ~= "#" then name = "#" .. name end
  return name:lower()
end
M.norm = norm

--- Is a field name a custom field's (#something)?
function M.is(field)
  return type(field) == "string" and field:sub(1, 1) == "#"
end

local declared -- name -> { type=, help= }, read once
-- (built whole, then put in place in one step: a task interrupted while
-- building must not leave another task reading half of it)
local function load()
  if declared then return declared end
  local d = {}
  for name, spec in pairs(M.builtin) do d[name] = spec end
  for _, r in ipairs(lulibre.sql("SELECT name, type, help FROM custom.fields")) do
    d[r.name] = { type = r.type, help = r.help }
  end
  declared = d
  return d
end

--- Declare a field (or say again what it is). type: text, number, date or list.
function M.declare(name, spec)
  name = norm(name)
  assert(name:match("^#[%w_]+$"), "a custom field's name is # and letters, figures or _")
  spec = spec or {}
  local t = spec.type or "text"
  assert(M.TYPES[t], "a custom field is text, number, date or list")
  lulibre.store("INSERT OR REPLACE INTO custom.fields(name, type, help, created) VALUES(?, ?, ?, ?)", name, t, spec.help,
    os.time())
  load()[name] = { type = t, help = spec.help }
  return name
end

--- What a field is: { type=, help= }, or nil when it has not been declared.
function M.field(name)
  return load()[norm(name)]
end

--- Every field, with how many books have it.
function M.fields()
  local counts = {}
  for _, r in ipairs(lulibre.sql("SELECT field, count(DISTINCT book) AS n FROM custom.data GROUP BY field")) do
    counts[r.field] = r.n
  end
  local out = {}
  for name, spec in pairs(load()) do
    out[#out + 1] = { name = name, type = spec.type, help = spec.help, books = counts[name] or 0 }
  end
  for name, n in pairs(counts) do
    if not load()[name] then out[#out + 1] = { name = name, type = "text", books = n, undeclared = true } end
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

--- A book's value of a field, as edits spell it ("" when it has none; a
-- list's items joined by ", ").
function M.get(id, name)
  local vals = {}
  for _, r in ipairs(lulibre.sql("SELECT value FROM custom.data WHERE book = ? AND field = ? ORDER BY ord", id, norm(name))) do
    vals[#vals + 1] = r.value
  end
  return table.concat(vals, ", ")
end

function M.all(id)
  local out = {}
  for _, r in ipairs(lulibre.sql("SELECT field, value FROM custom.data WHERE book = ? ORDER BY field, ord", id)) do
    out[r.field] = out[r.field] and (out[r.field] .. ", " .. r.value) or r.value
  end
  return out
end

--- A value made to fit its field (as lulibre.edit resolves a set), or an
-- error. A list's items are kept in the order given.
function M.resolve(name, value)
  local spec = M.field(name) or { type = "text" }
  value = (value or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if value == "" then return "" end
  if spec.type == "number" then
    if not tonumber(value) then error(("%s is a number"):format(norm(name)), 0) end
    return ("%.10g"):format(tonumber(value))
  elseif spec.type == "date" then
    if value:match("^%d%d%d%d$") then value = value .. "-01-01" end
    if not value:match("^%d%d%d%d%-%d%d%-%d%d$") then error(("%s is a date: YYYY or YYYY-MM-DD"):format(norm(name)), 0) end
  end
  return value
end

--- Write a book's value of a field (lulibre.edit does this: go through it,
-- so that the change is journaled). value: as M.get gives it; "" removes it.
function M.put(id, name, value, source)
  name = norm(name)
  lulibre.store("DELETE FROM custom.data WHERE book = ? AND field = ?", id, name)
  if value == nil or value == "" then return end
  local spec = M.field(name) or { type = "text" }
  local items = { value }
  if spec.type == "list" then
    items = {}
    for raw in value:gmatch("[^,]+") do
      local item = raw:gsub("^%s+", ""):gsub("%s+$", "")
      if item ~= "" then items[#items + 1] = item end
    end
  end
  for i, v in ipairs(items) do
    lulibre.store("INSERT INTO custom.data(book, field, ord, value, source, ts) VALUES(?, ?, ?, ?, ?, ?)", id, name, i - 1, v,
      source, os.time())
  end
end

--- A book's custom fields follow it to a new id (a file added from the
-- sync folder, a book brought back from the recycle bin).
function M.move(from, to)
  lulibre.store("UPDATE custom.data SET book = ? WHERE book = ?", to, from)
end

-- ---- in calibre too ----

-- calibre's type for each of lulibre's, as add_custom_column takes it
M.DATATYPES = { text = { "text" }, number = { "float" }, date = { "datetime" }, list = { "text", "--is-multiple" } }

--- calibre's label for a field: its name without the #.
function M.label(name)
  return norm(name):sub(2)
end

--- calibre's column for a field: { label=, name=, datatype=, multiple= }, or nil.
function M.column(name)
  return lulibre.sql("SELECT label, name, datatype, multiple FROM cal_columns WHERE label = ?", M.label(name))[1]
end

--- The books whose value of a field calibre's column does not hold:
-- { {book=, lulibre=, calibre=}, ... } (values as M.get spells them; "" for none).
function M.differing(name)
  name = norm(name)
  return lulibre.sql([[
    WITH l AS (SELECT book, group_concat(value, ', ') AS v
                 FROM (SELECT book, value FROM custom.data WHERE field = ?1 AND book > 0 ORDER BY book, ord) GROUP BY book),
         c AS (SELECT book, group_concat(value, ', ') AS v
                 FROM (SELECT book, value FROM cal_values WHERE label = ?2 ORDER BY book, ord) GROUP BY book)
    SELECT b.id AS book, coalesce(l.v, '') AS lulibre, coalesce(c.v, '') AS calibre
      FROM books b LEFT JOIN l ON l.book = b.id LEFT JOIN c ON c.book = b.id
     WHERE (l.v IS NOT NULL OR c.v IS NOT NULL) AND l.v IS NOT c.v ORDER BY b.id]], name, M.label(name))
end

-- the queued job (lulibre.offline) that would run `command` on a field's column
local function queued(command, name)
  for _, j in ipairs(require("lulibre.offline").jobs()) do
    if j.argv[1] == command and j.argv[2] == M.label(name) then return j.id end
  end
end

--- Where a field stands with calibre: { state = "lulibre" } (calibre has no
-- column for it), { state = "waiting", job = id } (one is queued), or
-- { state = "calibre", differ = n } (n books' values are not calibre's;
-- removing = id when the column's removal is queued).
function M.state(name)
  name = norm(name)
  if M.column(name) then
    return { state = "calibre", differ = #M.differing(name), removing = queued("remove_custom_column", name) }
  end
  local job = queued("add_custom_column", name)
  if job then return { state = "waiting", job = job } end
  return { state = "lulibre" }
end

--- Ask calibre for a column for a field. Queued: it is made the next time
-- the content server is stopped (lulibre.offline). opts.heading: the
-- column's heading in calibre (default: the name); opts.datatype: calibre's
-- type when the field's own will not do (int for a chapter's number).
-- Returns the job's id, or nil and why not.
function M.add_column(name, opts)
  opts = opts or {}
  name = norm(name)
  local label = M.label(name)
  if not label:match("^%l[%l%d_]*$") then
    return nil, ("calibre's column names are a letter, then letters, figures or _: %s will not do"):format(name)
  end
  local st = M.state(name)
  if st.state == "calibre" then return nil, ("calibre has a column %s already"):format(name) end
  if st.state == "waiting" then return st.job end
  local spec = M.field(name) or { type = "text" }
  local argv = { "add_custom_column", label, opts.heading or label }
  if opts.datatype then
    argv[#argv + 1] = opts.datatype
  else
    for _, a in ipairs(M.DATATYPES[spec.type]) do argv[#argv + 1] = a end
  end
  return require("lulibre.offline").queue(argv, ("the calibre column %s"):format(name))
end

--- Ask calibre to remove a column: any of calibre's, lulibre's field or
-- not. calibre's values in it go with it; lulibre's own values of a field
-- stay. Queued like adding one. Returns the job's id, or nil and why not.
-- A column whose adding is still queued is not added instead: the id of
-- that job, and "cancelled".
function M.remove_column(name)
  name = norm(name)
  local offline = require "lulibre.offline"
  local adding = queued("add_custom_column", name)
  if adding then
    offline.cancel(adding)
    return adding, "cancelled"
  end
  if not M.column(name) then return nil, ("calibre has no column %s"):format(name) end
  local job = queued("remove_custom_column", name)
  if job then return job end
  return offline.queue({ "remove_custom_column", M.label(name), "--force" }, ("removing the calibre column %s"):format(name))
end

--- How many books have a value in calibre's column for a field.
function M.calibre_books(name)
  return lulibre.sql("SELECT count(DISTINCT book) AS n FROM cal_values WHERE label = ?", M.label(name))[1].n
end

--- calibredb's spelling of a field's value.
function M.wire(name, value)
  local spec = M.field(name) or { type = "text" }
  -- noon UTC: the same day in calibre's local time, wherever it is (midnight
  -- UTC shows as the evening before west of Greenwich), and in the mirror
  if spec.type == "date" and value:match("^%d%d%d%d%-%d%d%-%d%d$") then return value .. "T12:00:00+00:00" end
  return value
end

--- Copy a field's values into calibre's column, for the books where they
-- differ (M.differing): lulibre's value wins. Waits. Returns
-- { copied=, failed={ {id=, error=}, ... } }.
function M.push(name)
  name = norm(name)
  if not M.column(name) then error(("calibre has no column %s yet"):format(name), 0) end
  local edit = require "lulibre.edit"
  local out = { copied = 0, failed = {} }
  lulibre.each(M.differing(name), function(d)
    local args = edit.calibredb()
    for _, a in ipairs { "set_custom", M.label(name), tostring(d.book), M.wire(name, d.lulibre) } do args[#args + 1] = a end
    local r, err = lulibre.system(args, { timeout = 120000 })
    if r and r.code == 0 then
      out.copied = out.copied + 1
    else
      out.failed[#out.failed + 1] = { id = d.book, error = edit.failure(r, err) }
    end
  end, { jobs = edit.write_jobs(), progress = "copying " .. name })
  if out.copied > 0 then edit.after_direct() end
  lulibre.reload()
  return out
end

return M
