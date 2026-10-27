--- Proposals: one per book and field, from one parse or collective, with
-- its alternatives (design 16, 18, 19).
--
-- A collective proposal takes no span of text for two fields: a field's
-- first value comes from the best-ranked parse whose span for it no other
-- field's first value already took. Every other parse's value for the
-- field follows as an alternative, so where parses claim the same span for
-- different fields, the alternatives show the conflict. A field whose
-- first value equals the record's is not proposed.
--
-- @library lulibre.proposals
local reading = require "lulibre.reading"
local grammar = require "lulibre.grammar"
local sources = require "lulibre.sources"
local rank = require "lulibre.rank"
local similar = require "lulibre.similar"

local M = {}

--- The settings proposing reads, taken once by the command that proposes
-- (design 3) and passed down.
function M.settings()
  local coverage <const>, agreement <const>, track <const>, after <const>, near <const>, same <const> =
    setman.get("rank_coverage", "rank_agreement", "rank_track", "track_after", "similar_near", "similar_same")
  return { coverage = coverage, agreement = agreement, track = track, track_after = after, near = near, same = same }
end

--- A value as the field holds it: authors as calibre writes them, "A & B".
function M.normalize(field, value)
  if field ~= "authors" then return value end
  local names = {}
  for name in (value:gsub("%s+and%s+", "&"):gsub("[,;]", "&") .. "&"):gmatch("%s*(.-)%s*&") do
    if name ~= "" then names[#names + 1] = name end
  end
  return table.concat(names, " & ")
end

local function overlaps(a, b)
  return a.start <= b.stop and b.start <= a.stop
end

--- The rows: per field, its values in order, the first-ranked first.
-- @treturn table `{ [field] = { {value=, parse=, score=, agree=, disagree=, start=, stop=}, ... } }`
function M.rows(ranked, srcs, w)
  local rows, taken = {}, {}
  for _, p in ipairs(ranked) do
    for field, f in pairs(p.fields) do
      local value = M.normalize(field, f.value)
      local alt = { value = value, parse = p.grammar, score = p.score, start = f.start, stop = f.stop,
                    agree = (p.agree or {})[field], disagree = (p.disagree or {})[field] }
      local list = rows[field]
      local free = true
      for _, t in ipairs(taken) do
        if t.field ~= field and overlaps(t, f) then free = false end
      end
      if not list then
        if free then
          rows[field] = { alt }
          taken[#taken + 1] = { field = field, start = f.start, stop = f.stop }
        end
      else
        local same = false
        for _, a in ipairs(list) do
          same = same or similar.compare(rank.kind(field), a.value, value, w.near, w.same) == "equal"
        end
        if not same then list[#list + 1] = alt end
      end
    end
  end
  -- a value from a parse that only conflicted still shows as an alternative
  for _, p in ipairs(ranked) do
    for field, f in pairs(p.fields) do
      if not rows[field] then
        rows[field] = { { value = M.normalize(field, f.value), parse = p.grammar, score = p.score,
                          start = f.start, stop = f.stop } }
      end
    end
  end
  local record = srcs[1] and srcs[1].kind == "record" and srcs[1].fields or {}
  for field, list in pairs(rows) do
    local now = record[field]
    if now and similar.compare(rank.kind(field), list[1].value, now, w.near, w.same) == "equal" then rows[field] = nil end
  end
  return rows
end

--- Reads, parses, ranks and stores a book's proposals; returns how many
-- fields have one, or nil and the reason.
-- @tparam integer book
-- @tparam table w M.settings()
function M.propose(book, w)
  local r <close>, err = reading.of(book)
  if not r then return nil, err end
  local srcs = sources.of(book, r)
  local ranked = rank.order(grammar.parse(r), srcs, w)
  local rows = M.rows(ranked, srcs, w)
  lulibre.store("DELETE FROM proposals WHERE book = ?", book)
  local n = 0
  for field, list in pairs(rows) do
    n = n + 1
    for i, a in ipairs(list) do
      lulibre.store("INSERT INTO proposals(book, field, value, parse, alt, score, agree, disagree, file,"
                    .. " span_start, span_end, ts) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, strftime('%s', 'now'))",
                    book, field, a.value, a.parse, i, a.score,
                    a.agree and table.concat(a.agree, ",") or nil,
                    a.disagree and table.concat(a.disagree, ",") or nil,
                    r.file, a.start, a.stop)
    end
  end
  return n
end

--- Returns a book's proposals for review: per field, the first-ranked and
-- its alternatives.
-- @tparam integer book
-- @treturn {table,...} `{ {field=, alts = { {id=, value=, parse=, score=, agree=, disagree=}, ... } }, ... }`
function M.of(book)
  local out, by = {}, {}
  for _, row in ipairs(lulibre.sql("SELECT id, field, value, parse, score, agree, disagree FROM proposals"
                                   .. " WHERE book = ? ORDER BY field, alt", book)) do
    local f = by[row.field]
    if not f then
      f = { field = row.field, alts = {} }
      by[row.field] = f
      out[#out + 1] = f
    end
    table.insert(f.alts, row)
  end
  return out
end

--- Accepts a proposal, as proposed or edited, as an operation of the
-- library, with its provenance (design 27).
-- @tparam integer id the proposal
-- @tparam[opt] string value the edited value
function M.accept(id, value)
  error("not written yet", 2)
end

--- Rejects a proposal.
-- @tparam integer id
function M.reject(id)
  error("not written yet", 2)
end

return M
