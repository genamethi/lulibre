-- Review proposed changes: accept, reject or correct each, then write the
-- accepted ones as one batch. The list and preview follow the cursor, so the
-- book's title page is in view while you decide.
--
-- x opens a book up: its other fields appear under the proposals, so what is
-- proposed can be judged against what is already known, and any of them can
-- be edited in the same pass (an edit becomes an accepted proposal).
local edit = require "lulibre.edit"
local proposals = require "lulibre.proposals"
local suggest = require "lulibre.suggest"

local M = {}

local keys = require("lulibre.ui.keys").of("review")
local panels = require "lulibre.ui.panels"

-- the fields a book opens up to, in the order they are shown
M.fields = { "title", "authors", "pubdate", "tags", "publisher", "series", "identifiers" }

local function key_of(item)
  if not item then return nil end
  if item.heading then return "h" .. item.book end
  if item.plain then return "f" .. item.book .. item.field end
  return "p" .. item.id
end

--- Open review. args: a filter (as :review FILTER gives it) or { ids = {...} }
-- keeps it to those books' proposals; otherwise it shows every proposal for
-- what the list is showing.
function M.run(args)
  -- proposals for what the list is showing: the library, or the sync folder
  local scope = lulibre.source()
  local only -- book id -> true, when review is kept to some books
  if type(args) == "table" and args.ids then
    only = {}
    for _, id in ipairs(args.ids) do only[id] = true end
  elseif type(args) == "string" and args ~= "" then
    only = {}
    for _, id in ipairs(lulibre.ids(args)) do only[id] = true end
  end
  -- the proposals with a status (pending and accepted when nil) that this review covers
  local function listed(status)
    local all = proposals.list(status, scope)
    if not only then return all end
    local out = {}
    for _, pr in ipairs(all) do
      if only[pr.book] then out[#out + 1] = pr end
    end
    return out
  end
  local items       -- row index -> a proposal, { plain=, book=, field= } or { heading=, book= }
  local open = {}   -- book id -> its other fields are shown
  local options = {} -- "book field" -> suggestions, read once

  -- The order of the books. With "confidence" the book whose surest proposal
  -- is surest comes first, so what can be accepted at a glance is at the top
  -- and what needs thought is further down. It is worked out when review
  -- opens, on s and when the library changes, not after every key: a book
  -- does not jump away because one of its proposals was rejected.
  local sort = lulibre.o.review_sort
  local rank
  local function rank_books()
    local best, ids = {}, {}
    for _, pr in ipairs(listed()) do
      if not best[pr.book] then
        best[pr.book] = -1
        ids[#ids + 1] = pr.book
      end
      best[pr.book] = math.max(best[pr.book], pr.confidence or 0)
    end
    table.sort(ids, function(a, b)
      if sort == "confidence" and best[a] ~= best[b] then return best[a] > best[b] end
      return math.abs(a) < math.abs(b)
    end)
    rank = {}
    for i, id in ipairs(ids) do rank[id] = i end
  end
  rank_books()

  local function proposal_row(book, pr)
    local shown = pr.value == "" and edit.BLANK or pr.value
    if pr.op == "add" then shown = "+ " .. shown elseif pr.op == "remove" then shown = "- " .. shown end
    return {
      pr.status == "accepted" and "✓" or "", pr.field, edit.current(book, pr.field), shown,
      ("%s%s"):format(pr.source or "", pr.confidence and (" %.2f"):format(pr.confidence) or ""),
      id = book.id, style = pr.status == "accepted" and "ok" or nil,
    }
  end

  local function build()
    local rows = {}
    items = {}
    local by_book, order = {}, {}
    for _, pr in ipairs(listed()) do
      if not by_book[pr.book] then
        by_book[pr.book] = {}
        order[#order + 1] = pr.book
      end
      table.insert(by_book[pr.book], pr)
    end
    -- books ranked when review opened keep their place; any that came since follow
    table.sort(order, function(a, b)
      if rank[a] and rank[b] then return rank[a] < rank[b] end
      if rank[a] or rank[b] then return rank[a] ~= nil end
      return math.abs(a) < math.abs(b)
    end)
    for _, id in ipairs(order) do
      local book = lulibre.book(id)
      if book then
        local who = edit.current(book, "authors")
        local best, waiting = 0, 0
        for _, pr in ipairs(by_book[id]) do
          if pr.status == "pending" then
            waiting = waiting + 1
            best = math.max(best, pr.confidence or 0)
          end
        end
        rows[#rows + 1] = { ("%s %d  %s%s%s%s"):format(open[id] and "▾" or "▸", id, book.title or "",
          who ~= "" and ("  —  " .. who) or "", book.year and ("  (%d)"):format(book.year) or "",
          waiting > 0 and ("     %d to decide, surest %.2f"):format(waiting, best) or "     all decided"),
          id = id, style = "head" }
        items[#rows] = { heading = true, book = id }
        local function put(pr)
          rows[#rows + 1] = proposal_row(book, pr)
          items[#rows] = pr
        end
        if not open[id] then
          for _, pr in ipairs(by_book[id]) do put(pr) end
        else
          -- every field in one fixed order: proposed ones with their
          -- proposals, the rest as they stand
          local listed = {}
          for _, field in ipairs(M.fields) do
            listed[field] = true
            local any = false
            for _, pr in ipairs(by_book[id]) do
              if pr.field == field then
                put(pr)
                any = true
              end
            end
            if not any then
              rows[#rows + 1] = { "", field, edit.current(book, field), "", "", id = id, style = "dim" }
              items[#rows] = { plain = true, book = id, field = field }
            end
          end
          for _, pr in ipairs(by_book[id]) do
            if not listed[pr.field] then put(pr) end
          end
        end
      end
    end
    return rows
  end

  local rows = build()
  if #rows == 0 then
    lulibre.notify(only and "no proposals are waiting for that"
      or scope == "sync" and "no proposals for the sync folder (:run propose in:sync makes them)"
      or "no proposals to review (scripts such as :run propose make them)")
    return
  end
  if lulibre.o.review_open ~= 0 then
    for _, it in ipairs(items) do
      if it.heading then open[it.book] = true end
    end
    rows = build()
  end
  local function title()
    return ("review%s  %d pending, %d accepted   %s"):format(scope == "sync" and " (sync folder)" or "",
      #listed("pending"), #listed("accepted"), sort == "confidence" and "surest first" or "by id")
  end
  local p <close> = lulibre.panel {
    title = title(), help = keys:hint("accept", "reject", "edit", "expand", "write"), follow = true, height = 0.42,
    keys = keys:own(), pass = panels.PASS, reloads = true,
    columns = { { "", 1 }, { "Field", 12 }, { "Now", -2 }, { "Proposed", -3 }, { "From", 24 } },
    rows = rows,
  }
  p:cursor(2)
  local peek = panels.peeker(p, 0.42)

  -- Ask for a field's value, with what the file and the library suggest.
  local function ask(book_id, field, default)
    local slot = book_id .. " " .. field
    if not options[slot] then
      lulibre.progress("reading the file…")
      local ok, list = pcall(suggest.for_field, field, { book_id })
      lulibre.progress(nil)
      options[slot] = ok and list or {}
    end
    return lulibre.input { prompt = field .. ": ", default = default, suggestions = options[slot],
      separator = edit.separator[field] }
  end

  while true do
    local key, row = p:wait()
    if not key then return end
    local item = items[row]
    local pr = item and not item.heading and not item.plain and item or nil
    local keep = key_of(item) -- where the cursor should be after the rows change
    local act = keys:action(key)
    -- what a field is to become: v is what was typed, "" to blank it
    local function answer(v)
      if pr then
        local book = lulibre.book(pr.book)
        if not book then return end
        -- an empty answer blanks the field, which only "set" can mean
        local op = v == "" and "set" or pr.op
        local ok, to = pcall(edit.resolve, book, pr.field, op, v)
        if not ok then
          lulibre.notify(tostring(to), "error")
        elseif to == edit.current(book, pr.field) then
          proposals.set_status(pr.id, "rejected")
          lulibre.notify(("%s already reads that way: the proposal is dropped"):format(pr.field))
          keep = open[pr.book] and ("f" .. pr.book .. pr.field) or key_of(items[row + 1]) or key_of(items[row - 1])
        else
          proposals.set_value(pr.id, v, op)
          pr.value, pr.op = v, op
          proposals.accept(pr)
        end
      else
        -- a field nothing was proposed for: the answer becomes an accepted proposal
        for _, c in ipairs(edit.typed(item.book, item.field, v)) do
          local ok, added, pid = pcall(proposals.add, c.id, c.field, c.value, { op = c.op, source = "typed", confidence = 1 })
          if not ok then
            lulibre.notify(tostring(added), "error")
          elseif added then
            proposals.accept { id = pid, book = c.id, field = c.field, op = c.op }
            keep = "p" .. pid
          end
        end
      end
    end
    if act == "help" then
      keys:show("review", panels.also())
    elseif act == "peek" then
      peek()
    elseif act == "sort" then
      sort = sort == "confidence" and "id" or "confidence"
      rank_books()
    elseif key == "<Reload>" then
      rank_books() -- the library changed under us: books may have gone, values may differ
    elseif act == "write" then
      if #listed("accepted") == 0 then
        lulibre.notify(("nothing accepted yet: %s accepts the proposal under the cursor"):format(keys:key("accept") or "accept"))
      else
        p:close()
        local r = proposals.apply_accepted(scope, only)
        lulibre.notify(edit.summary(r), #r.failed > 0 and "error" or nil)
        return
      end
    elseif item and act == "expand" then
      open[item.book] = not open[item.book] or nil
    elseif act == "expand_all" then
      local any = next(open) ~= nil
      open = {}
      if not any then
        for _, it in ipairs(items) do
          if it.heading then open[it.book] = true end
        end
      end
    elseif pr and act == "accept" then
      if pr.status == "accepted" then proposals.set_status(pr.id, "pending") else proposals.accept(pr) end
      keep = key_of(items[row + 1]) or keep
    elseif pr and act == "reject" then
      proposals.set_status(pr.id, "rejected")
      -- an opened book shows the field as it stands in the proposal's place
      keep = open[pr.book] and ("f" .. pr.book .. pr.field) or key_of(items[row + 1]) or key_of(items[row - 1])
    elseif pr and act == "edit" then
      local v = ask(pr.book, pr.field, pr.value)
      if v then answer(v) end
    elseif item and item.plain and (act == "edit" or act == "accept") then
      local book = lulibre.book(item.book)
      local v = book and ask(item.book, item.field, edit.current(book, item.field))
      if v then answer(v) end
    elseif item and not item.heading and act == "clear" then
      answer("")
    elseif act == "accept_above" then
      local v = lulibre.input { prompt = "accept every pending proposal with confidence at least: ", default = "0.8" }
      local floor = tonumber(v or "")
      if floor then
        local n, taken = 0, {}
        for _, q in ipairs(listed("accepted")) do
          if q.op == "set" then taken[q.book .. "\0" .. q.field] = true end
        end
        for _, q in ipairs(listed("pending")) do
          -- one value per single-valued field: the strongest wins (the list is ordered so)
          local slot = q.book .. "\0" .. q.field
          if (q.confidence or 0) >= floor and not (q.op == "set" and taken[slot]) then
            proposals.accept(q)
            taken[slot] = true
            n = n + 1
          end
        end
        lulibre.notify(("accepted %d; %s writes them"):format(n, keys:key("write") or "write"))
      end
    elseif act == "reject_rest" then
      if lulibre.confirm("reject every proposal still pending?") then
        for _, q in ipairs(listed("pending")) do proposals.set_status(q.id, "rejected") end
      end
    end
    rows = build()
    if #rows == 0 then
      lulibre.notify("nothing left to review")
      return
    end
    p:rows(rows)
    p:title(title())
    if keep then
      for i, it in ipairs(items) do
        if key_of(it) == keep then
          p:cursor(i)
          break
        end
      end
    end
  end
end

return M
