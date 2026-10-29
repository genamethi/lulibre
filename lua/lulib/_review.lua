--- The review view (design 16, 18, 33, 34), a uiman.list.
--
-- One field's wits per row, under a heading per book; space cycles a row
-- through its alternatives. "Records changed" for a book in view proposes
-- for the book again, so its rows are ranked against the record as it now
-- stands.
--
-- Keys: a accepts the alternative in view, e edits it first, r rejects the
-- row, space shows the next alternative, q closes.
--
-- @library lulib._review
local bookman = require "bookman"
local propose = require "lulib._propose"
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

--- Opens the view on the books' wits, and returns when it closes.
-- @tparam {integer,...} books
function M.open(books)
  local w <const> = propose.settings()
  local in_view, which = {}, {} -- the books; per book and field, the alternative in view
  for _, book in ipairs(books) do in_view[book] = true end
  -- per book with wits, a heading and a row per field
  local function entries()
    local out = {}
    for _, book in ipairs(books) do
      local fields = wit.get(book)
      if #fields > 0 then
        local title = bookman.get(book, "title")
        out[#out + 1] = { book = book, head = title and title ~= "" and title or ("book " .. book) }
        for _, f in ipairs(fields) do
          local key = book .. "\0" .. f.field
          which[key] = math.min(which[key] or 1, #f.alts)
          out[#out + 1] = { book = book, field = f.field, alts = f.alts, i = which[key], key = key }
        end
      end
    end
    if #out == 0 then out[1] = { note = "no proposals for these books: :propose makes them" } end
    return out
  end
  -- a key's action on a field's row; a heading's or the note's does nothing
  local function on(fn)
    return function(e) if e.alts then return fn(e, e.alts[e.i]) end end
  end
  uiman.list {
    title = "review", help = M.help, follow = true,
    columns = { { "Field", 10 }, "Record", "Proposed", { "From", 12 }, { "Sources", 20 } },
    items = entries,
    row = function(e)
      if e.note then return { e.note, style = "note" } end
      if e.head then return { e.head, id = e.book, style = "head" } end
      local r = M.cells(e, bookman.get(e.book, e.field))
      r.id = e.book
      return r
    end,
    keys = {
      a = on(function(_, alt) return wit.accept(alt.id) end),
      e = on(function(e, alt)
        local value = uiman.input { prompt = e.field .. ": ", default = alt.value }
        if value then return wit.accept(alt.id, value) end
        return true
      end),
      r = on(function(_, alt) return wit.reject(alt.id) end),
      ["<Space>"] = on(function(e) which[e.key] = e.i % #e.alts + 1 return true end),
    },
    refresh = {
      records_changed = function(ev)
        for _, book in ipairs(ev.ids) do
          if in_view[book] then propose.propose(book, w) end
        end
      end,
    },
  }
end

return M
