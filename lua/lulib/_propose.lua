--- What :propose does, in steps, each keeping what it worked out: what the
-- grammars find in a file, the file's identifiers (lulib._ids) and how much
-- of a value is on its pages (lulib._check) are kept per file (lulib._kept).
-- Then the parses and the online records are ranked, and per field the values
-- kept as wits, the first-ranked first, the others its alternatives (design
-- 16, 18, 19). Ranking reads nothing again: a new online answer, or a changed
-- setting, only ranks anew.
--
-- A record is only taken for the book if the book's pages bear it out
-- (lulib._check). When the book has a record so borne out, by an identifier
-- that is the file's own, and all such records agree, its values score by
-- how much of them is on the pages (score_identified up to 1), and for the
-- fields it fills the other parses' values are kept but not shown. Any other
-- value scores by lulib._rank, on its own: nothing about one field's value
-- lends anything to another's.
--
-- A collective proposal takes no span of text for two fields: a field's
-- first value comes from the best-ranked parse whose span for it no other
-- field's first value already took. Every other parse's value for the
-- field follows as an alternative, so where parses claim the same span for
-- different fields, the alternatives show the conflict. A field whose
-- first value equals the record's is not proposed.
--
-- All of it is kept; a review shows less (a deep review all of it): no more
-- than propose_values values per field, none under propose_min or, where the
-- field has a value, under propose_over; no record the pages do not bear out.
--
-- @library lulib._propose
local check = require "lulib._check"
local exprman = require "exprman"
local ids = require "lulib._ids"
local junk = require "lulib._junk"
local kept = require "lulib._kept"
local mesr = require "mesr"
local rank = require "lulib._rank"
local sources = require "lulib._sources"
local trust = require "trust"
local wit = require "wit"

local M = {}
local own, get = require "lulib._expose" (M) -- internal functions (expose_modules)

--- What proposing goes by, taken once by the command that proposes
-- (design 3) and passed down: the settings, and the parses' track records
-- as the journal has them.
function M.settings()
  local coverage <const>, agreement <const>, weight <const>, after <const>, near <const>, same <const> =
    setman.get("rank_coverage", "rank_agreement", "rank_track", "track_after", "similar_near", "similar_same")
  local identified <const>, own_id <const>, other_id <const>, group <const> =
    setman.get("score_identified", "score_own_id", "score_other_id", "rank_group")
  local min <const>, over <const>, values <const>, top <const> =
    setman.get("propose_min", "propose_over", "propose_values", "id_top")
  return { coverage = coverage, agreement = agreement, track = weight, near = near, same = same,
           records = trust.records(after, near, same), decided = trust.decided(), check = check.settings(),
           identified = identified, own_id = own_id, other_id = other_id, group = group,
           min = min, over = over, values = values, top = top }
end

