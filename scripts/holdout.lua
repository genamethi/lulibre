-- How well do the learned subjects do on books they were not taught by?
-- The confirmed records (gk) are cut into parts; each part in turn is left
-- out, the phrases are learned from the others, and the subject of every
-- book left out is asked for and held against the tags it has.
--   :run holdout            five parts
--   :run holdout 10         ten (more to learn from each time, and slower)
--   :run holdout --wrong    name every book it got wrong, with the phrases
--   lulibre run holdout [N] [--wrong]
-- Nothing is kept or changed: what :learn has learned stays as it is.
--
-- Read the result for what it is. A book has several subjects and its tags
-- name one or two, so "not among its tags" is not always "wrong"; and a
-- few dozen books for a subject are few. It is for seeing whether a change
-- (more books confirmed, a phrase dropped in :terms, another threshold in
-- lulibre.learn) made things better or worse.
local learn = require "lulibre.learn"
local quality = require "lulibre.quality"

local parts, list_wrong = 5, false
for _, a in ipairs({ ... }) do
  if a == "--wrong" then list_wrong = true
  elseif tonumber(a) and tonumber(a) >= 2 and tonumber(a) % 1 == 0 then parts = math.tointeger(tonumber(a))
  else error(("holdout takes a number of parts (2 or more) and --wrong, not '%s'"):format(a), 0) end
end

local good = quality.good_ids()
if #good < parts * 4 then
  error(("%d confirmed records are too few to leave some out: confirm more with %s"):format(#good, lulibre.hint("good")), 0)
end
-- the same cut every time, and not by id (neighbouring ids are often one author's)
local function mix(id) return (id * 7919) % 104729 end
table.sort(good, function(a, b)
  if mix(a) ~= mix(b) then return mix(a) < mix(b) end
  return a < b
end)

-- the subjects a book's tags stand for: each, and those above it, less the catch-alls
local function subjects(book)
  local set, n = {}, 0
  for _, tag in ipairs(book.tags or {}) do
    for _, s in ipairs(learn.lineage(tag)) do
      if not quality.catchall(s) and not set[s] then set[s], n = true, n + 1 end
    end
  end
  return set, n
end

local function judge(subject, set, tags)
  if set[subject] then return "right" end
  for _, tag in ipairs(tags or {}) do
    if subject:sub(1, #tag + 1) == tag .. "/" then return "finer" end -- below a tag the book has
  end
  return "wrong"
end

local census = learn.census()
local tally = { right = 0, finer = 0, wrong = 0, silent = 0, unlearned = 0, untagged = 0 }
local by_subject, by_sure, wrongs = {}, {}, {}
local function count(t, key, ok)
  t[key] = t[key] or { said = 0, ok = 0 }
  t[key].said = t[key].said + 1
  if ok then t[key].ok = t[key].ok + 1 end
end
for part = 1, parts do
  local from, held = {}, {}
  for i, id in ipairs(good) do
    if (i - 1) % parts + 1 == part then held[#held + 1] = id else from[#from + 1] = id end
  end
  lulibre.progress(("leaving out part %d of %d"):format(part, parts))
  local got = assert(learn.work { from = from, census = census })
  local model = learn.model(got)
  for _, id in ipairs(held) do
    local book = lulibre.book(id)
    local set, n = subjects(book)
    local subject, sure, why = learn.suggest(learn.text(id, true) or "", model)
    if n == 0 then
      tally.untagged = tally.untagged + 1
    elseif not subject then
      local could = false
      for s in pairs(set) do
        if model[s] then could = true end
      end
      if could then tally.silent = tally.silent + 1 else tally.unlearned = tally.unlearned + 1 end
    else
      local verdict = judge(subject, set, book.tags)
      tally[verdict] = tally[verdict] + 1
      count(by_subject, subject, verdict ~= "wrong")
      count(by_sure, #why >= 5 and "5 or more" or tostring(#why), verdict ~= "wrong")
      if verdict == "wrong" then
        wrongs[#wrongs + 1] = ("  %-5d %-44s has %-30s said %s (%s)"):format(id, (book.title or ""):sub(1, 44),
          table.concat(book.tags or {}, ", "):sub(1, 30), subject, table.concat(why, ", ", 1, math.min(3, #why)))
      end
    end
  end
  if lulibre.task_id() then lulibre.yield() end
end
census.counter:close()
lulibre.progress(nil)

local said = tally.right + tally.finer + tally.wrong
local out = {}
local function line(...) out[#out + 1] = string.format(...) end
line("%d confirmed records, each left out once (%d parts); %d books in the library read", #good, parts, census.total)
line("")
line("a subject was said for %d of %d:", said, #good - tally.untagged)
line("  %4d  a subject the book has", tally.right)
line("  %4d  finer than a tag the book has", tally.finer)
line("  %4d  not among its tags", tally.wrong)
line("nothing was said for %d:", tally.silent + tally.unlearned)
line("  %4d  too few of its phrases", tally.silent)
line("  %4d  none of its subjects has enough confirmed books to be learned", tally.unlearned)
if tally.untagged > 0 then line("%d have only catch-all tags and were not counted", tally.untagged) end
local function table_of(title, t, order)
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys, order)
  line("")
  line(title)
  for _, k in ipairs(keys) do line("  %-36s %4d said  %4d of them among the book's subjects", k, t[k].said, t[k].ok) end
end
table_of("by the subject said:", by_subject)
table_of("by how many marking phrases the book had (what the confidence is made of):", by_sure)
if list_wrong then
  line("")
  line("not among the book's tags:")
  for _, w in ipairs(wrongs) do out[#out + 1] = w end
elseif #wrongs > 0 then
  line("")
  line("%s names the %d that were not among the book's tags, with the phrases", lulibre.headless and "--wrong" or ":run holdout --wrong", #wrongs)
end

if lulibre.headless then
  print(table.concat(out, "\n"))
else
  lulibre.show(table.concat(out, "\n"), "learned subjects, tried on books left out")
end
