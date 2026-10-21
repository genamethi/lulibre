--- Stores proposed changes until you accept or reject them in review.
-- Scripts add proposals, and `:review` shows them. lulibre writes the
-- accepted proposals together as one batch. Proposals are stored in the
-- index, so you can finish a review in a later session.
--
-- A proposal is a row of the `proposals` table: `{ id=, book=, field=,
-- op=, value=, source=, confidence=, status=, created=, note=, asked= }`.
-- A proposal's status is "pending", "accepted", "applied", "rejected" or
-- "barred".
--
-- @module lulibre.proposals
-- @usage
-- local proposals = require "lulibre.proposals"
-- proposals.add(12, "title", "Knot Theory", { source = "title page", confidence = 0.8 })
--   --> true, 341
-- proposals.count()            --> pending proposals shown in review
-- print(proposals.to_review()) --> "1 proposal waits. Press gr to review."
local edit = require "lulibre.edit"

local M = {}

-- ---- what is shown: propose_min ----
-- A proposal under the option propose_min (learned subjects: learned_tags_min)
-- is kept but not shown: review leaves it out, nothing counts it as
-- waiting, and the summaries say how many there are. Lowering the option
-- shows them; a typed proposal, one without a confidence, and one asked for
-- (opts.asked: taking a copy's values) are always shown.

--- Returns true if the source is a subject learned from the library.
-- @tparam string source a proposal's source
-- @treturn boolean
function M.learned(source)
  source = source or ""
  return source:find("^learned:") ~= nil or source:find("^shares references with ") ~= nil
end

--- Returns the lowest confidence at which a proposal from this source is
-- shown: `propose_min`, or `learned_tags_min` for a learned subject.
-- @tparam string source
-- @treturn number 0 to 1
function M.floor(source)
  local pct = M.learned(source) and lulibre.o.learned_tags_min or lulibre.o.propose_min
  return (tonumber(pct) or 0) / 100
end

--- Returns true if review shows the proposal. A proposal is shown if it is
-- accepted, typed, asked for, has no confidence, or reaches its source's
-- `floor`.
-- @tparam table pr a proposal: `confidence`, `source`, `status`, `asked`
-- @treturn boolean
function M.shown(pr)
  return pr.status == "accepted" or pr.confidence == nil or pr.source == "typed" or pr.asked == 1
    or pr.confidence >= M.floor(pr.source) - 1e-9
end

--- Returns the test `shown` makes, as SQL, for a query of the `proposals` table.
-- @function shown_sql
-- @treturn string a condition beginning " AND (", to append to a WHERE clause
local function shown_sql()
  local p = (tonumber(lulibre.o.propose_min) or 0) / 100
  local l = (tonumber(lulibre.o.learned_tags_min) or 0) / 100
  return ([[ AND (status = 'accepted' OR confidence IS NULL OR source = 'typed' OR asked = 1 OR confidence >= CASE
    WHEN source LIKE 'learned:%%' OR source LIKE 'shares references with %%' THEN %.6f ELSE %.6f END - 1e-9)]]):format(l, p)
end
M.shown_sql = shown_sql

--- Proposes a change to a book.
--
-- A title in capitals is converted to title case (if `title_case` allows)
-- and its mathematics to Unicode (if `math_notation` allows). Typed values
-- and `opts.as_is` skip both conversions.
--
-- A value you barred for this book and field (N in review) is not proposed
-- again. Neither is a rejected value when `review_reject` is "always".
-- Typed values and `opts.again` override both.
--
-- If the same proposal is already waiting and the new source is more
-- confident, the waiting proposal takes the new source and confidence.
--
-- Proposing a new value removes the hidden proposals for the same book and
-- field, unless `propose_held` is "keep". Subjects and identifiers are
-- exempt, since each value adds to the others instead of replacing them.
-- @tparam integer id the book
-- @tparam string field a field `lulibre.edit` knows ("title", "authors", "tags", "#custom" ...)
-- @tparam string value
-- @tparam[opt] table opts `op` ("set", the default; "add", "remove"), `source`, `confidence` (0 to 1),
-- `note`, `as_is`, `again`, `asked` (asked for: shown whatever `propose_min` says)
-- @treturn[1] boolean true: proposed and shown
-- @treturn[1] integer the proposal's id
-- @treturn[2] boolean false: the book has the value, the same proposal waits, or the value was barred
-- @treturn[3] boolean false: stored but hidden, under `propose_min`
-- @treturn[3] integer its id
-- @treturn[3] string "held"
function M.add(id, field, value, opts)
  opts = opts or {}
  local op = opts.op or "set"
  local book = lulibre.book(id)
  if not book then return false end
  -- only comments run over lines; a line break anywhere else is a record's layout
  if field ~= "comments" and type(value) == "string" and value:find("[\r\n\t]") then
    value = value:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
  end
  if field == "title" and op == "set" and opts.source ~= "typed" and not opts.as_is then
    -- in title case, and its mathematics in Unicode (option math_notation)
    value = require("lulibre.notation").title(value, require("lulibre.titlecase").proposed)
  end
  local ok, new = pcall(edit.resolve, book, field, op, value)
  if not ok then error(new, 2) end
  if new == edit.current(book, field) then return false end
  local dup = lulibre.store([[SELECT id, confidence, source, asked FROM proposals WHERE book = ? AND field = ? AND op = ?
    AND value = ? AND status IN ('pending', 'accepted')]], id, field, op, value)[1]
  if not dup and not opts.again and opts.source ~= "typed" then
    local barred = lulibre.o.review_reject == "always" and "('barred', 'rejected')" or "('barred')"
    local said_no = lulibre.store([[SELECT 1 AS x FROM proposals WHERE book = ? AND field = ? AND op = ?
      AND value = ? AND status IN ]] .. barred .. " LIMIT 1", id, field, op, value)[1]
    if said_no then return false end
  end
  if dup and opts.asked and dup.asked ~= 1 then
    -- asked for now: shown from here on
    lulibre.store("UPDATE proposals SET asked = 1 WHERE id = ?", dup.id)
    return true, dup.id
  end
  if dup then
    -- the same value from a surer source: the proposal takes that source's word
    if opts.confidence and opts.confidence > (dup.confidence or 0) then
      lulibre.store("UPDATE proposals SET confidence = ?, source = ? WHERE id = ?", opts.confidence,
        opts.source or dup.source, dup.id)
      if M.shown({ confidence = opts.confidence, source = opts.source or dup.source }) then
        return true, dup.id
      end
      return false, dup.id, "held"
    end
    return false
  end
  if lulibre.o.propose_held ~= "keep" and op == "set" and field ~= "tags" and field ~= "identifiers" then
    -- the proposals for this field nobody is shown give way to the new one
    local gone = {}
    for _, q in ipairs(lulibre.store([[SELECT id, confidence, source, status, asked FROM proposals
      WHERE book = ? AND field = ? AND op = 'set' AND status = 'pending']], id, field)) do
      if not M.shown(q) then gone[#gone + 1] = q.id end
    end
    if #gone > 0 then lulibre.store(("DELETE FROM proposals WHERE id IN (%s)"):format(table.concat(gone, ","))) end
  end
  local _, _, pid = lulibre.store([[INSERT INTO proposals(book, field, op, value, source, confidence, created, note, asked)
    VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)]], id, field, op, value, opts.source, opts.confidence, os.time(), opts.note,
    opts.asked and 1 or nil)
  if not M.shown({ confidence = opts.confidence, source = opts.source, asked = opts.asked and 1 or nil }) then
    return false, pid, "held"
  end
  return true, pid
end

-- Library books have positive ids and files staged from the sync folder
-- negative ones; scope ("library", "sync" or nil for both) picks a side.
-- Proposals for a book that is no longer there (removed since) are not listed.
local function side(scope)
  return (scope == "library" and " AND book > 0" or scope == "sync" and " AND book < 0" or "")
    .. " AND EXISTS (SELECT 1 FROM books b WHERE b.id = proposals.book)"
end

--- Returns the proposals with a status, by book, most confident first.
-- Pending proposals under `propose_min` are left out (`held` lists them),
-- and so are proposals for books that have been removed.
-- @tparam[opt] string status "pending" and "accepted" when not given
-- @tparam[opt] string scope "library" (positive ids), "sync" (files staged from the sync folder,
-- negative ids), or nil for both
-- @treturn {table,...} the proposals' rows
function M.list(status, scope)
  if status then
    return lulibre.store("SELECT * FROM proposals WHERE status = ?" .. side(scope) ..
      (status == "pending" and shown_sql() or "") .. " ORDER BY abs(book), field, confidence DESC, id", status)
  end
  return lulibre.store("SELECT * FROM proposals WHERE status IN ('pending', 'accepted')" .. side(scope) ..
    shown_sql() .. " ORDER BY abs(book), field, confidence DESC, id")
end

--- Returns how many proposals have a status. Pending proposals under
-- `propose_min` are not counted.
-- @tparam[opt] string status "pending" when not given
-- @tparam[opt] string scope as for `list`
-- @treturn integer
function M.count(status, scope)
  status = status or "pending"
  return lulibre.store("SELECT count(*) AS n FROM proposals WHERE status = ?" .. side(scope) ..
    (status == "pending" and shown_sql() or ""), status)[1].n
end

--- Returns the pending proposals that are stored but hidden, because they are
-- under `propose_min` (or `learned_tags_min`).
-- @tparam[opt] string scope as for `list`
-- @treturn {table,...}
function M.held(scope)
  local out = {}
  for _, pr in ipairs(lulibre.store("SELECT * FROM proposals WHERE status = 'pending'" .. side(scope) ..
      " ORDER BY abs(book), field, confidence DESC, id")) do
    if not M.shown(pr) then out[#out + 1] = pr end
  end
  return out
end

--- Returns a sentence about what waits for review, such as "300 proposals
-- wait. Press gr to review.", followed by how many are hidden under
-- `propose_min`. Every script that proposes ends its summary with this
-- sentence. You can replace this function.
-- @tparam[opt] string prefix put before the sentence, if the sentence is not empty
-- @treturn string "" when none wait and none are held back
function M.to_review(prefix)
  local n, held, learned = M.count("pending"), 0, 0
  for _, pr in ipairs(M.held()) do
    if M.learned(pr.source) then learned = learned + 1 else held = held + 1 end
  end
  local out = {}
  if n > 0 then
    out[#out + 1] = ("%d proposal%s wait%s. Press %s to review."):format(n, n == 1 and "" or "s",
      n == 1 and "s" or "", lulibre.hint("review"))
  end
  if held > 0 then
    out[#out + 1] = ("%d %s under propose_min (%s%%) and not shown."):format(held, held == 1 and "is" or "are",
      tostring(lulibre.o.propose_min))
  end
  if learned > 0 then
    out[#out + 1] = ("%d learned subject%s under learned_tags_min (%s%%) not shown."):format(learned,
      learned == 1 and "" or "s", tostring(lulibre.o.learned_tags_min))
  end
  if #out == 0 then return "" end
  return (prefix or "") .. table.concat(out, " ")
end

--- Sets a proposal's status.
-- @tparam integer pid the proposal's id
-- @tparam string status "pending", "accepted", "applied", "rejected", "barred"
function M.set_status(pid, status)
  lulibre.store("UPDATE proposals SET status = ? WHERE id = ?", status, pid)
end

--- Changes a proposal's value, and adds " (edited)" to its source.
-- @tparam integer pid the proposal's id
-- @tparam string value
-- @tparam[opt] string op the operation, when it changes
function M.set_value(pid, value, op)
  lulibre.store([[UPDATE proposals SET value = ?, op = coalesce(?, op),
    source = CASE WHEN coalesce(source, '') LIKE '% (edited)' THEN source ELSE coalesce(source, '') || ' (edited)' END
    WHERE id = ?]], value, op, pid)
end

--- Accepts a proposal. For a field that holds one value (op "set"), any
-- other accepted proposal for the same book and field goes back to pending.
-- @tparam table p the proposal: `id`, `book`, `field`, `op`
function M.accept(p)
  if p.op == "set" then
    lulibre.store([[UPDATE proposals SET status = 'pending' WHERE book = ? AND field = ? AND op = 'set'
      AND status = 'accepted']], p.book, p.field)
  end
  M.set_status(p.id, "accepted")
end

--- Writes every accepted proposal as one batch, and waits until done.
-- Written proposals are marked applied and failed ones go back to pending.
-- Pending proposals that now match the library are marked applied too.
-- @tparam[opt] string scope as for `list`
-- @tparam[opt] table only a set of book ids, `{ [id] = true }`, to keep to; the rest stay accepted
-- @treturn table `lulibre.edit.apply`'s result
function M.apply_accepted(scope, only)
  local accepted = M.list("accepted", scope)
  if only then
    local kept = {}
    for _, p in ipairs(accepted) do
      if only[p.book] then kept[#kept + 1] = p end
    end
    accepted = kept
  end
  local changes = {}
  for i, p in ipairs(accepted) do
    changes[i] = { id = p.book, field = p.field, value = p.value, op = p.op }
  end
  local r = edit.apply(changes, { label = "review" })
  local failed = {}
  for _, f in ipairs(r.failed) do failed[f.id] = true end
  for _, p in ipairs(accepted) do
    M.set_status(p.id, failed[p.book] and "pending" or "applied")
  end
  -- anything still pending that the library now already says is settled too
  for _, p in ipairs(M.list("pending", scope)) do
    local book = lulibre.book(p.book)
    if not book or edit.resolve(book, p.field, p.op, p.value) == edit.current(book, p.field) then
      M.set_status(p.id, "applied")
    end
  end
  return r
end

--- Returns true if the proposal would replace a value the book has, rather
-- than fill an empty field or add to a list. A junk value, such as a file
-- name used as a title, counts as empty.
-- @tparam table p the proposal
-- @treturn boolean
function M.replaces(p)
  if p.op ~= "set" then return false end
  local book = lulibre.book(p.book)
  if not book then return false end
  -- a value that is plainly not one (a file name for a title) has no claim to stay
  return not require("lulibre.propose").is_gap(p.field, edit.current(book, p.field), p.book)
end

--- Deletes the proposals with a status, or all that are not applied.
-- @tparam[opt] string status
function M.clear(status)
  if status then lulibre.store("DELETE FROM proposals WHERE status = ?", status)
  else lulibre.store("DELETE FROM proposals WHERE status <> 'applied'") end
end

return M
