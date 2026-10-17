-- What a proposal in review rests on, as rows for the panel review shows
-- where the list is: the verdict of the book's own pages on it (the mark its
-- row carries, verify.judge), what the pages say of the value and of the
-- record, the record it came from (or the record an identifier leads to),
-- and what the other sources propose for the field.
--
--   local context = require "lulibre.ui.context"
--   context.record_of(pr)        --> the kept record a proposal came from or points at, or nil
--   context.source_class(src)    --> "CrossRef" for "CrossRef 10.1007/...", and so on
--   context.rows(pr, others)     --> rows: { label, text, style = }
local edit = require "lulibre.edit"
local net = require "lulibre.net"
local verify = require "lulibre.verify"

local M = {}

--- The kind of source a proposal came from, without the work it names:
-- "CrossRef 10.1007/x" and "CrossRef 10.1016/y" are both "CrossRef";
-- "CrossRef title search" stays itself; notes in brackets go.
function M.source_class(src)
  src = (src or ""):gsub("%s*%b()", "")
  if src:find("^CrossRef title search") then return "CrossRef title search" end
  for _, name in ipairs { "CrossRef", "Open Library", "OpenAlex", "zbMATH" } do
    if src:find("^" .. name) then return name end
  end
  if src:find("^arXiv %d") or src:find("^arXiv [%a%-]+/%d") then return "arXiv record" end
  if src:find("^vocabulary") then return "vocabulary" end
  return src ~= "" and src or "(none)"
end

-- the work a source names: "CrossRef 10.1/x" -> doi, "Open Library 978..." -> isbn
local function named(src)
  src = (src or ""):gsub("%s*%b()", "")
  local doi = src:match("^CrossRef (10%.%S+)") or src:match("^OpenAlex (10%.%S+)")
  if doi then return "doi", doi end
  local isbn = src:match("^Open Library ([%dXx]+)")
  if isbn then return "isbn", isbn end
  local ax = src:match("^arXiv (%d[%d.]+%d)") or src:match("^arXiv ([%a%-]+/%d+)")
  if ax then return "arxiv", ax end
  return nil
end

--- The kept record behind a proposal: the one its source names, or, for an
-- identifier, the one the identifier leads to. Returns rec, kind, value.
function M.record_of(pr)
  -- an identifier: the record it leads to, which is what taking it would bring
  if pr.field == "identifiers" then
    local kind, value = (pr.value or ""):match("^(%a+):(.+)$")
    if kind then
      kind = kind:lower()
      local rec = net.kept_record(kind, value)
      if rec then return rec, kind, value end
      local skind, svalue = named(pr.source)
      local srec = skind and net.kept_record(skind, svalue)
      if srec then return srec, skind, svalue end
      return nil, kind, value
    end
  end
  local kind, value = named(pr.source)
  if not kind then return nil end
  return net.kept_record(kind, value), kind, value
end

local function pct(x) return x and ("%d%%"):format(math.floor(x * 100 + 0.5)) or "?" end

local WHERE = {
  own = "named in the file's own metadata, or standing as the file's own",
  front = "on the opening pages",
  inside = "further in than the opening pages",
  cited = "only in the file's reference list: a work it cites",
  absent = "nowhere in what was read of the file",
  unknown = "cannot tell (the file could not be read)",
}

-- what the pages say of one value of a field, and whether that bears it out
local function judged(ev, field, value)
  if not ev then return nil end
  if field == "title" then
    local v, share = verify.title(ev, value)
    if v == "unknown" then return nil end
    return ("%s (%s of its words; %s in order, %s in the title's type)"):format(
      v == "shown" and "show it" or v == "partly" and "show part of it" or "do not show it",
      pct(share), pct(verify.phrase(ev, value)), pct(verify.headline(ev, value))), v == "shown"
  elseif field == "authors" then
    local v, shown, named_ = verify.authors(ev, value)
    if v == "unknown" then return nil end
    local said = shown == named_ and (named_ == 1 and "name them" or ("name all %d of them"):format(named_))
      or shown == 0 and (named_ == 1 and "do not name them" or ("name none of the %d"):format(named_))
      or ("name %d of the %d"):format(shown, named_)
    return said, v == "shown"
  elseif field == "identifiers" then
    local where = verify.ident(ev, (value or ""):gsub("^[+-]%s*", ""))
    return WHERE[where], where == "own" or where == "front"
  elseif field == "pubdate" then
    local d = verify.date(ev, value)
    if d == "unknown" then return nil end
    return d == "stated" and "state its year where they give a date (a copyright line, a stamp)"
      or d == "mentioned" and "have its year, but not where they give a date" or "do not have its year", d == "stated"
  elseif field == "publisher" or field == "series" then
    local v = verify.shows(ev, field, value)
    if v == "unknown" then return nil end
    return v == "shown" and "show it" or v == "partly" and "show part of it" or "do not show it", v == "shown"
  end
  return nil
