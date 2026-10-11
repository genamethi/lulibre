-- Proposed changes waiting for a decision. Scripts add them; :review shows
-- them; accepted ones are applied as one batch. They are kept in the index
-- database, so a long review can be spread over several sessions.
local edit = require "lulibre.edit"

local M = {}

--- Propose a change. opts: op ("set", "add", "remove"), source, confidence,
-- note. A title that arrives in capitals is proposed in title case, as the
-- option title_case allows, unless it was typed (source "typed") or
-- opts.as_is is set. Returns true and the proposal's id, or false if the book already
-- has that value or the same proposal is already waiting (when this source
-- is surer than the one it came from, the waiting proposal is upgraded).
function M.add(id, field, value, opts)
  opts = opts or {}
  local op = opts.op or "set"
  local book = lulibre.book(id)
  if not book then return false end
  if field == "title" and op == "set" and opts.source ~= "typed" and not opts.as_is then
    value = require("lulibre.titlecase").proposed(value)
  end
  local ok, new = pcall(edit.resolve, book, field, op, value)
  if not ok then error(new, 2) end
  if new == edit.current(book, field) then return false end
  local dup = lulibre.store([[SELECT id, confidence, source FROM proposals WHERE book = ? AND field = ? AND op = ?
    AND value = ? AND status IN ('pending', 'accepted')]], id, field, op, value)[1]
  if dup then
    -- the same value from a surer source: the proposal takes that source's word
    if opts.confidence and opts.confidence > (dup.confidence or 0) then
      lulibre.store("UPDATE proposals SET confidence = ?, source = ? WHERE id = ?", opts.confidence,
        opts.source or dup.source, dup.id)
      return true, dup.id
    end
    return false
  end
  local _, _, pid = lulibre.store([[INSERT INTO proposals(book, field, op, value, source, confidence, created, note)
    VALUES(?, ?, ?, ?, ?, ?, ?, ?)]], id, field, op, value, opts.source, opts.confidence, os.time(), opts.note)
  return true, pid
end

-- Library books have positive ids and files staged from the sync folder
-- negative ones; scope ("library", "sync" or nil for both) picks a side.
-- Proposals for a book that is no longer there (removed since) are not listed.
local function side(scope)
  return (scope == "library" and " AND book > 0" or scope == "sync" and " AND book < 0" or "")
    .. " AND EXISTS (SELECT 1 FROM books b WHERE b.id = proposals.book)"
end

--- Proposals with the given status ("pending" and "accepted" when omitted),
-- by book, strongest first.
function M.list(status, scope)
  if status then
    return lulibre.store("SELECT * FROM proposals WHERE status = ?" .. side(scope) ..
      " ORDER BY abs(book), field, confidence DESC, id", status)
  end
  return lulibre.store("SELECT * FROM proposals WHERE status IN ('pending', 'accepted')" .. side(scope) ..
    " ORDER BY abs(book), field, confidence DESC, id")
end

function M.count(status, scope)
  return lulibre.store("SELECT count(*) AS n FROM proposals WHERE status = ?" .. side(scope), status or "pending")[1].n
end

function M.set_status(pid, status)
  lulibre.store("UPDATE proposals SET status = ? WHERE id = ?", status, pid)
end

function M.set_value(pid, value, op)
  lulibre.store([[UPDATE proposals SET value = ?, op = coalesce(?, op),
    source = CASE WHEN coalesce(source, '') LIKE '% (edited)' THEN source ELSE coalesce(source, '') || ' (edited)' END
    WHERE id = ?]], value, op, pid)
end

--- Accepting one proposal for a single-valued field settles the others for
-- that book and field.
function M.accept(p)
  if p.op == "set" then
    lulibre.store([[UPDATE proposals SET status = 'pending' WHERE book = ? AND field = ? AND op = 'set'
      AND status = 'accepted']], p.book, p.field)
  end
  M.set_status(p.id, "accepted")
end

--- Apply every accepted proposal as one batch. Waits. Returns edit.apply's
-- result; applied proposals are marked so, failed ones go back to pending.
-- only: a set of book ids ({ [id] = true }) to keep to; the rest stay accepted.
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

--- Drop proposals: by status, or everything not yet applied.
function M.clear(status)
  if status then lulibre.store("DELETE FROM proposals WHERE status = ?", status)
  else lulibre.store("DELETE FROM proposals WHERE status <> 'applied'") end
end

return M
