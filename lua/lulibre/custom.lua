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
local function load()
  if declared then return declared end
  declared = {}
  for name, spec in pairs(M.builtin) do declared[name] = spec end
  for _, r in ipairs(lulibre.sql("SELECT name, type, help FROM custom.fields")) do
    declared[r.name] = { type = r.type, help = r.help }
  end
  return declared
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

return M
