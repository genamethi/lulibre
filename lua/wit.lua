--- Wits: a value for a book's field, with the source that gave it, kept
-- until a review writes or rejects it.
--
-- Per book and field the wits are in order, the first-ranked first; the
-- others are its alternatives. They belong to a review, and each review has
-- its own: its proposals and what is marked on them. Accepting and rejecting
-- only mark; `write` does what is marked and takes it out of that review, and
-- no other review changes. One review is the current one, which proposing
-- adds to; `open` makes another current. They are kept in the file path.witdb
-- (tables `wits` and `reviews`), which the filter `is:proposed` reads.
--
--     local wit = require "wit"
--     wit.set(12, { { field = "title", value = "Knot Theory", source = "front", start = 41, stop = 52 } })
--     for _, f in ipairs(wit.get(12)) do print(f.field, f.alts[1].value) end
--     wit.accept(f.alts[1].id)
--     wit.write()
--
-- @library wit
local bookman = require "bookman"
local mesr = require "mesr"
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

local function transaction(fn)
  run("BEGIN IMMEDIATE")
  local ok, err = pcall(fn)
  run(ok and "COMMIT" or "ROLLBACK")
  if not ok then error(err, 3) end
end

local function joined(list)
  return list and table.concat(list, ",") or nil
end

--- The current review, made if there is none yet.
-- @treturn integer
function M.current()
  local r = run("SELECT id FROM reviews ORDER BY opened DESC, id DESC LIMIT 1")[1]
  if r then return r.id end
  run("INSERT INTO reviews(opened) VALUES (1)")
  return run("SELECT MAX(id) AS id FROM reviews")[1].id
end

--- Makes a review the current one.
function M.open(review)
  run("UPDATE reviews SET opened = (SELECT MAX(opened) + 1 FROM reviews) WHERE id = ?", review)
end

--- Starts a new review, empty, and makes it the current one.
-- @tparam[opt] string name
-- @treturn integer
function M.new(name)
  run("INSERT INTO reviews(name, opened) VALUES (?, (SELECT COALESCE(MAX(opened), 0) + 1 FROM reviews))", name)
  return run("SELECT MAX(id) AS id FROM reviews")[1].id
end

--- Names a review.
function M.name(review, name)
  run("UPDATE reviews SET name = ? WHERE id = ?", name, review)
end

--- Discards a review: its proposals and what is marked on them.
function M.discard(review)
  transaction(function()
    run("DELETE FROM wits WHERE review = ?", review)
    run("DELETE FROM reviews WHERE id = ?", review)
  end)
end

--- The reviews, the current one first: `{ {id=, name=, books=, marked=}, ... }`.
function M.reviews()
  M.current()
  return run("SELECT r.id, r.name, COUNT(DISTINCT w.book) AS books, COUNT(w.decision) AS marked"
             .. " FROM reviews r LEFT JOIN wits w ON w.review = r.id"
             .. " GROUP BY r.id ORDER BY r.opened DESC, r.id DESC")
end

