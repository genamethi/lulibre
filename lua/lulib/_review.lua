--- The review view (design 16, 18, 33, 34), a uiman.list on a review (wit).
--
-- One field's wits per row, under a heading per book; space cycles a row
-- through its alternatives. Accepting and rejecting only mark a row, and w
-- writes what is marked. A review keeps its proposals and marks until then,
-- however long, as what the record holds is read afresh; with the setting
-- review_prune it drops a proposal when the record comes to hold its value.
--
-- The screen "review": a accepts the alternative in view, e edits it
-- first, r rejects the row, u takes the mark off, space shows the next
-- alternative, w writes what is marked, z shows what the review otherwise
-- doesn't; s names the review, o opens another, n starts a new one, d
-- discards it, A adds books to it, E asks the online services about its
-- books, p drops what the record now holds; q closes.
-- keymap.set("review", key, action) rebinds them.
--
-- @library lulib._review
local bookman = require "bookman"
local propose = require "lulib._propose"
local wit = require "wit"

local M = {}
local own, get = require "lulib._expose" (M) -- internal (expose_modules)

-- a score as a percentage
local function shown_score(s)
  return s and ("%d%%"):format(math.floor(s * 100 + 0.5)) or ""
end

-- The screen, and what each of its actions does to a field's row: e the
-- row, alt the alternative in view, view the review's own state. With
-- expose_modules, an action is added by adding it to both and making
-- the screen again:
--     local review = require "lulib._review"
--     table.insert(review.screen.actions, { "mine", "m", "what it does" })
--     review.actions.mine = function(e, alt, view) ... end
--     scrnman.create("review", review.screen)
own.screen = {
  actions = {
    { "accept", "a", "mark the alternative in view accepted" },
    { "edit", "e", "edit the alternative in view, and mark that accepted" },
    { "reject", "r", "mark the row rejected" },
    { "unmark", "u", "take the mark off the row" },
    { "next", "<Space>", "show the row's next alternative" },
    { "write", "w", "write what is marked" },
    { "deep", "z", "show or hide what the review otherwise doesn't show" },
    { "name", "s", "name the review, which keeps it under that name" },
    { "recall", "o", "open another review" },
    { "fresh", "n", "start a new review" },
    { "discard", "d", "discard the review" },
    { "add", "A", "add books to the review, by a filter" },
    { "sources", "E", "ask the online services about the review's books" },
    { "prune", "p", "drop what the record now holds" },
  },
  hint = { "accept", "edit", "reject", "next", "write", "deep", "recall" },
}
-- those that are about the review and not a row
own.whole = { write = true, deep = true, name = true, recall = true, fresh = true, discard = true, add = true,
              sources = true, prune = true }
