--- A parse's track record, derived from the journal and never accumulated
-- (design 20, 21).
--
-- Each review decision (a journal row with a proposal) scores the field's
-- value as the record stands now against the value as proposed, by
-- lulibre.similar: 1 as proposed, 0 rejected, between for an edit. So an
-- undone or later corrected decision counts as such. A record is held near
-- the prior until its decisions accumulate, and every record is the prior
-- until the journal holds the setting track_after's number of decisions
-- across every parse.
--
-- @library lulibre.track
local similar = require "lulibre.similar"

local M = {}

--- The neutral record.
M.prior = 0.5
--- How many decisions the prior weighs as.
M.prior_weight = 5

--- The library field a proposal's field is written to, and the kind its
-- values are compared as.
M.library_field = { title = "title", authors = "authors", publisher = "publisher", series = "series",
                    year = "pubdate", tags = "tags" }
local kinds = { title = "text", authors = "people", publisher = "text", series = "text", pubdate = "date",
                tags = "tags", identifiers = "ident" }

--- A proposal's field as the library's: an identifier's type goes to
-- identifiers.
function M.field(f)
  return M.library_field[f] or "identifiers"
end

local function now(book, field)
  local b = lulibre.book(book)
  if not b then return "" end
  if field == "authors" then return (b.author == "Unknown" or b.author == "()") and "" or b.author or "" end
  if field == "tags" then return table.concat(b.tags or {}, ", ") end
  if field == "identifiers" then
    local out = {}
    for k, v in pairs(b.idents or {}) do out[#out + 1] = k .. ":" .. v end
    return table.concat(out, ", ")
  end
  return b[field] or ""
end

local function score(field, proposed, current, near, same)
  if current == "" then return 0 end
  if field == "identifiers" then
    for item in current:gmatch("[^,]+") do
      if similar.score("ident", proposed, (item:gsub("^%s+", ""))) == 1 then return 1 end
    end
    return 0
  end
  local _, ab, ba = similar.compare(kinds[field] or "text", proposed, current, near, same)
  return (ab + ba) / 2
end

--- Every parse's record per field, from the journal as it stands: a table
-- keyed by parse and library field (`records[parse][field]`), empty while
-- the journal holds fewer than `after` decisions. Taken once by the code
-- that proposes, and passed down.
-- @tparam integer after
-- @tparam number near
-- @tparam number same
function M.records(after, near, same)
  local rows = lulibre.sql("SELECT book, field, proposed, source FROM history.journal"
                           .. " WHERE proposal IS NOT NULL AND source IS NOT NULL AND state IN (2, 4)")
  local out = {}
  if #rows < after then return out end
  local sums = {}
  for _, r in ipairs(rows) do
    local key = r.source .. "\0" .. r.field
    local s = sums[key] or { parse = r.source, field = r.field, sum = 0, n = 0 }
    sums[key] = s
    s.sum = s.sum + score(r.field, r.proposed or "", now(r.book, r.field), near, same)
    s.n = s.n + 1
  end
  for _, s in pairs(sums) do
    out[s.parse] = out[s.parse] or {}
    out[s.parse][s.field] = (M.prior * M.prior_weight + s.sum) / (M.prior_weight + s.n)
  end
  return out
end

--- Returns the record of a grammar or service for a proposal's field.
-- @tparam table records `records()`'s
-- @tparam string parse
-- @tparam string field a proposal's field
-- @treturn number 0 to 1
function M.record(records, parse, field)
  local r = records[parse]
  return r and r[M.field(field)] or M.prior
end

return M
