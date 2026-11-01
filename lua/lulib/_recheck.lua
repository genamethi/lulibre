--- :verify written: goes back over what lulibre wrote, with each book's own file deciding.
-- A title or authors it wrote that the pages do not show, where what was there before
-- is shown, goes back; a DOI, ISBN or arXiv number it added that stands in the file
-- only as a cited work's, or whose kept record is plainly another work's, comes off; one
-- it took off that the file's own metadata names goes back on. Values typed by hand
-- are left alone, as are changes made outside lulibre and books whose file can't be
-- read. It goes by what was kept and asks no service anything.
--
-- The screen "recheck": p proposes it all in the current review, w writes it after
-- taking a snapshot; q closes. keymap.set("recheck", key, action) rebinds them.
--
-- @library lulib._recheck
local bookman = require "bookman"
local check = require "lulib._check"
local expr = require "expr"
local ids = require "lulib._ids"
local junk = require "lulib._junk"
local kept = require "lulib._kept"
local sql = require "sql"
local sqlite3 = require "lsqlite3"
local store = require "store"

local M = {}

--- What its judgments go by, 0 to 1. Change them here to judge otherwise.
M.limits = {
  shown = 0.8,          -- words on the pages for a value to be shown
  in_order = 0.6,       -- of a title in its order, below which it isn't what the page reads
  better = 0.15,        -- what the old title must read better by, to win over a record's
  old_in_order = 0.9,   -- or how well the old title reads, when the new isn't shown
  more_found = 0.2,     -- how many more of the old title's words must be found
  headline = 0.8,       -- of the old title in the largest type, to read as a title
}

-- headings any file may carry, never a title to go back to
local GENERIC = {}
for _, h in ipairs { "lecture notes", "lecture notes mathematics", "lecture notes in mathematics", "motivation and background",
                     "front matter", "back matter", "about the author", "about the authors", "table of contents", "list of symbols",
                     "list of contributors", "series page", "inside front cover", "title page", "half title", "notices" } do
  GENERIC[h] = true
end

local function plain_words(s)
  return (expr.fold(s or ""):gsub("[^%w]+", " "):gsub("^ ", ""):gsub(" $", ""))
end

local function significant(s)
  local n = 0
  for w in plain_words(s):gmatch("%S+") do
    if not check.minor[w] then n = n + 1 end
  end
  return n
end

-- the sources that are a catalogue's record
local function is_record(source)
  return source and require("net.service").services[source] ~= nil
end

-- a title run on with a person's name ("Noncommutative Geometry Alain"): words at its
-- end that belong to the book's people are not the title's
local function unglued(title, authors, old_authors)
  local names = {}
  for _, who in ipairs { authors or "", old_authors or "" } do
    for w in plain_words(who):gmatch("%S+") do
      if #w > 1 then names[w] = true end
    end
  end
  local out = title
  while true do
    local head, last = out:match("^(.-)%s+([%w\128-\255%.]+)%s*$")
    if not head or significant(head) < 2 or not names[plain_words(last)] then break end
    out = head
  end
  return out
end

local function share(found, words)
  return found and words and words > 0 and found / words or 0
end

-- how a record kept for an identifier reads against the pages, or nil
local function record_against(kind, value, file, k, text, c)
  local net = require "net"
  for _, r in ipairs(net.kept_for(kind, value)) do
    local verdict = check.record(r, file, k, text, c)
    if verdict then return verdict, r end
  end
end

