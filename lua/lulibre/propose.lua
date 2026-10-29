--- What :propose does: a book's text parsed by the grammars, the parses
-- and the online records ranked, and per field the values kept as wits,
-- the first-ranked first, the others its alternatives (design 16, 18, 19).
--
-- A collective proposal takes no span of text for two fields: a field's
-- first value comes from the best-ranked parse whose span for it no other
-- field's first value already took. Every other parse's value for the
-- field follows as an alternative, so where parses claim the same span for
-- different fields, the alternatives show the conflict. A field whose
-- first value equals the record's is not proposed.
--
-- @library lulibre.propose
local txt = require "txt"
local expr = require "expr"
local lex = require "lex"
local grammar = require "lulibre.grammar"
local sources = require "lulibre.sources"
local rank = require "lulibre.rank"
local mesr = require "mesr"
local trust = require "trust"
local wit = require "wit"

local M = {}

--- What proposing goes by, taken once by the command that proposes
-- (design 3) and passed down: the settings, and the parses' track records
-- as the journal has them.
function M.settings()
  local coverage <const>, agreement <const>, weight <const>, after <const>, near <const>, same <const> =
    setman.get("rank_coverage", "rank_agreement", "rank_track", "track_after", "similar_near", "similar_same")
  return { coverage = coverage, agreement = agreement, track = weight, near = near, same = same,
           records = trust.records(after, near, same) }
end

--- A value as the field holds it: authors as calibre writes them, "A & B";
-- an identifier as "type:value".
function M.normalize(field, value)
  if not trust.library_field[field] and not value:find("^[%w_%-]+:") then return field .. ":" .. value end
  if field ~= "authors" then return value end
  local names = {}
  for name in (value:gsub("%s+and%s+", "&"):gsub("[,;]", "&") .. "&"):gmatch("%s*(.-)%s*&") do
    if name ~= "" then names[#names + 1] = name end
  end
  return table.concat(names, " & ")
end

-- an online record's fields have no span: they take none
local function overlaps(a, b)
  return a.start ~= nil and b.start ~= nil and a.start <= b.stop and b.start <= a.stop
end

--- The rows: per field, its values in order, the first-ranked first.
-- @treturn table `{ [field] = { {value=, source=, score=, agree=, disagree=, start=, stop=}, ... } }`
function M.rows(ranked, srcs, w)
  local rows, taken = {}, {}
  for _, p in ipairs(ranked) do
    for field, f in pairs(p.fields) do
      local value = M.normalize(field, f.value)
      local alt = { value = value, source = p.grammar, score = p.score, start = f.start, stop = f.stop,
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
          same = same or mesr.compare(rank.kind(field), a.value, value, w.near, w.same) == "equal"
        end
        if not same then list[#list + 1] = alt end
      end
    end
  end
  -- a value from a parse that only conflicted still shows as an alternative
  for _, p in ipairs(ranked) do
    for field, f in pairs(p.fields) do
      if not rows[field] then
        rows[field] = { { value = M.normalize(field, f.value), source = p.grammar, score = p.score,
                          start = f.start, stop = f.stop } }
      end
    end
  end
  local record = srcs[1] and srcs[1].kind == "record" and srcs[1].fields or {}
  for field, list in pairs(rows) do
    local now = record[field]
    if now and mesr.compare(rank.kind(field), list[1].value, now, w.near, w.same) == "equal" then rows[field] = nil end
  end
  return rows
end

-- the identifiers in a text, as a parse named "lex": per type, the first
-- found
local function found(t)
  local fields = {}
  for _, kind in ipairs { "isbn", "doi", "arxiv", "issn" } do
    local start, stop, id = expr.find(t, lex[kind])
    if start then fields[kind] = { value = kind .. ":" .. id, start = start, stop = stop } end
  end
  if next(fields) then return { grammar = "lex", fields = fields } end
end

-- reads, parses and ranks the book's values once, and keeps them as its
-- wits
local function once(book, w)
  local t <close> = txt.of(book)
  local srcs = sources.of(book, t)
  -- an online record is a parse too (design 39), ranked beside the grammars'
  local parses = t and grammar.parse(t) or {}
  parses[#parses + 1] = t and found(t) or nil
  for _, s in ipairs(srcs) do
    if s.kind == "online" then
      local fields = {}
      for field, value in pairs(s.fields) do fields[field] = { value = value } end
      parses[#parses + 1] = { grammar = s.name, fields = fields }
    end
  end
  local rows = M.rows(rank.order(parses, srcs, w), srcs, w)
  local wits, n = {}, 0
  for field, list in pairs(rows) do
    n = n + 1
    for _, a in ipairs(list) do
      a.field, a.file = field, t and t.file
      wits[#wits + 1] = a
    end
  end
  wit.set(book, wits)
  return n
end

-- per book, the propose running for it: true, or "again" when it was asked
-- for while it ran
local running = {}

--- Reads, parses and ranks a book's values, and keeps them as its wits;
-- returns how many fields have one. A book with no text is proposed for
-- from its online records alone. Asked for while one runs for the book,
-- it returns at once, and the one running goes again as it ends, with the
-- sources as they then are.
-- @tparam integer book
-- @tparam table w M.settings()
function M.propose(book, w)
  if running[book] then
    running[book] = "again"
    return
  end
  local _ <close> = setmetatable({}, { __close = function() running[book] = nil end })
  local n
  repeat
    running[book] = true
    n = once(book, w)
  until running[book] ~= "again"
  return n
end

-- an answer arriving re-ranks the book (design 42)
evman.add("source_arrived", function(ev)
  M.propose(ev.book, M.settings())
end)

return M
