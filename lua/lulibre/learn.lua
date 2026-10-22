--- Learns which phrases mark a subject, from the records you confirmed.
--
-- learn cuts every book's indexed pages into phrases of two and three words
-- (lulibre.phrases). A phrase marks a subject if books of that subject use
-- the phrase far more than books of other subjects, and if the phrase is
-- not one author's habit: it must appear in several of the subject's books,
-- by more than one author. For each subject, the strongest few phrases are
-- kept in the table `terms` (the option subject_terms sets how many). :terms
-- shows them for review, where you can drop a phrase for good or add one
-- by hand.
--
-- lulibre then suggests a subject for a book from the marking phrases on
-- the book's pages. The suggestion names those phrases, so you can judge it.
--
-- Only confirmed records teach (quality.lua, :good). Otherwise a wrong
-- subject on an unchecked record would be taught back to the rest. A book
-- teaches its subject and every subject above it: "math/number-theory/
-- algebraic" also teaches "math/number-theory" and "math". A catch-all
-- subject ("math/general") teaches only the subjects above it, since a
-- catch-all says where a book was filed, not what it is about.
--
-- @judging lulibre.learn
-- @usage
-- local learn = require "lulibre.learn"
-- learn.run()                        --> { books=, subjects=, terms=, phrases=, seconds= }
-- learn.terms("math/number-theory")  --> { {term=, score=, books=, state=}, ... }
-- learn.classify(text)               --> { {subject=, score=, matched={...}}, ... } best first
-- learn.suggest(text)                --> subject, confidence, { phrases } or nil
local quality = require "lulibre.quality"

local M = {}

--- How many confirmed books a subject needs before learn learns phrases for it.
M.MIN_BOOKS = 6
--- The share of a subject's books a marking phrase must appear in, at least.
M.MIN_SHARE = 0.08
--- How many of a subject's books a marking phrase must appear in, at least.
M.MIN_IN = 3
--- How many times more often a marking phrase must appear in the subject's
-- books than in books of other subjects.
M.MIN_LIFT = 2.5
--- How many different authors must use a marking phrase, at least. A
-- subject with few books needs fewer.
M.MIN_AUTHORS = 3