--- A value as the field holds it: authors as calibre writes them, "A & B";
-- an identifier (identifier:TYPE) in its canonical form, when it has one.
function M.normalize(field, value)
  local kind = field:match("^identifier:(.+)")
  if kind then return mesr.canonical(kind, value) or value end
  if field ~= "authors" then return value end
  local names = {}
  for name in (value:gsub("%s+and%s+", "&"):gsub("[,;]", "&") .. "&"):gmatch("%s*(.-)%s*&") do
    if name ~= "" then names[#names + 1] = name end
  end
  return table.concat(names, " & ")
end

-- a title the record has that is no title, a file's name say, is no value to
-- keep: a proposal fills it, it does not replace it
function own.holds(field, value)
  if value == nil or value == "" then return false end
  return not (field == "title" and (junk.title(value) or junk.unlikely_title(value)))
end

-- an online record's fields have no span: they take none
function own.overlaps(a, b)
  return a.start ~= nil and b.start ~= nil and a.start <= b.stop and b.start <= a.stop
end

-- how sure a value's reading is: as its grammar says; for an online record, how
-- much of it is on the pages
function own.sure(p, f, w)
  local sure = f.sure or rank.grammar_sure
  if p.online then sure = 0.5 + 0.5 * (f.share or 0) end
  if p.group_hit then sure = sure + w.group end
  return math.min(1, sure)
end

-- what a value scores, and who agrees: fixed for an identifier; for a strong record's,
-- by how much of it is on the pages; else by lulib._rank
function own.value_score(p, field, f, value, srcs, w)
  local name = f.how or p.grammar
  if f.fixed then return f.fixed, nil, nil, name end
  if p.strong then
    local agree, disagree = select(2, rank.agreement(name, field, value, srcs, w))
    return w.identified + (1 - w.identified) * (f.share or 0), agree, disagree, name
  end
  local score, agree, disagree = rank.value(name, field, value, get("sure")(p, f, w), srcs, w)
  return score, agree, disagree, name
end

-- the values to rank: every value of each parse, the best first, those of a record
-- the pages do not bear out last, those a strong record outranks before them
function own.candidates(ranked, srcs, w, decided)
  local filled = {}
  for _, p in ipairs(ranked) do
    if p.strong then
      for field in pairs(p.fields) do filled[field] = true end
    end
  end
  local out = {}
  local function add(p, field, f)
    local value = M.normalize(field, f.value)
    local wanted = not w.only or w.only[field] or (w.only.identifiers and field:find("^identifier:"))
    if wanted and value ~= "" and not (decided[field] and decided[field][value]) then
      local score, agree, disagree, name = get("value_score")(p, field, f, value, srcs, w)
      out[#out + 1] = { parse = p, field = field, f = f, value = value, score = score, agree = agree, disagree = disagree,
                        name = name, failed = p.failed, weak = filled[field] and not p.strong and not f.fixed }
    end
  end
  for _, p in ipairs(ranked) do
    for field, f in pairs(p.fields) do
      add(p, field, f)
      for _, other in ipairs(f.also or {}) do add(p, field, other) end
    end
  end
  local function level(c) return c.failed and 2 or c.weak and 1 or 0 end
  table.sort(out, function(a, b)
    if level(a) ~= level(b) then return level(a) < level(b) end
    if a.score ~= b.score then return a.score > b.score end
    if a.name ~= b.name then return a.name < b.name end
    if a.field ~= b.field then return a.field < b.field end
    return a.value < b.value
  end)
  return out
end

--- The rows: per field, its values in order, the first-ranked first.
-- @treturn table `{ [field] = { {value=, source=, score=, agree=, disagree=,
-- start=, stop=, hidden=}, ... } }`
function M.rows(ranked, srcs, w, decided)
  local rows, taken = {}, {}
  local function alt_of(c)
    local f = c.f
    return { value = c.value, source = c.name, score = c.score, start = f.start, stop = f.stop,
             agree = c.agree, disagree = c.disagree, hide = c.failed or c.weak }
  end
  local cands = get("candidates")(ranked, srcs, w, decided or {})
  for _, c in ipairs(cands) do
    local field, f = c.field, c.f
    local list = rows[field]
    local free = true
    for _, t in ipairs(taken) do
      if t.field ~= field and get("overlaps")(t, f) then free = false end
    end
    if not list then
      if free then
        rows[field] = { alt_of(c) }
        taken[#taken + 1] = { field = field, start = f.start, stop = f.stop }
      end
    else
      local same = false
      for _, a in ipairs(list) do
        same = same or mesr.cmp(field, a.value, c.value, w.near, w.same) == "equal"
      end
      if not same then list[#list + 1] = alt_of(c) end
    end
  end
  -- a value from a parse that only conflicted still shows as an alternative
  for _, c in ipairs(cands) do
    if not rows[c.field] then rows[c.field] = { alt_of(c) } end
  end
  local record = srcs[1] and srcs[1].kind == "record" and srcs[1].fields or {}
  for field, list in pairs(rows) do
    local now = record[field]
    if now and mesr.cmp(field, list[1].value, now, w.near, w.same) == "equal" then
      rows[field] = nil
    else
      local need = get("holds")(field, now) and w.over or w.min
      for i, a in ipairs(list) do
        a.hidden = a.hide or i > w.values or (a.score or 0) < need
      end
    end
  end
  return rows
end

-- what the grammars find in the book's file: each grammar's kept, per its
-- version; those not yet run on it are run now
function own.grammars(book, k, text)
  local parses, missing = {}, {}
  for _, name in ipairs(exprman.names()) do
    local key = name .. "\0" .. tostring(exprman.grammars[name].version or "")
    local p = k:get("parse", key)
    if p == nil then missing[#missing + 1] = { name = name, key = key }
    elseif p then parses[#parses + 1] = p end
  end
  local t = #missing > 0 and text.get()
  if t then
    local names = {}
    for i, m in ipairs(missing) do names[i] = m.name end
    local by = {}
    for _, p in ipairs(exprman.parse(t, book, names)) do by[p.grammar] = p end
    for _, m in ipairs(missing) do
      k:put("parse", m.key, by[m.name] or false)
      parses[#parses + 1] = by[m.name]
    end
  end
  return parses
end

-- whether a grammar's values gain for being of what it was written for: a
-- publisher or series the record has, or all found on the pages
function own.group_hit(p, book, k, text)
  local g = exprman.grammars[p.grammar]
  local group = g and g.group
  if not group then return false end
  for _, field in ipairs { "publisher", "series" } do
    local now = wit.now(book, field)
    if now and now ~= "" and mesr.cmp("publisher", group, now) ~= "differs" then return true end
  end
  local found, words = check.count("publisher", group, k, text)
  return found ~= nil and words > 0 and found == words
end

-- the records by an identifier the pages bear out, if they all agree: such
-- records make a book's match clear; several of the same work agree
function own.clear(records, w)
  local borne = {}
  for _, r in ipairs(records) do
    if r.check and r.check.same and r.ident ~= "title" then borne[#borne + 1] = r end
  end
  for i = 2, #borne do
    local a, b = borne[1].fields.title, borne[i].fields.title
    if a and b and mesr.cmp("title", a, b, w.near, w.same) == "differs" then return false end
  end
  return #borne > 0
end

-- the file's identifiers as parses, each one's score fixed: a borne-out
-- record's scores as the record does
function own.id_parses(found, records, w)
  local out = {}
  for _, id in ipairs(found) do
    local score = id.own and w.own_id or w.other_id
    for _, r in ipairs(records) do
      if r.ident == id.kind and r.key == mesr.canonical(id.kind, id.value) and r.check then
        score = r.check.same and w.identified + (1 - w.identified) * r.check.score or math.min(score, w.other_id)
      end
    end
    out[#out + 1] = { grammar = "lex", fields = { ["identifier:" .. id.kind] =
      { value = id.value, start = id.start, stop = id.stop, fixed = score } } }
  end
  return out
end

-- reads what was not kept, ranks the book's values, and keeps them as its
-- wits; how many fields have one shown
function own.once(book, w)
  local file = kept.file_of(book)
  local k <close> = kept.open(file and file.id, file and file.indexed)
  local text <close> = kept.reader(file)
  local parses = get("grammars")(book, k, text)
  for _, p in ipairs(parses) do p.group_hit = get("group_hit")(p, book, k, text) end
  local found = file and ids.of(file, k, text, w.top) or {}

  -- an online record is a parse too (design 39), ranked beside the
  -- grammars', once compared with the pages
  local srcs, records = {}, {}
  for _, s in ipairs(sources.of(book, file, found)) do
    if s.kind == "online" then
      if not s.identifies then s.check = check.record(s, file or {}, k, text, w.check) end
      -- one found by its title must be the same work, by title and authors too
      if s.ident == "title" and s.check then
        s.check.same = s.check.same and s.fields.title
          and check.title_match(wit.now(book, "title") or "", s.fields.title, wit.now(book, "authors"), s.fields.authors)
      end
      records[#records + 1] = s
    end
    if s.kind == "record" and s.fields.title and not get("holds")("title", s.fields.title) then s.fields.title = nil end
    if not (s.check and not s.check.same) then srcs[#srcs + 1] = s end
  end
  local clear = get("clear")(records, w)
  for _, s in ipairs(records) do
    local fields = {}
    for field, value in pairs(s.fields) do
      fields[field] = { value = value, share = check.share(field, value, k, text), fixed = s.identifies and w.own_id or nil }
    end
    local same = s.check and s.check.same
    parses[#parses + 1] = { grammar = s.name, fields = fields, online = true, failed = s.check and not same,
                            strong = clear and same and s.ident ~= "title" }
  end
  for _, p in ipairs(get("id_parses")(found, records, w)) do parses[#parses + 1] = p end

  local rows = M.rows(parses, srcs, w, w.decided and w.decided[book])
  local wits, n = {}, 0
  for field, list in pairs(rows) do
    local shown = false
    for _, a in ipairs(list) do
      a.field, a.file = field, file and file.id
      shown = shown or not a.hidden
      wits[#wits + 1] = a
    end
    if shown then n = n + 1 end
  end
  wit.set(book, wits)
  return n
end

-- per book, the propose running for it: true, or "again" when it was asked
-- for while it ran
local running = {}

--- Ranks a book's values, reading only what was not kept, and keeps them as
-- its wits in the current review; returns how many fields have one shown. A
-- book with no text is proposed for from its online records alone. Asked for
-- while one runs for the book, it returns at once, and the one running goes
-- again as it ends, with the sources as they then are.
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
    n = get("once")(book, w)
  until running[book] ~= "again"
  evman.post("proposed", { book = book })
  taskman.yield() -- what was kept takes no waiting: the other tasks get a turn
  return n
end

-- an answer arriving re-ranks the book (design 42)
local arrived, arrived_at
evman.add("source_arrived", function(ev)
  -- (many answers come in a run; what proposing goes by is taken every few seconds)
  if not arrived or os.time() - arrived_at > 5 then arrived, arrived_at = M.settings(), os.time() end
  M.propose(ev.book, arrived)
end)

return M
