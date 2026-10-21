--- Adds custom fields: metadata of your own, kept beside calibre's.
-- lulibre stores custom fields in a database of their own beside the index
-- (<index>.custom.db). Custom fields never change calibre's database, and
-- rebuilding the index keeps them. A custom field is named the way calibre
-- names a custom column (#partof), so the field can become a column later.
--
-- A custom field works like any other field. lulibre.edit writes custom
-- fields, so the journal records their changes, and undo and snapshots
-- restore them. Custom fields are proposed and reviewed, shown in the
-- preview, and can be used in filters: `#partof:handbook`, `#part:none`,
-- `has:#partof`.
--
-- A custom field can also have a calibre custom column of the same name.
-- lulibre then keeps its own values, which filters, the journal and undo
-- use, and writes every change to calibre's column too. calibre adds a
-- column only while the content server is stopped, so `add_column` queues
-- the request (see `lulibre.offline`). The preview shows when the column
-- does not exist yet, and when calibre's values differ from lulibre's.
--
-- @module lulibre.custom
-- @usage
-- local custom = require "lulibre.custom"
-- custom.declare("#series2", { type = "text", help = "..." })   -- text | number | date | list
-- custom.fields()              --> { {name=, type=, help=, books=}, ... }
-- custom.get(id, "#partof")    --> its value as edits spell it ("" when none)
-- custom.all(id)               --> { ["#partof"] = "...", ... }
-- lulibre.apply{ { id = 12, field = "#partof", value = "Handbook of Algebra" } }   -- to change one
-- custom.add_column("#partof", { heading = "Part of" })   -- queue calibre's column
-- custom.state("#partof")      --> { state = "lulibre" | "waiting" | "calibre", differ = n, removing = id }
-- custom.push("#partof")       -- copy lulibre's values into calibre's column
local M = {}

--- The types a field can have: text, number, date, list.
M.TYPES = { text = true, number = true, date = true, list = true }

--- The fields lulibre itself uses, declared at startup: #partof, #part, #parts.
M.builtin = {
  ["#partof"] = { type = "text", help = "the whole this is a part of: the handbook a chapter is from, the Stacks project" },
  ["#part"] = { type = "number", help = "its number in that whole (a chapter's)" },
  ["#parts"] = { type = "number", help = "how many parts the whole has" },
}

--- Returns a field's name as it is stored: lower case, starting with "#".
-- @function norm
-- @tparam string name "partof", "#PartOf" ...
-- @treturn string "#partof"
local function norm(name)
  name = tostring(name or "")
  if name:sub(1, 1) ~= "#" then name = "#" .. name end
  return name:lower()
end
M.norm = norm

--- Returns true if a field name is a custom field's (#something).
-- @tparam any field
-- @treturn boolean
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

--- Declares a field, or changes its declaration.
-- @tparam string name
-- @tparam table spec `{ type=, help= }`, where type is one of `TYPES`
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

--- Returns a field's declaration.
-- @tparam string name
-- @treturn table|nil `{ type=, help= }`, or nil if the field is not declared
function M.field(name)
  return load()[norm(name)]
end

--- Returns every field that is declared or has values, with how many books have it.
-- @treturn {table,...} `{ name=, type=, help=, books= }`
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

--- Returns a book's value of a field, in the form changes use.
-- @tparam integer id
-- @tparam string name
-- @treturn string "" if the book has no value; a list's items are joined by ", "
function M.get(id, name)
  local vals = {}
  for _, r in ipairs(lulibre.sql("SELECT value FROM custom.data WHERE book = ? AND field = ? ORDER BY ord", id, norm(name))) do
    vals[#vals + 1] = r.value
  end
  return table.concat(vals, ", ")
end

--- Returns a book's values of every custom field.
-- @tparam integer id
-- @treturn table `{ ["#partof"] = "...", ... }`
function M.all(id)
  local out = {}
  for _, r in ipairs(lulibre.sql("SELECT field, value FROM custom.data WHERE book = ? ORDER BY field, ord", id)) do
    out[r.field] = out[r.field] and (out[r.field] .. ", " .. r.value) or r.value
  end
  return out
end

--- Converts a value to its field's type, as `lulibre.edit.resolve` does
-- for a set. A list's items keep the order given.
-- @tparam string name
-- @tparam string value
-- @treturn string
-- @raise if the value can't be converted to the field's type
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

--- Writes a book's value of a field. `lulibre.edit` calls this. Make
-- changes through `lulibre.edit`, so that they are journaled.
-- @tparam integer id
-- @tparam string name
-- @tparam string|nil value in the form `get` returns; "" or nil removes the value
-- @tparam[opt] string source
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

--- Moves a book's custom fields to its new id, for example after a file is
-- added from the sync folder or a book is restored from the recycle bin.
-- @tparam integer from
-- @tparam integer to
function M.move(from, to)
  lulibre.store("UPDATE custom.data SET book = ? WHERE book = ?", to, from)
end

-- ---- in calibre too ----

--- calibre's type for each lulibre type, in the form calibredb's `add_custom_column` takes.
M.DATATYPES = { text = { "text" }, number = { "float" }, date = { "datetime" }, list = { "text", "--is-multiple" } }

--- Returns calibre's label for a field: its name without the #.
-- @tparam string name
-- @treturn string
function M.label(name)
  return norm(name):sub(2)
end

--- Returns calibre's column for a field.
-- @tparam string name
-- @treturn table|nil `{ label=, name=, datatype=, multiple= }`, or nil if calibre has no such column
function M.column(name)
  return lulibre.sql("SELECT label, name, datatype, multiple FROM cal_columns WHERE label = ?", M.label(name))[1]
end

--- Returns the books whose value of a field differs from calibre's column.
-- @tparam string name
-- @treturn {table,...} `{ book=, lulibre=, calibre= }`, values in the form `get` returns ("" for none)
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

--- Returns whether calibre has a column for a field.
-- @tparam string name
-- @treturn table `{ state = "lulibre" }` if calibre has no column, `{ state = "waiting", job = id }`
-- if one is queued, or `{ state = "calibre", differ = n }` if calibre has one and n books' values
-- differ from it. `removing = id` is set if the column's removal is queued.
function M.state(name)
  name = norm(name)
  if M.column(name) then
    return { state = "calibre", differ = #M.differing(name), removing = queued("remove_custom_column", name) }
  end
  local job = queued("add_custom_column", name)
  if job then return { state = "waiting", job = job } end
  return { state = "lulibre" }
end

--- Queues a request for calibre to add a column for a field. The column is
-- added the next time the content server is stopped (see `lulibre.offline`).
-- @tparam string name
-- @tparam[opt] table opts `heading` (the column's heading in calibre; the name by default),
-- `datatype` (calibre's type, if the field's own does not fit, such as int for a chapter's number)
-- @treturn[1] integer the job's id
-- @treturn[2] nil
-- @treturn[2] string why not
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

--- Queues a request for calibre to remove a column, whether or not it is a
-- lulibre field. calibre's values in the column are removed with it, and
-- lulibre's own values of the field stay. If the column's addition is still
-- queued, that job is cancelled instead.
-- @tparam string name
-- @treturn[1] integer the job's id
-- @treturn[2] integer the adding job's id
-- @treturn[2] string "cancelled"
-- @treturn[3] nil
-- @treturn[3] string why not
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

--- Returns how many books have a value in calibre's column for a field.
-- @tparam string name
-- @treturn integer
function M.calibre_books(name)
  return lulibre.sql("SELECT count(DISTINCT book) AS n FROM cal_values WHERE label = ?", M.label(name))[1].n
end

--- Returns a field's value in the form calibredb takes. A date is written
-- at noon UTC, so it is the same day in every time zone calibre shows it in.
-- @tparam string name
-- @tparam string value
-- @treturn string
function M.wire(name, value)
  local spec = M.field(name) or { type = "text" }
  -- noon UTC: the same day in calibre's local time, wherever it is (midnight
  -- UTC shows as the evening before west of Greenwich), and in the mirror
  if spec.type == "date" and value:match("^%d%d%d%d%-%d%d%-%d%d$") then return value .. "T12:00:00+00:00" end
  return value
end

--- Copies a field's values into calibre's column, for the books where they
-- differ (see `differing`), and waits. lulibre's value replaces calibre's.
-- @tparam string name
-- @treturn table `{ copied=, failed = { {id=, error=}, ... } }`
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