--- What going back over the journal finds.
-- @tparam[opt] table o `{ ids=, since= }`: only these books, only after this snapshot
-- @treturn table `{ changes = { {book=, field=, value=, op=, why=}, ... }, unread=, kept=, typed=, values= }`
function M.find(o)
  o = o or {}
  local L, c <const> = M.limits, check.settings()
  local top <const>, from <const> = setman.get("id_top"), setman.get("id_refs_from")
  local wanted
  if o.ids then
    wanted = {}
    for _, id in ipairs(o.ids) do wanted[id] = true end
  end
  local db = sql.open(setman.get("path.journaldb"), sqlite3.OPEN_READONLY)
  local rows = sql.run(db, "SELECT book, field, old, new, label, source, proposed FROM journal WHERE id > ? AND state = 2"
                           .. " AND store <> 'outside' AND field IN ('title', 'authors', 'identifiers') AND book > 0 ORDER BY id",
                       o.since and o.since.upto or 0)
  db:close()
  -- per book and field, the value before lulibre's first write, whether the last was by
  -- hand, and whether what stands came from a record
  local before, order, by_hand, recorded = {}, {}, {}, {}
  for _, r in ipairs(rows) do
    if not wanted or wanted[r.book] then
      local key = r.book .. "\0" .. r.field
      if before[key] == nil then
        before[key] = r.old or ""
        order[#order + 1] = { book = r.book, field = r.field, key = key }
      end
      -- a hand edit, or a value edited in review, is the user's own word
      by_hand[key] = r.label == "edit" or (r.proposed ~= nil and r.proposed ~= r.new) or false
      recorded[key] = is_record(r.source) or false
    end
  end
  local out = { changes = {}, unread = 0, kept = 0, typed = 0, values = #order }
  local function decide(book, field, value, op, why)
    out.changes[#out.changes + 1] = { book = book, field = field, value = value, op = op, why = why }
  end
  for i, item in ipairs(order) do
    if i % 100 == 0 then uiman.progress(("rechecking %d/%d"):format(i, #order)) end
    local book, key = item.book, item.key
    local old = before[key]
    if bookman.get(book) then
      local now = bookman.get(book, item.field) or ""
      local file = kept.file_of(book)
      local readable = file and file.text and file.usable ~= false
      if now == old then
        -- put back already
      elseif by_hand[key] and item.field ~= "identifiers" then
        out.typed = out.typed + 1
      elseif not readable then
        out.unread = out.unread + 1
      else
        local k <close> = kept.open(file.id, file.indexed)
        local text <close> = kept.reader(file)
        if item.field == "title" then
          local sn = share(check.count("title", now, k, text))
          local so = share(check.count("title", old, k, text))
          -- a long title is judged by its main part too: a subtitle is often set apart
          local main = now:match("^(.-)%s*[:%.]%s") or now
          local pn = math.max(check.phrase(now, k, text) or 0, significant(main) >= 2 and check.phrase(main, k, text) or 0)
          local hn = check.headline(now, k, text) or 0
          local po = check.phrase(old, k, text) or 0
          -- what it was must read as a title, set as a title is
          local plain = not junk.unlikely_title(old) and not GENERIC[plain_words(old)] and significant(old) >= 2
          local titled = plain and (check.headline(old, k, text) or 0) >= L.headline
          if recorded[key] and plain and ((pn < L.in_order and po >= pn + L.better) or (sn < L.shown and so >= L.shown and po >= L.old_in_order)) then
            decide(book, "title", unglued(old, now and bookman.get(book, "authors"), before[book .. "\0authors"]), "set",
                   ("a record's title; the pages read \"%s\" %d%%, the record's %d%%"):format(old:sub(1, 50), math.floor(po * 100 + 0.5), math.floor(pn * 100 + 0.5)))
          elseif not titled then
            out.kept = out.kept + 1
          elseif sn < 0.5 and so > sn + L.more_found then
            decide(book, "title", old, "set", ("the pages do not show \"%s\"; they show what it was"):format(now:sub(1, 60)))
          elseif pn < L.in_order and hn < L.in_order then
            decide(book, "title", old, "set", ("the title page reads \"%s\"; of \"%s\" only %d%% stands there in that order"):format(
              old:sub(1, 50), now:sub(1, 50), math.floor(math.max(pn, hn) * 100 + 0.5)))
          else
            out.kept = out.kept + 1
          end
        elseif item.field == "authors" then
          local fn, wn = check.count("authors", now, k, text)
          local fo = check.count("authors", old, k, text)
          if wn and wn > 0 and fn == 0 and (fo or 0) > 0 then
            decide(book, "authors", old, "set", ("the pages name %d of the %d it has now, and %d it had before"):format(fn, wn, fo))
          else
            out.kept = out.kept + 1
          end
        else
          local function set_of(text_)
            local set = {}
            for ident in (text_ .. ","):gmatch("%s*(.-)%s*,") do
              if ident ~= "" then set[ident:lower()] = ident end
            end
            return set
          end
          local had, has = set_of(old), set_of(now)
          local here = {}
          for _, f in ipairs(ids.of(file, k, text, top)) do here[f.kind .. ":" .. f.value] = f.own and "own" or "mentioned" end
          for low, ident in pairs(has) do
            if not had[low] then
              local kind, value = ident:match("^([^:]+):(.+)$")
              kind = kind and kind:lower()
              local canon = kind and require("mesr").canonical(kind, value) or value
              local where = kind and here[kind .. ":" .. canon]
              if not where and kind and text.get() then where = ids.place(kind, canon, text.get().text, top, file.pages, from) end
              local verdict, r
              if kind and where ~= "own" then verdict, r = record_against(kind, canon, file, k, text, c) end
              if where == "cited" then
                decide(book, "identifiers", ident, "remove", "it stands in the file only as a work it cites")
              elseif verdict and not verdict.same and where ~= "mentioned" then
                decide(book, "identifiers", ident, "remove", ("its record is of \"%s\", which the pages do not show"):format((r.fields.title or ""):sub(1, 60)))
              else
                out.kept = out.kept + 1
              end
            end
          end
          for low, ident in pairs(had) do
            local kind, value = ident:match("^([^:]+):(.+)$")
            local canon = kind and require("mesr").canonical(kind:lower(), value) or value
            if not has[low] and kind and here[kind:lower() .. ":" .. canon] == "own" then
              decide(book, "identifiers", ident, "add", "the file names it as the file's own")
            end
          end
        end
      end
    end
  end
  uiman.progress(nil)
  return out
end

--- What was found as rows of a list.
function M.rows(found)
  local rows = { { ("%d values lulibre wrote: %d to change, %d the files bear out or can't tell apart, %d on files that can't be read, %d typed by hand, left alone"):format(
    found.values, #found.changes, found.kept, found.unread, found.typed), style = "head" } }
  for _, c in ipairs(found.changes) do
    rows[#rows + 1] = { tostring(c.book), c.field, c.op == "set" and "back to" or c.op, c.value == "" and "(blank)" or c.value, c.why, id = c.book }
  end
  return rows
end

--- Proposes what was found in the current review; how many.
function M.propose(found)
  local wit = require "wit"
  for _, c in ipairs(found.changes) do
    wit.add(c.book, { field = c.field, value = c.value, source = "recheck: " .. c.why, op = c.op })
  end
  return #found.changes
end

--- Writes what was found, after a snapshot: the batch and the snapshot; nil and why.
function M.write(found)
  local changes = {}
  for i, c in ipairs(found.changes) do changes[i] = { book = c.book, field = c.field, value = c.value, op = c.op } end
  local snap = require("lulib._snapshots").take("before recheck")
  local batch, err = store.apply(changes, "recheck")
  if err then return nil, err end
  return batch, snap
end

scrnman.create("recheck", {
  actions = {
    { "propose", "p", "propose them in the current review" },
    { "write", "w", "write them now, after taking a snapshot" },
  },
  hint = { "propose", "write" },
})

--- Opens the report, and returns when it closes.
-- @tparam[opt] table o as for `find`
function M.open(o)
  local found = M.find(o)
  uiman.list {
    title = "what lulibre wrote, held against the files", screen = "recheck", follow = true,
    columns = { { "Book", 7 }, { "Field", 11 }, { "", 8 }, { "Value", -2 }, { "Why", -3 } },
    items = function() return M.rows(found) end,
    actions = {
      propose = function()
        local n = M.propose(found)
        found.changes = {}
        uiman.notify(("%d proposal%s in the review"):format(n, n == 1 and "" or "s"))
        return true
      end,
      write = function()
        if #found.changes == 0 then return true end
        local answer = uiman.input { prompt = ("change %d value%s now? a snapshot is taken first (y/N) "):format(#found.changes, #found.changes == 1 and "" or "s") }
        if not (answer and answer:lower():sub(1, 1) == "y") then return true end
        local batch, snap = M.write(found)
        if not batch then return nil, snap end
        uiman.notify(("written; snapshot %d is how it was before (:rollback %d puts it back)"):format(snap.id, snap.id))
        found.changes = {}
        return true
      end,
    },
  }
end

return M
