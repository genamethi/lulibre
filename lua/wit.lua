--- Wits: a value for a book's field, with the source that gave it, kept
-- until a review accepts or rejects it.
--
-- Per book and field the wits are in order, the first-ranked first; the
-- others are its alternatives. They are kept in the file path.witdb
-- (table `wits`), which the filter `is:proposed` reads.
--
--     local wit = require "wit"
--     wit.set(12, { { field = "title", value = "Knot Theory", source = "front", start = 41, stop = 52 } })
--     for _, f in ipairs(wit.get(12)) do print(f.field, f.alts[1].value) end
--     wit.accept(f.alts[1].id)
--
-- @library wit
local sql = require "sql"
local sqlite3 = require "lsqlite3"
local store = require "store"
local trust = require "trust"

local M = {}

local db

-- a statement on the file, opened on first use; the file and its table
-- are made with the index
local function run(query, ...)
  db = db or sql.open(setman.get("path.witdb"), sqlite3.OPEN_READWRITE)
  return sql.run(db, query, ...)
end

local function joined(list)
  return list and table.concat(list, ",") or nil
end

--- Replaces a book's wits. Each is `{ field=, value=, source=, score=,
-- agree=, disagree=, file=, start=, stop= }`, agree and disagree lists of
-- source names; a field's wits are ranked in the order given.
-- @tparam integer book
-- @tparam {table,...} wits
function M.set(book, wits)
  run("BEGIN IMMEDIATE")
  local ok, err = pcall(function()
    run("DELETE FROM wits WHERE book = ?", book)
    local alt = {}
    for _, w in ipairs(wits) do
      alt[w.field] = (alt[w.field] or 0) + 1
      run("INSERT INTO wits(book, field, value, source, alt, score, agree, disagree, file, start, stop, ts)"
          .. " VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, strftime('%s', 'now'))",
          book, w.field, w.value, w.source, alt[w.field], w.score, joined(w.agree), joined(w.disagree),
          w.file, w.start, w.stop)
    end
  end)
  run(ok and "COMMIT" or "ROLLBACK")
  if not ok then error(err, 2) end
end

--- A book's wits, per field: the first-ranked and its alternatives.
-- @tparam integer book
-- @treturn {table,...} `{ {field=, alts = { {id=, value=, source=, score=, agree=, disagree=, start=, stop=}, ... } }, ... }`
function M.get(book)
  local out, by = {}, {}
  for _, row in ipairs(run("SELECT id, field, value, source, score, agree, disagree, start, stop FROM wits"
                           .. " WHERE book = ? ORDER BY field, alt", book)) do
    local f = by[row.field]
    if not f then
      f = { field = row.field, alts = {} }
      by[row.field] = f
      out[#out + 1] = f
    end
    f.alts[#f.alts + 1] = row
  end
  return out
end

--- The change a decision on a wit makes: the library's field, with the
-- wit's provenance (design 27). An identifier (identifier:TYPE) is added
-- to the book's identifiers as TYPE:value; tags are added to its own.
local function change(w, value)
  local field, kind = trust.field(w.field), w.field:match("^identifier:(.+)")
  local function written(v) return kind and v and kind .. ":" .. v or v end
  return { book = w.book, field = field, value = written(value), proposal = w.id, proposed = written(w.value),
           source = w.source, op = (field == "identifiers" or field == "tags") and value and "add" or "set" }
end

local function row(id)
  return run("SELECT id, book, field, value, source FROM wits WHERE id = ?", id)[1]
end

-- the decision applied, and the field's wits gone
local function decide(w, value, label)
  local batch, err = store.apply({ change(w, value) }, label)
  if err then return nil, err end
  run("DELETE FROM wits WHERE book = ? AND field = ?", w.book, w.field)
  return batch
end

--- Accepts a wit, as it is or edited, as an operation of the library;
-- waits for it. Returns the batch, or nil and why.
-- @tparam integer id
-- @tparam[opt] string value the edited value
function M.accept(id, value)
  local w = row(id)
  if not w then return nil, "no wit " .. id end
  return decide(w, value or w.value, "review: " .. w.field)
end

--- Rejects a wit: the field keeps its value, and the journal keeps the
-- decision, for the source's track record (trust).
-- @tparam integer id
function M.reject(id)
  local w = row(id)
  if not w then return nil, "no wit " .. id end
  return decide(w, nil, "review: " .. w.field .. " rejected")
end

return M
