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
local txt = require "txt"
local grammar = require "lulibre.grammar"
local sources = require "lulibre.sources"
local rank = require "lulibre.rank"
local similar = require "lulibre.similar"
local track = require "lulibre.track"
local store = require "store"

local M = {}

--- What proposing goes by, taken once by the command that proposes
-- (design 3) and passed down: the settings, and the parses' track records
-- as the journal has them.
function M.settings()
  local coverage <const>, agreement <const>, weight <const>, after <const>, near <const>, same <const> =
    setman.get("rank_coverage", "rank_agreement", "rank_track", "track_after", "similar_near", "similar_same")
  return { coverage = coverage, agreement = agreement, track = weight, near = near, same = same,
           records = track.records(after, near, same) }
end

--- A value as the field holds it: authors as calibre writes them, "A & B";
-- an identifier as "type:value".
function M.normalize(field, value)
  if not track.library_field[field] and not value:find("^[%w_%-]+:") then return field .. ":" .. value end
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

-- the books a propose is running for
local proposing = {}

--- Reads, parses, ranks and stores a book's proposals; returns how many
-- fields have one. A book with no text is proposed for from its online
-- records alone.
-- @tparam integer book
-- @tparam table w M.settings()
function M.propose(book, w)
  -- one at a time per book: its rows are deleted and written again
  while proposing[book] do taskman.sleep(50) end
  proposing[book] = true
  local _ <close> = setmetatable({}, { __close = function() proposing[book] = nil end })
  local r <close> = txt.of(book)
  local srcs = sources.of(book, r)
  -- an online record is a parse too (design 39), ranked beside the grammars'
  local parses = r and grammar.parse(r) or {}
  for _, s in ipairs(srcs) do
    if s.kind == "online" then
      local fields = {}
      for field, value in pairs(s.fields) do fields[field] = { value = value } end
      parses[#parses + 1] = { grammar = s.name, fields = fields }
    end
  end
  local ranked = rank.order(parses, srcs, w)
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
                    r and r.file, a.start, a.stop)
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

--- The change a decision on a proposal makes: the library's field, with
-- the proposal's provenance (design 27). An identifier is added to the
-- book's; tags are added to its own.
local function change(p, value)
  local field = track.field(p.field)
  return { book = p.book, field = field, value = value, proposal = p.id, proposed = p.value, source = p.parse,
           op = (field == "identifiers" or field == "tags") and value and "add" or "set" }
end

local function row(id)
  return lulibre.sql("SELECT id, book, field, value, parse FROM proposals WHERE id = ?", id)[1]
end

local function decided(p)
  lulibre.store("DELETE FROM proposals WHERE book = ? AND field = ?", p.book, p.field)
end

--- Accepts a proposal, as proposed or edited, as an operation of the
-- library; waits for it. Returns the batch, or nil and why.
-- @tparam integer id the proposal
-- @tparam[opt] string value the edited value
function M.accept(id, value)
  local p = row(id)
  if not p then return nil, "no proposal " .. id end
  local batch, err = store.apply({ change(p, value or p.value) }, "review: " .. p.field)
  if err then return nil, err end
  decided(p)
  return batch
end

--- Rejects a proposal: the field keeps its value, and the journal keeps
-- the decision, for the parse's track record.
-- @tparam integer id
function M.reject(id)
  local p = row(id)
  if not p then return nil, "no proposal " .. id end
  local batch, err = store.apply({ change(p, nil) }, "review: " .. p.field .. " rejected")
  if err then return nil, err end
  decided(p)
  return batch
end

return M