end

-- how a verdict's level is shown (verify.judge)
local GOOD = { better = "ok", more = "ok", both = nil, partly = "accent", silent = "dim", neither = "warn", against = "warn" }

--- Rows for a proposal: { label, text, style = }. others: the other
-- proposals waiting for the same book and field.
function M.rows(pr, others)
  local book = lulibre.book(pr.book)
  if not book then return { { "", "the book is no longer in the library" } } end
  local rows = {}
  local function add(label, text, style) rows[#rows + 1] = { label, text or "", style = style } end
  add(("book %d"):format(book.id), book.title or "", "head")
  add("authors", edit.current(book, "authors"))
  local ev, why = verify.evidence(book.id)
  add("")
  add("proposed", ("%s %s %s"):format(pr.field, pr.op == "add" and "+" or pr.op == "remove" and "−" or "→",
    pr.value == "" and edit.BLANK or pr.value), "accent")
  add("now", edit.current(book, pr.field))
  add("from", ("%s%s"):format(pr.source or "?", pr.confidence and ("   %.2f"):format(pr.confidence) or ""))
  if pr.note and pr.note ~= "" then add("note", pr.note) end
  local j = verify.judge(pr)
  local mark = require("lulibre.ui.review").marks[j.level]
  add("verdict", ("%s %s"):format(mark or "", j.says), GOOD[j.level])
  if not ev then
    add("the pages", "cannot say: " .. (why or "the file could not be read"), "dim")
  else
    local said, good = judged(ev, pr.field, pr.value)
    -- what the pages say of the proposed value, and of the value it would replace
    if said then add("pages: new", said, good and "ok" or "warn") end
    local was = judged(ev, pr.field, edit.current(book, pr.field))
    if was and pr.op == "set" then add("pages: now", was, "dim") end
  end

  local rec, kind, value = M.record_of(pr)
  if rec then
    add("")
    add("record", rec.source or (kind .. ":" .. value), "head")
    if rec.title then add("title", rec.title) end
    if rec.authors and #rec.authors > 0 then add("authors", table.concat(rec.authors, " & ")) end
    if rec.date or rec.year then add("date", tostring(rec.date or rec.year)) end
    if rec.type then add("type", rec.type) end
    if rec.pages then add("length", ("%d pages%s"):format(rec.pages, ev and ev.pages and ("; the file has %d"):format(ev.pages) or "")) end
    if rec.publisher or rec.member then add("publisher", rec.publisher or rec.member) end
    if rec.container then add("in", rec.container) end
    if rec.series then add("series", rec.series .. (rec.series_index and (" " .. rec.series_index) or "")) end
    local ids = {}
    for k, v in pairs(rec.ids or {}) do ids[#ids + 1] = k .. ":" .. v end
    table.sort(ids)
    if #ids > 0 then add("identifiers", table.concat(ids, ", ")) end
    if ev then
      local j = verify.record(ev, rec)
      local verdict = j.another and "another work's: neither its title nor its people are on the pages"
        or j.part and ("of the whole this file is part of (%s)"):format(j.size_why or "")
        or ("its title %s; its people %s"):format(j.title, j.authors)
      add("the pages", verdict, (j.another or j.part) and "warn" or "ok")
    end
  elseif kind then
    add("")
    add("record", ("nothing kept for %s:%s (:enrich asks)"):format(kind, value), "dim")
  end

  if others and #others > 0 then
    add("")
    add("other sources", ("%d more for %s"):format(#others, pr.field), "head")
    for _, q in ipairs(others) do
      add(M.source_class(q.source), ("%s   %.2f%s"):format(q.value == "" and edit.BLANK or q.value, q.confidence or 0,
        q.status == "accepted" and "  ✓" or ""), q.status == "accepted" and "ok" or nil)
    end
  end
  return rows
end

return M