--- The books a review has shown proposals for, in the order they came.
-- @tparam[opt] table o `{ review=, deep= }`: deep, those with hidden ones too
function M.books(o)
  o = o or {}
  local out = {}
  for _, r in ipairs(run("SELECT book FROM wits WHERE review = ? AND (? OR NOT hidden) GROUP BY book ORDER BY MIN(id)",
                         o.review or M.current(), o.deep and 1 or 0)) do
    out[#out + 1] = r.book
  end
  return out
end

--- Replaces a book's wits in a review, keeping what is marked: a mark stays
-- on its value, or, when the value is no longer proposed, on the value and
-- its source added last. Each is `{ field=, value=, source=, score=, agree=,
-- disagree=, file=, start=, stop=, hidden= }`, agree and disagree lists of
-- source names; a field's wits are ranked in the order given.
-- @tparam integer book
-- @tparam {table,...} wits
-- @tparam[opt] integer review the current one by default
function M.set(book, wits, review)
  review = review or M.current()
  transaction(function()
    local marks, rewrites = {}, {}
    for _, m in ipairs(run("SELECT field, value, source, score, decision, edited, op FROM wits"
                           .. " WHERE review = ? AND book = ? AND (decision IS NOT NULL OR op IS NOT NULL) ORDER BY alt",
                           review, book)) do
      if m.op then rewrites[#rewrites + 1] = m
      elseif m.decision then marks[m.field .. "\0" .. m.value] = m end
    end
    run("DELETE FROM wits WHERE review = ? AND book = ?", review, book)
    local alt = {}
    local function insert(w, m)
      alt[w.field] = (alt[w.field] or 0) + 1
      run("INSERT INTO wits(review, book, field, value, source, alt, score, agree, disagree, file, start, stop, ts,"
          .. " hidden, decision, edited, op) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, strftime('%s', 'now'), ?, ?, ?, ?)",
          review, book, w.field, w.value, w.source, alt[w.field], w.score, joined(w.agree), joined(w.disagree),
          w.file, w.start, w.stop, w.hidden and 1 or 0, m and m.decision, m and m.edited, w.op)
    end
    local taken = {}
    for _, m in ipairs(rewrites) do
      insert(m, m)
      taken[m.field .. "\0" .. m.value] = true
    end
    for _, w in ipairs(wits) do
      local key = w.field .. "\0" .. w.value
      if not taken[key] then
        insert(w, marks[key])
        marks[key] = nil
      end
    end
    for _, m in pairs(marks) do insert(m, m) end
  end)
end

--- Adds a rewrite of a book's field to a review, first among the field's
-- values: `{ field=, value=, source= }`. Writing it sets the field to the value
-- whatever the field is. Making the book's proposals anew leaves it. Returns
-- true.
-- @tparam integer book
-- @tparam table w
-- @tparam[opt] integer review the current one by default
function M.add(book, w, review)
  review = review or M.current()
  transaction(function()
    run("DELETE FROM wits WHERE review = ? AND book = ? AND field = ? AND value = ?", review, book, w.field, w.value)
    local first = run("SELECT MIN(alt) AS alt FROM wits WHERE review = ? AND book = ? AND field = ?",
                      review, book, w.field)[1].alt or 1
    run("INSERT INTO wits(review, book, field, value, source, alt, score, ts, op)"
        .. " VALUES (?, ?, ?, ?, ?, ?, 1, strftime('%s', 'now'), 'set')",
        review, book, w.field, w.value, w.source, first - 1)
  end)
  return true
end

--- Every book's wits in a review at once, per book, as `get` gives them for
-- each: `{ [book] = { {field=, alts=}, ... } }`, and the books in the order they
-- came.
-- @tparam[opt] table o `{ review=, deep= }`
function M.all(o)
  o = o or {}
  local out, by = {}, {}
  for _, row in ipairs(run("SELECT id, book, field, value, source, score, agree, disagree, start, stop, hidden, decision, edited"
                           .. " FROM wits WHERE review = ? AND (? OR NOT hidden OR decision IS NOT NULL)"
                           .. " ORDER BY book, field, alt", o.review or M.current(), o.deep and 1 or 0)) do
    if not out[row.book] then
      out[row.book] = {}
      by[row.book] = {}
    end
    local f = by[row.book][row.field]
    if not f then
      f = { field = row.field, alts = {} }
      by[row.book][row.field] = f
      table.insert(out[row.book], f)
    end
    f.alts[#f.alts + 1] = row
  end
  return out, M.books(o)
end

--- A book's wits in a review, per field: the first-ranked and its
-- alternatives. Those a review doesn't show are left out, unless `deep`.
-- @tparam integer book
-- @tparam[opt] table o `{ review=, deep= }`
-- @treturn {table,...} `{ {field=, alts = { {id=, value=, source=, score=, agree=, disagree=, start=, stop=, hidden=,
-- decision=, edited=}, ... } }, ... }`
function M.get(book, o)
  o = o or {}
  local out, by = {}, {}
  for _, row in ipairs(run("SELECT id, field, value, source, score, agree, disagree, start, stop, hidden, decision, edited"
                           .. " FROM wits WHERE review = ? AND book = ? AND (? OR NOT hidden OR decision IS NOT NULL)"
                           .. " ORDER BY field, alt", o.review or M.current(), book, o.deep and 1 or 0)) do
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
           source = w.source, op = w.op or (field == "identifiers" or field == "tags") and value and "add" or "set" }
end

local function row(id)
  return run("SELECT id, review, book, field, value, source, op FROM wits WHERE id = ?", id)[1]
end

-- a mark on a wit, none left on the field's others
local function mark(id, decision, value)
  local w = row(id)
  if not w then return nil, "no wit " .. id end
  transaction(function()
    run("UPDATE wits SET decision = NULL, edited = NULL WHERE review = ? AND book = ? AND field = ?",
        w.review, w.book, w.field)
    if decision then run("UPDATE wits SET decision = ?, edited = ? WHERE id = ?", decision, value, id) end
  end)
  return true
end

--- Marks a wit accepted, as it is or edited. `write` writes it.
-- @tparam integer id
-- @tparam[opt] string value the edited value
function M.accept(id, value)
  return mark(id, "accept", value)
end

--- Marks a wit rejected. `write` keeps the decision in the journal, for the
-- source's track record (trust); the field keeps its value.
-- @tparam integer id
function M.reject(id)
  return mark(id, "reject")
end

--- Takes the mark off a field's wits.
-- @tparam integer id one of them
function M.unmark(id)
  return mark(id)
end

--- Writes what is marked in a review, as one operation of the library, and
-- takes the fields from the review; waits for it. Returns the batch and how
-- many fields it took, 0 and 0 with nothing marked, or nil and why.
-- @tparam[opt] integer review the current one by default
function M.write(review)
  review = review or M.current()
  local marked = run("SELECT id, book, field, value, source, decision, edited, op FROM wits"
                     .. " WHERE review = ? AND decision IS NOT NULL", review)
  if #marked == 0 then return 0, 0 end
  local changes = {}
  for i, w in ipairs(marked) do
    changes[i] = change(w, w.decision == "accept" and (w.edited or w.value) or nil)
  end
  local batch, err = store.apply(changes, "review")
  if err then return nil, err end
  transaction(function()
    for _, w in ipairs(marked) do
      run("DELETE FROM wits WHERE review = ? AND book = ? AND field = ?", review, w.book, w.field)
    end
  end)
  return batch, #marked
end

--- A book's proposals, in every review, under another book: a file taken
-- into the library goes from its staged id to its id there.
function M.move(from, to)
  run("UPDATE wits SET book = ? WHERE book = ?", to, from)
end

--- A field as the record has it now: bookman's, or for identifier:TYPE the
-- identifier of that type.
function M.now(book, field)
  local kind = field:match("^identifier:(.+)")
  if not kind then return bookman.get(book, field) end
  local b = bookman.get(book)
  return b and b.idents and b.idents[kind] or ""
end

--- Drops from a review the proposals whose value the record now holds, unless
-- marked. Returns how many.
-- @tparam[opt] integer review the current one by default
function M.prune(review)
  review = review or M.current()
  local n = 0
  transaction(function()
    for _, w in ipairs(run("SELECT id, book, field, value FROM wits WHERE review = ? AND decision IS NULL", review)) do
      local now = M.now(w.book, w.field)
      if now and now ~= "" and mesr.cmp(w.field, w.value, now) == "equal" then
        run("DELETE FROM wits WHERE id = ?", w.id)
        n = n + 1
      end
    end
  end)
  return n
end

return M