own.actions = {
  accept = function(_, alt) return wit.accept(alt.id) end,
  edit = function(e, alt)
    local value = uiman.input { prompt = e.field .. ": ", default = alt.edited or alt.value }
    if value then return wit.accept(alt.id, value) end
    return true
  end,
  reject = function(_, alt) return wit.reject(alt.id) end,
  unmark = function(_, alt) return wit.unmark(alt.id) end,
  next = function(e, _, view)
    view.which[e.key] = e.i % #e.alts + 1
    return true
  end,
  write = function()
    local batch, n = wit.write()
    if batch == nil then return nil, n end
    uiman.notify(n == 0 and "nothing is marked" or ("written: %d field%s"):format(n, n == 1 and "" or "s"))
    return true
  end,
  deep = function(_, _, view)
    view.deep = not view.deep
    return true
  end,
  name = function()
    local cur = wit.current()
    local was
    for _, r in ipairs(wit.reviews()) do
      if r.id == cur then was = r.name end
    end
    local name = uiman.input { prompt = "review's name: ", default = was or "" }
    if name and name ~= "" then wit.name(cur, name) end
    return true
  end,
  recall = function(_, _, view)
    local list, labels = wit.reviews(), {}
    for i, r in ipairs(list) do labels[i] = get("label")(r) end
    local _, i = uiman.pick(labels, { title = "reviews" })
    if i then
      wit.open(list[i].id)
      view.filter = nil
    end
    return true
  end,
  fresh = function(_, _, view)
    wit.new()
    view.filter = nil
    return true
  end,
  discard = function(_, _, view)
    local answer = uiman.input { prompt = "discard this review and its marks? (y/N) " }
    if answer and answer:lower():sub(1, 1) == "y" then
      wit.discard(wit.current())
      view.filter = nil
    end
    return true
  end,
  add = function(_, _, view)
    local filter = uiman.input { prompt = "add books by filter: " }
    if not filter or filter == "" then return true end
    local w <const> = propose.settings()
    for _, book in ipairs(bookman.ids(filter)) do
      propose.propose(book, w)
      if view.filter then view.filter[#view.filter + 1] = book end
    end
    return true
  end,
  sources = function(_, _, view)
    local books = view.filter or wit.books { deep = true }
    taskman.spawn(function()
      local net = require "net"
      for _, book in ipairs(books) do net.enrich(book) end
    end)
    uiman.notify(("asking the online services about %d book%s"):format(#books, #books == 1 and "" or "s"))
    return true
  end,
  prune = function()
    uiman.notify(("dropped %d"):format(wit.prune()))
    return true
  end,
}
scrnman.create("review", own.screen)

-- a review as the picker lists it
function own.label(r)
  return ("%s  (%d book%s, %d marked)"):format(r.name or ("review " .. r.id), r.books, r.books == 1 and "" or "s", r.marked)
end

--- A row's cells: the mark, field, the record's value, the alternative in
-- view (and which of how many), its score, where it came from and what
-- agrees.
function M.cells(entry, current)
  local alt = entry.alts[entry.i]
  local which = #entry.alts > 1 and (" (%d/%d)"):format(entry.i, #entry.alts) or ""
  local agree = alt.agree and ("agrees: " .. alt.agree) or (alt.disagree and ("differs: " .. alt.disagree) or "")
  local mark = alt.decision == "accept" and "+" or alt.decision == "reject" and "-" or ""
  return { mark, entry.field, current or "", ((alt.edited or alt.value) == "" and "(blank)" or alt.edited or alt.value) .. which, shown_score(alt.score), alt.source, agree }
end

--- Opens the view on the current review, and returns when it closes.
-- @tparam[opt] {integer,...} books only these books' proposals
-- @tparam[opt] table o `{ deep= }`: show what a review otherwise doesn't
function M.open(books, o)
  local which = {} -- per book and field, the alternative in view
  local view = { which = which, filter = books, deep = o and o.deep }
  if setman.get("review_prune") then wit.prune() end
  -- per book with wits, a heading and a row per field
  local function entries()
    local out = {}
    for _, book in ipairs(view.filter or wit.books { deep = view.deep }) do
      local fields = wit.get(book, { deep = view.deep })
      if #fields > 0 then
        local title = bookman.get(book, "title")
        out[#out + 1] = { book = book, head = title and title ~= "" and title or ("book " .. book) }
        for _, f in ipairs(fields) do
          local key = book .. "\0" .. f.field
          local i = which[key]
          if not i then
            for n, a in ipairs(f.alts) do
              if a.decision then i = n end
            end
          end
          which[key] = math.min(i or 1, #f.alts)
          out[#out + 1] = { book = book, field = f.field, alts = f.alts, i = which[key], key = key }
        end
      end
    end
    if #out == 0 then out[1] = { note = "no proposals for these books: :propose makes them" } end
    return out
  end
  -- an action as the module's actions say when it is taken: on a field's
  -- row, or anywhere if it is about the review
  local actions = {}
  for _, a in ipairs(get("screen").actions) do
    actions[a[1]] = function(e)
      local fn = get("actions")[a[1]]
      if fn and (e.alts or get("whole")[a[1]]) then return fn(e, e.alts and e.alts[e.i], view) end
    end
  end
  local function title()
    local cur = wit.current()
    for _, r in ipairs(wit.reviews()) do
      if r.id == cur then
        local name = r.name and ("review: " .. r.name) or "review"
        return view.deep and name .. "  (deep)" or name
      end
    end
    return "review"
  end
  uiman.list {
    title = title, screen = "review", follow = true,
    columns = { { "", 1 }, { "Field", 10 }, "Record", "Proposed", { "Score", 5 }, { "From", 12 }, { "Sources", 20 } },
    items = entries,
    row = function(e)
      if e.note then return { e.note, style = "note" } end
      if e.head then return { e.head, id = e.book, style = "head" } end
      local r = M.cells(e, wit.now(e.book, e.field))
      r.id = e.book
      return r
    end,
    actions = actions,
    refresh = {
      proposed = false,
      records_changed = function()
        if setman.get("review_prune") then wit.prune() end
      end,
    },
  }
end

return M
