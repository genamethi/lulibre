--- The review view (design 16, 18, 33, 34).
--
-- One field's wits per row; space cycles a row through its alternatives. The
-- task that opens the view owns the view and pulls its keys: the row shown
-- and the alternative in view live in the task's locals. "Records changed"
-- for a book in view proposes for the book again, so its rows are ranked
-- against the record as it now stands.
--
-- Keys: a accepts the alternative in view, e edits it first, r rejects the
-- row, space shows the next alternative, q closes.
--
-- @library lulibre.ui.review
local bookman = require "bookman"
local propose = require "lulibre.propose"
local wit = require "wit"

local M = {}

M.help = "a accept  e edit  r reject  <Space> next alternative  q close"

--- A row's cells: field, the record's value, the alternative in view (and
-- which of how many), where it came from and what agrees.
function M.cells(entry, current)
  local alt = entry.alts[entry.i]
  local which = #entry.alts > 1 and (" (%d/%d)"):format(entry.i, #entry.alts) or ""
  local agree = alt.agree and ("agrees: " .. alt.agree) or (alt.disagree and ("differs: " .. alt.disagree) or "")
  return { entry.field, current or "", alt.value .. which, alt.source, agree }
end

local function current(book, field)
  local b = bookman.book(book)
  if not b then return "" end
  if field == "authors" then return b.author end
  if field == "year" then return b.pubdate end
  if field == "tags" then return table.concat(b.tags or {}, ", ") end
  return b[field] or (b.idents and b.idents[field]) or ""
end

--- The entries for the books: per book with proposals, a heading and a
-- row per field.
local function entries(books)
  local out = {}
  for _, book in ipairs(books) do
    local fields = wit.get(book)
    if #fields > 0 then
      local b = bookman.book(book)
      out[#out + 1] = { book = book, head = (b and b.title or ("book " .. book)) }
      for _, f in ipairs(fields) do
        out[#out + 1] = { book = book, field = f.field, alts = f.alts, i = 1 }
      end
    end
  end
  return out
end

local function rows_of(list)
  local rows = {}
  for _, e in ipairs(list) do
    if e.head then
      rows[#rows + 1] = { e.head, id = e.book, style = "head" }
    else
      local r = M.cells(e, current(e.book, e.field))
      r.id = e.book
      rows[#rows + 1] = r
    end
  end
  if #rows == 0 then rows[1] = { "no proposals for these books: :propose makes them", style = "note" } end
  return rows
end

--- Opens the view on the books' wits, and returns when it closes.
-- @tparam {integer,...} books
function M.open(books)
  local w <const> = propose.settings()
  local list = entries(books)
  local p <close> = uiman.panel {
    title = "review", help = M.help, follow = true, keys = { "a", "e", "r", "<Space>" },
    columns = { { "Field", 10 }, "Record", "Proposed", { "From", 12 }, { "Sources", 20 } },
    rows = rows_of(list),
  }
  -- records changed for a book in view: propose again, then show it
  local in_view = {}
  for _, e in ipairs(list) do in_view[e.book] = true end
  local id = evman.add("records_changed", function(ev)
    for _, book in ipairs(ev.ids) do
      if in_view[book] then
        propose.propose(book, w)
        p:send("<Changed>")
      end
    end
  end)
  while true do
    local key, row = p:wait()
    if not key then break end
    local e = list[row]
    if key == "<Changed>" then
      list = entries(books)
      p:rows(rows_of(list))
    elseif e and not e.head then
      local alt = e.alts[e.i]
      local acted, err
      if key == "<Space>" then
        e.i = e.i % #e.alts + 1
        p:rows(rows_of(list))
      elseif key == "a" then
        acted, err = true, select(2, wit.accept(alt.id))
      elseif key == "e" then
        local value = uiman.input { prompt = e.field .. ": ", default = alt.value }
        if value then acted, err = true, select(2, wit.accept(alt.id, value)) end
      elseif key == "r" then
        acted, err = true, select(2, wit.reject(alt.id))
      end
      if err then uiman.notify(err, "error") end
      if acted then
        list = entries(books)
        p:rows(rows_of(list))
      end
    end
  end
  evman.rm(id)
end

return M