--- Phrases that say how a book was published, not what it is about. These
-- phrases appear in the front matter of one publisher's series, so the
-- subjects that series covers use them far more than other subjects do.
-- Some titles in the library are such headings ("Handbook of Algebra:
-- Editorial Board"), so the phrases also pass for title words. Add your own:
--
--    require("lulibre.learn").FURNITURE["lecture notes"] = true
--
M.FURNITURE = {}
for _, g in ipairs { "editorial board", "series editors", "series editor", "managing editor", "advisory board",
  "graduate texts", "texts in mathematics", "graduate texts in", "undergraduate texts", "undergraduate texts in",
  "lecture notes", "lecture notes in", "notes in mathematics", "subject classification", "mathematics subject",
  "mathematics subject classification", "second edition", "third edition", "revised edition", "university press" } do
  M.FURNITURE[g] = true
end

--- How many different books a line must appear in to count as shared.
-- Text that many books share word for word, such as a publisher's imprint,
-- a series list or a journal's notice to readers, says nothing about any
-- one book. learn finds shared lines by counting whole lines across the
-- library (copies of one book count once, by title), and leaves them out
-- wherever phrases are read.
M.SHARED = 3 -- a line in this many different books is not any book's own

local shared -- the counter of lines, built when first needed and after the library changes

local function shared_lines()
  if shared then return shared end
  local c = lulibre.counter()
  local books = lulibre.sql("SELECT id, title FROM books WHERE id > 0 ORDER BY lower(title), id")
  local last
  for n, b in ipairs(books) do
    local text = lulibre.text(b.id)
    local title = lulibre.fold(b.title or "")
    if text then
      c:add_lines(text, title ~= "" and title == last)
      last = title
    end
    if n % 200 == 0 and lulibre.task_id() then lulibre.yield() end
  end
  c:prune(M.SHARED)
  shared = c
  return c
end

--- Clears the shared lines worked out so far. Call it after the library has changed.
function M.forget()
  shared = nil
end

-- what marks a page as imprint: a copyright page, a publisher's notice, an
-- archive's cover sheet. Three of these on a page and its words are the
-- publisher's, not the book's.
local IMPRINT = { "isbn", "rights reserved", "rights are reserved", "copyright", "©", "library of congress",
  "printed in ", "cataloging", "catalogue record", "trademark", "permission", "publisher", "distributed",
  "terms and conditions", "typeset" }

--- Returns the text that is the book's own: its indexed pages, without the
-- imprint pages and without the lines it shares with other books.
-- @tparam integer id
-- @tparam[opt] boolean quick keep the shared lines, since finding them needs the whole
-- library read once
-- @treturn string
function M.text(id, quick)
  local text = lulibre.text(id)
  if not text then return nil end
  local keep = {}
  for page in (text .. "\f"):gmatch("(.-)\f") do
    local low, marks = page:lower(), 0
    for _, m in ipairs(IMPRINT) do
      if low:find(m, 1, true) then marks = marks + 1 end
    end
    if marks < 3 then keep[#keep + 1] = page end
  end
  if quick then return table.concat(keep, "\n") end
  return shared_lines():strip(table.concat(keep, "\n"), M.SHARED)
end

--- Returns the learned subject for a book in the library as a candidate,
-- or nil. A learned subject is a judgement from a handful of phrases, and
-- such judgements have proved poor. So the confidence is half of what the
-- phrases give, and never more than 0.3.
-- @tparam integer id
-- @treturn table|nil `{ field = "tags", value =, source = "learned: phrase, phrase", confidence = }`
function M.candidate(id)
  if lulibre.o.learned_tags == "off" or not M.ready() then return nil end
  local text = M.text(id, true)
  local subject, confidence, why = M.suggest(text or "")
  if not subject then return nil end
  return { field = "tags", value = subject, confidence = math.min(0.3, confidence / 2),
    source = "learned: " .. table.concat(why, ", ", 1, math.min(3, #why)) }
end

-- The phrases that book titles are made of. A title is the one place where
-- a book says what it is about and nothing else, so a phrase that never
-- stands in any title of the library (a city, a company, a turn of speech) is
-- not taken to mark a subject, however unevenly the subjects use it.
local function title_phrases()
  local set = {}
  for _, b in ipairs(lulibre.sql("SELECT title FROM books WHERE id > 0")) do
    for _, g in ipairs(lulibre.phrases(b.title or "")) do set[g] = true end
  end
  return set
end

--- Returns a subject and the subjects above it: "a/b/c" gives { "a/b/c", "a/b", "a" }.
-- @tparam string subject
-- @treturn {string,...}
function M.lineage(subject)
  local out = { subject }
  local up = subject
  while true do
    up = up:match("^(.*)/[^/]+$")
    if not up then break end
    out[#out + 1] = up
  end
  return out
end

-- the subjects a book teaches: its own and those above, less the catch-alls
local function taught(book)
  local set, out = {}, {}
  for _, tag in ipairs(book.tags or {}) do
    for _, s in ipairs(M.lineage(tag)) do
      if not quality.catchall(s) and not set[s] then
        set[s] = true
        out[#out + 1] = s
      end
    end
  end
  return out
end

--- Reads the whole library once and counts how many books use each phrase,
-- and waits. A phrase common to the whole library marks nothing, whatever
-- the confirmed books do with it.
-- @treturn table the census, which `work` takes as `opts.census`
function M.census()
  M.forget()
  local counter, ids = lulibre.counter(), lulibre.ids("in:library")
  for n, id in ipairs(ids) do
    local text = M.text(id)
    if text then counter:add(text) end
    if n % 100 == 0 then
      lulibre.progress(("reading %d/%d"):format(n, #ids))
      if lulibre.task_id() then lulibre.yield() end
    end
  end
  local total = counter:texts()
  counter:prune(M.MIN_IN, math.max(M.MIN_IN, math.floor(total * 0.4)))
  lulibre.progress(nil)
  return { counter = counter, total = total }
end

--- Works out the marking phrases without storing them. Phrases dropped in
-- :terms are left out, as `run` leaves them out.
-- @tparam[opt] table opts `from` is the ids to learn from (the confirmed records by
-- default); `census` is a census from `census`, to reuse it across several calls
-- @treturn[1] table `{ terms = { [subject] = { {term=, score=, books=}, ... strongest first },
-- books=, read=, subjects=, nterms=, phrases= }`
-- @treturn[2] nil
-- @treturn[2] string why nothing could be learned
function M.work(opts)
  opts = opts or {}
  local from = opts.from or quality.good_ids()
  if #from == 0 then
    return nil, ("no records are confirmed as good yet: %s lists them by how complete they look"):format(lulibre.hint("good"))
  end
  local census = opts.census or M.census()
  local _ <close> = not opts.census and census.counter or nil -- ours: freed when this returns
  local counter, total = census.counter, census.total
  -- how the confirmed books of each subject use what is left
  local books, in_s, by, all_in, taught_n = {}, {}, {}, {}, 0
  for n, id in ipairs(from) do
    local book = lulibre.book(id)
    local text = book and M.text(id)
    local subjects = book and taught(book) or {}
    if text and #subjects > 0 then
      -- a fuller record teaches more: one with nothing wrong counts once,
      -- one that scores 0.6 a little over half
      local w = math.max(0.5, (quality.score(book)))
      taught_n = taught_n + w
      local who = lulibre.fold(book.author or "")
      local phrases = counter:of(text)
      for _, g in ipairs(phrases) do all_in[g] = (all_in[g] or 0) + w end
      for _, s in ipairs(subjects) do
        books[s] = (books[s] or 0) + w
        local count, authors = in_s[s], by[s]
        if not count then
          count, authors = {}, {}
          in_s[s], by[s] = count, authors
        end
        for _, g in ipairs(phrases) do
          count[g] = (count[g] or 0) + w
          -- how many different authors use it, counted as far as it matters
          local seen = authors[g]
          if not seen then
            authors[g] = { [who] = true, n = 1 }
          elseif not seen[who] and seen.n < M.MIN_AUTHORS then
            seen[who], seen.n = true, seen.n + 1
          end
        end
      end
    end
    if n % 100 == 0 then
      lulibre.progress(("learning %d/%d"):format(n, #from))
      if lulibre.task_id() then lulibre.yield() end
    end
  end
  lulibre.progress(nil)

  local in_titles = title_phrases()
  local keep = tonumber(lulibre.o.subject_terms) or 20
  local dropped = {}
  for _, r in ipairs(lulibre.sql("SELECT subject, term FROM terms WHERE state = 'dropped'")) do
    dropped[r.subject .. "\0" .. r.term] = true
  end
  -- score every subject's phrases
  local scored_by = {}
  for s, n_s in pairs(books) do
    if n_s >= M.MIN_BOOKS then
      local scored = {}
      for g, k in pairs(in_s[s]) do
        if k >= M.MIN_IN and in_titles[g] and not M.FURNITURE[g] and by[s][g].n >= math.min(M.MIN_AUTHORS, n_s // 4 + 1)
          and not dropped[s .. "\0" .. g] then
          -- the share of the subject's books that use it, held back for a
          -- subject of few books: three books out of five are not sixty in a hundred
          local share = (k + 0.5) / (n_s + 5)
          -- how often books of other subjects use it; the halves keep a phrase
          -- no other book uses from scoring as infinitely telling
          local elsewhere = (all_in[g] - k + 0.5) / (taught_n - n_s + 1)
          local lift = share / elsewhere
          if k / n_s >= M.MIN_SHARE and lift >= M.MIN_LIFT then
            scored[#scored + 1] = { term = g, score = share * math.log(lift), books = math.floor(k + 0.5), raw = k / n_s }
          end
        end
      end
      scored_by[s] = scored
    end
  end
  -- A phrase marks one branch of the subjects, the one it marks best: "zeta
  -- function" may tell number theory from the rest, or physics, not both.
  -- (A subject and those above and below it are one branch.)
  local best = {} -- phrase -> { subject, score } of its strongest claim
  for s, scored in pairs(scored_by) do
    for _, t in ipairs(scored) do
      local b = best[t.term]
      if not b or t.score > b.score then best[t.term] = { subject = s, score = t.score } end
    end
  end
  local function same_branch(a, b)
    return a == b or a:sub(1, #b + 1) == b .. "/" or b:sub(1, #a + 1) == a .. "/"
  end
  local terms, nsubjects, nterms = {}, 0, 0
  -- how much of each subject's books use each of its phrases
  local raw = {}
  for s, scored in pairs(scored_by) do
    raw[s] = {}
    for _, t in ipairs(scored) do raw[s][t.term] = t.raw end
  end
  for s, scored in pairs(scored_by) do
    local above = M.lineage(s)
    local mine = {}
    for _, t in ipairs(scored) do
      local ok = same_branch(best[t.term].subject, s)
      -- Within a branch a phrase belongs to the widest subject it marks:
      -- "linear algebra" marks mathematics, and so says nothing more for
      -- field theory unless field theory's books use it far more than
      -- mathematics books at large do.
      for i = 2, #above do
        local wider = raw[above[i]] and raw[above[i]][t.term]
        if wider and wider >= 0.5 * t.raw then ok = false end
      end
      if ok then mine[#mine + 1] = t end
    end
    table.sort(mine, function(a, b)
      if a.score ~= b.score then return a.score > b.score end
      return a.term < b.term
    end)
    if #mine > 0 then
      nsubjects = nsubjects + 1
      terms[s] = {}
      for i = 1, math.min(keep, #mine) do
        terms[s][i] = { term = mine[i].term, score = mine[i].score, books = mine[i].books }
        nterms = nterms + 1
      end
    end
  end
  return { terms = terms, books = math.floor(taught_n + 0.5), read = total, subjects = nsubjects, nterms = nterms,
    phrases = counter:size() }
end

--- Learns the marking phrases and stores them. Waits: a few seconds for a
-- library of a couple of thousand books.
-- @tparam[opt] table opts `from` is the ids to learn from (the confirmed records by default)
-- @treturn[1] table `{ books=, read=, subjects=, terms=, phrases=, seconds= }`
-- @treturn[2] nil
-- @treturn[2] string why nothing could be learned
function M.run(opts)
  local t0 = os.time()
  local got, why = M.work(opts)
  if not got then return nil, why end
  lulibre.store("DELETE FROM terms WHERE state = 'learned'")
  for s, list in pairs(got.terms) do
    for _, t in ipairs(list) do
      lulibre.store("INSERT OR IGNORE INTO terms(subject, term, score, books, state) VALUES(?, ?, ?, ?, 'learned')",
        s, t.term, t.score, t.books)
    end
  end
  M.loaded = nil
  local out = { books = got.books, read = got.read, subjects = got.subjects, terms = got.nterms, phrases = got.phrases,
    seconds = os.time() - t0 }
  lulibre.store("INSERT OR REPLACE INTO kv(key, value) VALUES('learn:last', ?)",
    ("%d\t%d\t%d\t%d"):format(os.time(), out.books, out.subjects, out.terms))
  return out
end


--- Returns a subject's marking phrases, strongest first, with kept phrases
-- before learned ones. Without a subject, returns every subject's phrases.
-- @tparam[opt] string subject
-- @tparam[opt] boolean all also return the dropped phrases
-- @treturn {table,...} `{ term=, score=, books=, state= }`
function M.terms(subject, all)
  local where, args = {}, {}
  if subject then
    where[#where + 1] = "subject = ?"
    args[#args + 1] = subject
  end
  if not all then where[#where + 1] = "state <> 'dropped'" end
  return lulibre.sql("SELECT subject, term, score, books, state FROM terms" ..
    (#where > 0 and " WHERE " .. table.concat(where, " AND ") or "") ..
    " ORDER BY subject, state = 'dropped', state <> 'kept', score DESC, term", table.unpack(args))
end

--- Adds a phrase to a subject by hand, drops a phrase for good, or lets the
-- books decide again whether the phrase is learned.
-- @tparam string subject
-- @tparam string term
-- @tparam string|nil state "kept", "dropped", or nil to remove the decision
function M.set(subject, term, state)
  term = lulibre.fold(term):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "") -- as phrases are spelled
  if state then
    lulibre.store([[INSERT INTO terms(subject, term, score, books, state) VALUES(?, ?, 1, 0, ?)
      ON CONFLICT(subject, term) DO UPDATE SET state = excluded.state]], subject, term, state)
  else
    lulibre.store("DELETE FROM terms WHERE subject = ? AND term = ?", subject, term)
  end
  M.loaded = nil
end

local function load()
  if M.loaded then return M.loaded end
  local by = {}
  for _, r in ipairs(M.terms()) do
    by[r.subject] = by[r.subject] or {}
    by[r.subject][r.term] = r.score or 1
  end
  M.loaded = by
  return by
end

--- Returns the model `classify` and `suggest` use for a `work` result that
-- was not stored: the result's phrases, plus the phrases added by hand in
-- :terms.
-- @tparam table got `work`'s result
-- @treturn table
function M.model(got)
  local by = {}
  for _, r in ipairs(lulibre.sql("SELECT subject, term, score FROM terms WHERE state = 'kept'")) do
    by[r.subject] = by[r.subject] or {}
    by[r.subject][r.term] = r.score or 1
  end
  for s, list in pairs(got.terms) do
    by[s] = by[s] or {}
    for _, t in ipairs(list) do by[s][t.term] = by[s][t.term] or t.score end
  end
  return by
end

--- Returns true if any phrases have been learned.
-- @treturn boolean
function M.ready()
  return next(load()) ~= nil
end

--- Returns the subjects whose marking phrases a text holds, best first.
-- @tparam string text
-- @tparam[opt] table model a model from `model`, used instead of the stored phrases
-- @treturn {table,...} `{ {subject=, score=, matched={ phrase, ... }}, ... }`
function M.classify(text, model)
  local by = model or load()
  local has = {}
  for _, g in ipairs(lulibre.phrases(text or "")) do has[g] = true end
  local out = {}
  for subject, terms in pairs(by) do
    local sum, matched = 0, {}
    for term, score in pairs(terms) do
      if has[term] then
        sum = sum + score
        matched[#matched + 1] = term
      end
    end
    if #matched > 0 then
      table.sort(matched, function(a, b)
        if terms[a] ~= terms[b] then return terms[a] > terms[b] end
        return a < b
      end)
      out[#out + 1] = { subject = subject, score = sum, matched = matched }
    end
  end
  table.sort(out, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    return a.subject < b.subject
  end)
  return out
end

local function related(a, b)
  return a == b or a:sub(1, #b + 1) == b .. "/" or b:sub(1, #a + 1) == a .. "/"
end

--- Returns the subject to suggest for a text, how sure the suggestion is,
-- and the phrases behind it. Returns nil if the text's phrases mark no
-- subject, or too weakly. A suggestion needs at least two marking phrases.
-- If a subject and a narrower subject both fit, the narrower one is taken
-- if it fits nearly as well.
-- @tparam string text
-- @tparam[opt] table model as for `classify`
-- @treturn[1] string the subject
-- @treturn[1] number how sure
-- @treturn[1] {string,...} the phrases
-- @treturn[2] nil
function M.suggest(text, model)
  local ranked = M.classify(text, model)
  local best
  for _, r in ipairs(ranked) do
    if #r.matched >= 2 then
      best = r
      break
    end
  end
  if not best then return nil end
  for _, r in ipairs(ranked) do
    if r ~= best and #r.matched >= 2 and #r.subject > #best.subject and related(r.subject, best.subject)
      and r.score >= 0.6 * best.score then
      best = r
    end
  end
  -- how far ahead it is of the best subject on another branch
  local rival = 0
  for _, r in ipairs(ranked) do
    if not related(r.subject, best.subject) then
      rival = r.score
      break
    end
  end
  local confidence = math.min(0.85, 0.4 + 0.08 * #best.matched)
  if rival > 0 and best.score < 1.5 * rival then confidence = confidence - 0.15 end
  return best.subject, confidence, best.matched
end

return M
