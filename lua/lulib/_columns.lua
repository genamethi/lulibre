--- :columns: calibre columns for lulibre's own fields #partof (the whole a book
-- is part of), #part (its number in it) and #parts (how many there are), so that
-- calibre shows them and can sort and search by them. calibre makes a column only
-- while nothing holds the library, so they wait for that (:offline).
--
--     :columns          make them
--     :columns push     copy lulibre's values into them
--     :columns remove   take them out of calibre (lulibre keeps its values)
--
-- @library lulib._columns
local sql = require "sql"
local sqlite3 = require "lsqlite3"
local store = require "store"

local M = {}

--- The columns: `{ label, heading, datatype }`.
M.list = { { "partof", "Part of", "text" }, { "part", "Part", "float" }, { "parts", "Parts", "int" } }

-- the columns calibre has now, by label
local function have()
  local db = sql.open(setman.get("path.indexdb"), sqlite3.OPEN_READONLY)
  local out = {}
  for _, r in ipairs(sql.run(db, "SELECT label FROM cal_columns")) do out[r.label] = true end
  db:close()
  return out
end

--- Copies lulibre's values of a field into calibre's column, where they differ;
-- how many, and why not all.
function M.push(label)
  local custom = sql.open(setman.get("path.customdb"), sqlite3.OPEN_READONLY)
  local values = sql.run(custom, "SELECT book, group_concat(value, ',') AS value FROM data WHERE field = ? GROUP BY book", "#" .. label)
  custom:close()
  local index = sql.open(setman.get("path.indexdb"), sqlite3.OPEN_READONLY)
  local there = {}
  for _, r in ipairs(sql.run(index, "SELECT book, group_concat(value, ',') AS value FROM cal_values WHERE label = ? GROUP BY book", label)) do
    there[r.book] = r.value
  end
  index:close()
  local n, why = 0, nil
  for _, r in ipairs(values) do
    if r.book > 0 and there[r.book] ~= r.value then
      local b, err = store.command({ "set_custom", label, tostring(r.book), r.value }, { label = "columns: push " .. label, when = "any" })
      if b then n = n + 1 else why = why or err end
    end
  end
  return n, why
end

--- :columns's work.
-- @tparam string verb "", "push" or "remove"
function M.run(verb)
  local cols = have()
  if verb == "push" then
    local total, why = 0, nil
    for _, c in ipairs(M.list) do
      if cols[c[1]] then
        local n, err = M.push(c[1])
        total, why = total + n, why or err
      else
        why = why or ("calibre has no column %s yet: :columns makes it"):format(c[1])
      end
    end
    store.reload()
    return uiman.notify(("%d value%s copied%s"):format(total, total == 1 and "" or "s", why and (": " .. tostring(why)) or ""), why and "error" or nil)
  end
  local queued = 0
  for _, c in ipairs(M.list) do
    if verb == "remove" and cols[c[1]] then
      taskman.spawn(function() store.command({ "remove_custom_column", "--force", c[1] }, { label = "the column #" .. c[1] .. " removed" }) end)
      queued = queued + 1
    elseif verb == "" and not cols[c[1]] then
      taskman.spawn(function() store.command({ "add_custom_column", c[1], c[2], c[3] }, { label = "the column #" .. c[1] }) end)
      queued = queued + 1
    end
  end
  uiman.notify(queued == 0 and "calibre's columns are as they should be already"
               or ("%d column change%s wait%s for nothing to hold the library: :offline shows them"):format(queued, queued == 1 and "" or "s", queued == 1 and "s" or ""))
end

return M
