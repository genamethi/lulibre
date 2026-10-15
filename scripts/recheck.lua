-- Go back over what lulibre has written, with each book's own file deciding
-- (lulibre.verify): a title or authors it wrote that the opening pages do not
-- show, where what was there before is shown, goes back; a DOI, ISBN or
-- arXiv number it added that stands in the file only as a cited work's, or
-- whose record is plainly another work's, comes off; one it took off that
-- the file's own metadata names goes back on.
--   :run recheck [filter]             say what would change; nothing is changed
--   :run recheck --list [filter]      and name every book, with the reason
--   :run recheck --propose [filter]   propose it, for review (a run of its own)
--   :run recheck --apply [filter]     change it now; a snapshot is taken first
--   --since SNAP                      only what was written after a snapshot
--   lulibre recheck ...
-- Values typed by hand are left alone, as are changes made outside lulibre
-- and books whose file could not be read (there the file cannot decide). Asks no service anything: the
-- records are the ones kept from before.
local edit = require "lulibre.edit"
local junk = require "lulibre.junk"
local net = require "lulibre.net"
local proposals = require "lulibre.proposals"
local snapshots = require "lulibre.snapshots"
local verify = require "lulibre.verify"

local mode, list, since, words = "look", false, nil, {}
local args = { ... }
local i = 1
while i <= #args do
  local a = args[i]
  if a == "--apply" then mode = "apply"
  elseif a == "--propose" then mode = "propose"
  elseif a == "--list" then list = true
  elseif a == "--since" then
    local snap, why = snapshots.find(args[i + 1])
    if not snap then error(why, 0) end
    since, i = snap, i + 1
  else words[#words + 1] = a end
  i = i + 1
end
local wanted
if #words > 0 then
  wanted = {}
  for _, id in ipairs(lulibre.ids(table.concat(words, " "))) do wanted[id] = true end
end

-- headings any file may carry, never a title to go back to
local GENERIC = {}
for _, h in ipairs { "lecture notes", "lecture notes mathematics", "lecture notes in mathematics", "motivation and background",
  "front matter", "back matter", "about the author", "about the authors", "table of contents", "list of symbols",
  "list of contributors", "series page", "inside front cover", "title page", "half title", "notices" } do
  GENERIC[h] = true
end

net.offline = true -- only what was kept
local function record_of(kind, value)
  local ok, rec
  if kind == "doi" then ok, rec = pcall(net.crossref, value)
  elseif kind == "isbn" then ok, rec = pcall(net.openlibrary, value)
  elseif kind == "arxiv" then ok, rec = pcall(net.arxiv, value) end
  return ok and type(rec) == "table" and rec or nil
end

-- values typed by hand (in the edit form, or in review): the user's own word, never undone here;
-- and values that came from a catalogue's record (or a search of one), which the file is to bear out
local typed, recorded = {}, {}
local RECORDS = { "CrossRef", "Open Library", "zbMATH", "OpenAlex", "arXiv %d", "arXiv %a+/" }
for _, p in ipairs(lulibre.sql([[SELECT book, field, value, source FROM proposals WHERE status = 'applied']])) do
  local k = p.book .. "\0" .. p.field .. "\0" .. p.value
  local src = p.source or ""
  if src:find("^typed") then typed[k] = true end
  for _, r in ipairs(RECORDS) do
    if src:find("^" .. r) then recorded[k] = true end
  end
end

-- what lulibre wrote: per book and field, the value before its first write,
-- and whether the last write was typed
local before, order, by_hand = {}, {}, {}
for _, r in ipairs(lulibre.sql([[SELECT book, field, old, new, label FROM journal WHERE id > ? AND status = 'applied'
    AND coalesce(label, '') <> 'outside' AND field IN ('title', 'authors', 'identifiers') AND book > 0 ORDER BY id]],
    since and since.upto or 0)) do
  local k = r.book .. "\0" .. r.field
  if not wanted or wanted[r.book] then
    if before[k] == nil then
      before[k] = r.old or ""
      order[#order + 1] = { book = r.book, field = r.field }
    end
    by_hand[k] = r.label == "edit" or typed[k .. "\0" .. (r.new or "")] or false
  end
end

-- a title from a file name or a title page often has a name run on to it
-- ("Noncommutative Geometry Alain"): words at its end that belong to the
-- book's people are not the title's
local function unglued(title, book, old_authors)
  local names = {}
  for _, who in ipairs { edit.current(book, "authors"), old_authors or "" } do
    for w in lulibre.fold(who):gmatch("[%w\128-\255]+") do
      if #w > 1 then names[w] = true end
    end
  end
  local out = title
  while true do
    local head, last = out:match("^(.-)%s+([%w\128-\255%.]+)%s*$")
    if not head or #verify.telling(head) < 2 or not names[lulibre.fold(last):gsub("%.$", "")] then break end
    out = head
  end
  return out
end

local changes, lines = {}, {}
local n = { books = {}, unread = 0, kept = 0, back = 0, off = 0, on = 0, typed = 0 }
local function decide(book, field, value, op, why)
  changes[#changes + 1] = { id = book.id, field = field, value = value, op = op, why = why }
  n.books[book.id] = true
  lines[#lines + 1] = ("%6d  %-11s %-7s %s\n        %s"):format(book.id, field, op == "set" and "back to" or op,
    value == "" and "(blank)" or value:sub(1, 90), why)
end

for k, item in ipairs(order) do
  if k % 100 == 0 then lulibre.progress(("rechecking %d/%d"):format(k, #order)) end
  local book = lulibre.book(item.book)
  local old = before[item.book .. "\0" .. item.field]
  if book then
    local now = edit.current(book, item.field)
    local ev = verify.evidence(book.id)
    if now == old then
      -- put back already
    elseif by_hand[item.book .. "\0" .. item.field] and item.field ~= "identifiers" then
      n.typed = n.typed + 1
    elseif not ev then
      n.unread = n.unread + 1
    elseif item.field == "title" then
      local vn, sn = verify.title(ev, now)
      local vo, so = verify.title(ev, old)
      -- a long title is judged by its main part too: a subtitle is often set apart, or left off the page
      local main = now:match("^(.-)%s*[:%.]%s") or now
      local pn = math.max(verify.phrase(ev, now) or 0, #verify.telling(main) >= 2 and verify.phrase(ev, main) or 0)
      local hn = verify.headline(ev, now) or 0
      -- what it was must read as a title: not junk, not a heading any file may have, and set as
      -- a title is (in the largest type of the first pages)
      local plain = not junk.unlikely_title(old) and not GENERIC[lulibre.fold(old):gsub("[^%w]+", " "):gsub("^ ", ""):gsub(" $", "")]
        and #verify.telling(old) >= 2
      local titled = plain and (verify.headline(ev, old) or 0) >= 0.8
      -- a title a record put there (the source of most mistakes): what the file had wins when the page reads it better
      local from_record = recorded[item.book .. "\0title\0" .. now]
      local po = verify.phrase(ev, old) or 0
      if from_record and plain and ((pn < 0.6 and po >= pn + 0.15) or (vn ~= "shown" and vo == "shown" and po >= 0.9)) then
        n.back = n.back + 1
        decide(book, "title", unglued(old, book, before[item.book .. "\0authors"]), "set", ("a record's title; the pages read \"%s\" (%d%% in order) better than it (%d%%)"):format(
          old:sub(1, 50), math.floor(po * 100 + 0.5), math.floor(pn * 100 + 0.5)))
      elseif not titled then
        n.kept = n.kept + 1
      elseif vn == "absent" and (so or 0) > (sn or 0) + 0.2 then
        n.back = n.back + 1
        decide(book, "title", old, "set", ("the pages do not show \"%s\"; they show what it was"):format(now:sub(1, 60)))
      elseif pn < 0.6 and hn < 0.6 then
        n.back = n.back + 1
        decide(book, "title", old, "set", ("the title page reads \"%s\"; of \"%s\" only %d%% stands there in that order"):format(
          old:sub(1, 50), now:sub(1, 50), math.floor(math.max(pn, hn) * 100 + 0.5)))
      else
        n.kept = n.kept + 1
      end
    elseif item.field == "authors" then
      local _, shown_n, named_n = verify.authors(ev, now)
      local _, shown_o = verify.authors(ev, old)
      if named_n > 0 and shown_n == 0 and shown_o > 0 then
        n.back = n.back + 1
        decide(book, "authors", old, "set", ("the pages name %d of the %d it has now, and %d it had before"):format(shown_n, named_n, shown_o))
      else
        n.kept = n.kept + 1
      end
    else
      local had, has = {}, {}
      for _, x in ipairs(edit.split("identifiers", old)) do had[x:lower()] = x end
      for _, x in ipairs(edit.split("identifiers", now)) do has[x:lower()] = x end
      for low, ident in pairs(has) do
        if not had[low] then
          local where = verify.ident(ev, ident)
          local kind, value = ident:match("^([^:]+):(.+)$")
          local rec = kind and where ~= "own" and record_of(kind:lower(), value)
          local judged = rec and verify.record(ev, rec)
          if where == "cited" then
            n.off = n.off + 1
            decide(book, "identifiers", ident, "remove", "it stands in the file only as a work it cites")
          elseif judged and judged.another and where ~= "front" then
            n.off = n.off + 1
            decide(book, "identifiers", ident, "remove", ("its record is of \"%s\", which the pages do not show, nor its people"):format(
              (rec.title or ""):sub(1, 60)))
          else
            n.kept = n.kept + 1
          end
        end
      end
      for low, ident in pairs(had) do
        if not has[low] and verify.ident(ev, ident) == "own" then
          n.on = n.on + 1
          decide(book, "identifiers", ident, "add", "the file's own metadata names it as the file's")
        end
      end
    end
  end
end
lulibre.progress(nil)

local nb = 0
for _ in pairs(n.books) do nb = nb + 1 end
local out = {}
local function line(...) out[#out + 1] = string.format(...) end
line("%d values lulibre wrote%s, held against the books' files:", #order, since and (" since snapshot %d"):format(since.id) or "")
line("  %d titles or authors to go back to what they were (the pages show that, not this)", n.back)
line("  %d identifiers to come off (cited works', or another work's), %d to go back on", n.off, n.on)
line("  %d the files bear out, or cannot tell apart; %d on books whose file could not be read; %d typed by hand, left alone",
  n.kept, n.unread, n.typed)
line("  %d books in all", nb)

if mode == "look" then
  if list then
    line("")
    for _, l in ipairs(lines) do out[#out + 1] = l end
  elseif #lines > 0 then
    line("")
    for j = 1, math.min(15, #lines) do out[#out + 1] = lines[j] end
    if #lines > 15 then line("... --list names all %d", #lines) end
  end
  line("")
  line("--propose puts them in review; --apply changes them now (after taking a snapshot)")
elseif mode == "propose" then
  local runs = require "lulibre.runs"
  local ids = {}
  for id in pairs(n.books) do ids[#ids + 1] = id end
  table.sort(ids)
  local run <close> = runs.join { ids = ids, label = "recheck" }
  local added = 0
  for _, c in ipairs(changes) do
    if proposals.add(c.id, c.field, c.value, { op = c.op, source = "recheck: " .. c.why, confidence = 0.9, again = true, as_is = true }) then
      added = added + 1
    end
  end
  run:done()
  line("%d proposals; %s goes through them", added, lulibre.hint("review"))
else
  if #changes > 0 then
    local snap = snapshots.take("before recheck")
    local r = edit.apply(changes, { label = "recheck" })
    -- what still waits from the title-search repair (:run unmatch --fix) is settled by this
    local _, gone = lulibre.store("DELETE FROM proposals WHERE status = 'pending' AND source LIKE 'before a wrong title match%'")
    line("%s; snapshot %d is how it was before (:rollback %d puts it back)%s", edit.summary(r), snap.id, snap.id,
      gone > 0 and ("; %d restorations waiting from :run unmatch withdrawn, as settled"):format(gone) or "")
  else
    line("nothing to change")
  end
end
if lulibre.headless then print(table.concat(out, "\n"))
else lulibre.show(out, "what lulibre wrote, held against the files") end
