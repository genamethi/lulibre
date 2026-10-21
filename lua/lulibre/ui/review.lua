--- Reviews proposed changes. Accept, reject or correct each proposal, then
-- write the accepted ones as one batch. The list and preview follow the
-- cursor, so the book's title page is in view while you decide.
--
-- x expands a book: its other fields appear under the proposals, so you can
-- compare the proposals with what is already known. You can edit any of
-- those fields in the same pass, and the edit becomes an accepted proposal.
--
-- Review has views, shown as tabs in its bar: one for each run of proposing
-- that still has proposals waiting (lulibre.runs), and "all waiting". h and
-- l move between views, and D drops the proposals of the view shown.
--
-- @screens lulibre.ui.review
-- @usage
-- require("lulibre.ui.review").run()   -- as :review, gr does
local context = require "lulibre.ui.context"
local edit = require "lulibre.edit"
local proposals = require "lulibre.proposals"
local suggest = require "lulibre.suggest"
local runs = require "lulibre.runs"
local verify = require "lulibre.verify"

local M = {}

--- The mark a row shows for what the book's pages say about its proposal,
-- by verify.judge's levels. Replace the table in init.lua to use other marks.
M.marks = { better = "●", more = "●", both = "=", partly = "◐", silent = "·", neither = "○", against = "✗" }

local keys = require("lulibre.ui.keys").of("review")
local panels = require "lulibre.ui.panels"

-- the fields a book opens up to, in the order they are shown
M.fields = { "title", "authors", "pubdate", "tags", "publisher", "series", "identifiers" }

-- fields that hold one value: their proposals are alternatives to each
-- other, and with one row per field (the option review_rows) one is shown
-- at a time
M.single = { title = true, authors = true, pubdate = true, publisher = true, series = true, series_index = true,
  languages = true }

--- Returns what the panel in place of the list shows about the proposal
-- under the cursor (the option review_context; i shows and hides the
-- panel). Replace this function in init.lua to show something else:
-- require("lulibre.ui.review").context = function(pr, others) return { { "source", pr.source } } end
-- @tparam table pr the proposal
-- @tparam {table,...} others the other proposals waiting for that book and field
-- @treturn {table,...} rows of `{ label, text, style = }`
function M.context(pr, others)
  return context.rows(pr, others)
end

local function key_of(item)
  if not item then return nil end
  if item.banner then return "b" end
  if item.heading then return "h" .. item.book end
  if item.plain then return "f" .. item.book .. item.field end
  return "p" .. item.id
end

--- Returns the line at the top of a view, which says what the view is and
-- how to drop it. Returning nil shows no line. Replace this function in
-- init.lua to change the line, or to remove it:
--
--    require("lulibre.ui.review").banner = function() end
--
-- @tparam table view `{ run=, count= }`: the view's run (from lulibre.runs) or nil, and how
-- many proposals the view holds
-- @tparam function key `key(action)` returns the key bound to one of review's actions
-- @treturn string|nil
function M.banner(view, key)
  local run = view.run
  if not run then return nil end
  local books = ("%d book%s"):format(#run.ids, #run.ids == 1 and "" or "s")
  if not run.finished then
    return ("⟳ still proposing for %s%s: what it finds appears here, and this view comes up by itself when it is done.   %s stops it")
      :format(books, run.step and (" (%s)"):format(run.step) or "", key("drop") or "drop")
  end
  local before = (view.count or 0) - (view.own or 0)
  return ("proposed at %s for %s: %d waiting%s.   %s drops what this run added   %s %s the other views"):format(
    os.date("%H:%M", run.started), books, view.count or 0, before > 0 and (", %d of them from before"):format(before) or "",
    key("drop") or "drop", key("prev_view") or "", key("next_view") or "")
end

local session

--- Opens review. A filter (as :review FILTER gives it) or `{ ids = {...} }`
-- limits review to those books' proposals. `{ run = run }` opens on that
-- run's view. Otherwise review opens on a run that is in progress or not
-- yet seen, if there is one, or else on everything waiting for the books
-- the list shows. The other views are one key away.
-- @tparam[opt] string|table args a filter, `{ ids = {...} }` or `{ run = run }`
function M.run(args)
  local before = M.live
  local r = table.pack(pcall(session, args))
  M.live = before
  if not r[1] then error(r[2], 0) end
  return table.unpack(r, 2, r.n)
end

--- Shows a run's proposals: in the open review if there is one, or else in
-- a new review.
-- @tparam table run
function M.show_run(run)
  if M.live and pcall(M.live.show, "run:" .. run.id) then return end
  return M.run { run = run }
end

-- a review that is open hears of runs starting, moving on and ending
runs.on(function()
  if M.live then pcall(M.live.changed) end
end)

session = function(args)
  -- proposals for what the list is showing: the library, or the sync folder
  local scope = lulibre.source()
  if type(args) == "string" then args = args ~= "" and { filter = args } or {} end
  args = args or {}
  -- a view of its own for the books review was asked to keep to
  local asked
  if args.ids or args.filter then
    local ids, set = args.ids or lulibre.ids(args.filter), {}
    for _, id in ipairs(ids) do set[id] = true end
    asked = { key = "asked", only = set, fields = args.fields, floor = tonumber(args.min), n = #ids }
  end
  -- one field's proposals only, when set (f then a letter); accept-all and
  -- reject-rest then speak for that field alone
  local field_only = args.field
  -- The views: what was asked for, each run with something waiting, and all.
  local views, at = {}, 1
  local function in_view(view, pr)
    if view.run then return runs.covers(view.run, pr) end
    return (not view.only or view.only[pr.book]) and (not view.fields or view.fields[pr.field])
      and (not view.floor or (pr.confidence or 0) >= view.floor or pr.status == "accepted")
  end
  local function make_views(want)
    want = want or (views[at] and views[at].key)
    views = {}
    if asked then views[1] = asked end
    for _, run in ipairs(runs.list(scope)) do views[#views + 1] = { key = "run:" .. run.id, run = run } end
    views[#views + 1] = { key = "all" }
    at = #views
    for i, view in ipairs(views) do
      if view.key == want then at = i end
    end
    local all = proposals.list(nil, scope)
    for _, view in ipairs(views) do
      view.count, view.own = 0, 0
      for _, pr in ipairs(all) do
        if in_view(view, pr) then
          view.count = view.count + 1
          -- a run's view also holds what waited for its books before it began
          if not view.run or runs.own(view.run, pr) then view.own = view.own + 1 end
        end
      end
    end
  end
  -- asked for nothing in particular, review opens on a run that is going on
  -- or has not been looked at yet: what was just proposed, not the whole pile
  local fresh = not args.run and not asked and not field_only and runs.fresh(scope)
  make_views((args.run or fresh) and ("run:" .. (args.run or fresh).id) or asked and "asked" or "all")
  local function tab_names()
    if #views < 2 then return {} end
    local names = {}
    for i, view in ipairs(views) do
      names[i] = view.run and ("%s%s (%d)"):format(view.run.finished and "" or "⟳ ", view.run.label, view.count)
        or view.key == "all" and ("all waiting (%d)"):format(view.count)
        or ("%d book%s (%d)"):format(view.n, view.n == 1 and "" or "s", view.count)
    end
    return names
  end
  -- the books the view in front keeps to (nil: every book)
  local function books_of(view)
    if not view.run then return view.only end
    runs.covers(view.run, { book = 0 })
    return view.run.books
  end
  -- the proposals with a status (pending and accepted when nil) that the view in front covers
  local function listed(status)
    local view, out = views[at], {}
    for _, pr in ipairs(proposals.list(status, scope)) do
      if in_view(view, pr) and (not field_only or pr.field == field_only) then out[#out + 1] = pr end
    end
    return out
  end
  local items       -- row index -> a proposal, { plain=, book=, field= } or { heading=, book= }
  local open = {}   -- book id -> its other fields are shown
  -- one row per field, or every proposal its own; and which proposal a field's row shows
  local rows_mode = args.rows or lulibre.o.review_rows or "field"
  local chosen = {} -- "book\0field" -> proposal id
  -- the proposals that are alternatives for one book's field (single-valued, op set), surest first
  local function alternatives(pr)
    local out = {}
    if not (M.single[pr.field] and pr.op == "set") then return out end
    for _, q in ipairs(listed()) do
      if q.book == pr.book and q.field == pr.field and q.op == "set" then out[#out + 1] = q end
    end
    table.sort(out, function(a, b)
      if (a.confidence or 0) ~= (b.confidence or 0) then return (a.confidence or 0) > (b.confidence or 0) end
      return a.id < b.id
    end)
    return out
  end
  -- the one a field's row shows: the one picked with o or O, else the accepted one, else the surest
  local function shown_of(group)
    local slot = group[1].book .. "\0" .. group[1].field
    for _, q in ipairs(group) do
      if q.id == chosen[slot] then return q end
    end
    for _, q in ipairs(group) do
      if q.status == "accepted" then return q end
    end
    return group[1]
  end
  local options = {} -- "book field" -> suggestions, read once

  -- The order of the books. With "confidence" the book whose surest proposal
  -- is surest comes first, so what can be accepted at a glance is at the top
  -- and what needs thought is further down. It is worked out when review
  -- opens, on s and when the library changes, not after every key: a book
  -- does not jump away because one of its proposals was rejected.
  -- "disputed" puts first the books whose sources disagree most about a
  -- field (the note propose leaves: "2/3 agree, 0.41 apart"): where a look
  -- is most needed.
  local sort = args.sort or ((args.run or fresh) and (args.run or fresh).sort) or lulibre.o.review_sort
  local SORTS = { evidence = "best borne out first", confidence = "surest first", disputed = "most disputed first",
    id = "by id" }
  -- what the pages say of each proposal, worked out once (a value edited is judged again)
  local judged = {}
  local function judge(pr)
    local k = pr.id .. "\0" .. (pr.value or "")
    if not judged[k] then
      local ok, j = pcall(verify.judge, pr)
      judged[k] = ok and j or { level = "silent", says = tostring(j) }
    end
    return judged[k]
  end
  local rank
  local function rank_books()
    local best, apart, borne, ids = {}, {}, {}, {}
    for _, pr in ipairs(listed()) do
      if not best[pr.book] then
        best[pr.book], apart[pr.book], borne[pr.book] = -1, 0, -1
        ids[#ids + 1] = pr.book
      end
      best[pr.book] = math.max(best[pr.book], pr.confidence or 0)
      apart[pr.book] = math.max(apart[pr.book], tonumber((pr.note or ""):match("([%d.]+) apart")) or 0)
      if sort == "evidence" and pr.status == "pending" then
        borne[pr.book] = math.max(borne[pr.book], verify.LEVELS[judge(pr).level] or 0)
      end
    end
    table.sort(ids, function(a, b)
      if sort == "evidence" and borne[a] ~= borne[b] then return borne[a] > borne[b] end
      if (sort == "confidence" or sort == "evidence") and best[a] ~= best[b] then return best[a] > best[b] end
      if sort == "disputed" and apart[a] ~= apart[b] then return apart[a] > apart[b] end
      return math.abs(a) < math.abs(b)
    end)
    rank = {}
    for i, id in ipairs(ids) do rank[id] = i end
  end
  rank_books()

  local function proposal_row(book, pr, of)
    local shown = pr.value == "" and edit.BLANK or pr.value
    if pr.op == "add" then shown = "+ " .. shown elseif pr.op == "remove" then shown = "- " .. shown end
    return {
      (pr.status == "accepted" and "✓" or " ") .. (M.marks[judge(pr).level] or " "), pr.field, edit.current(book, pr.field), shown,
      -- where it is from, how sure, how far the book's sources agree about the field, and
      -- (one row per field) which of the field's proposals this is
      ("%s%s%s%s"):format(of and ("%d/%d "):format(of[1], of[2]) or "", pr.source or "",
        pr.confidence and (" %.2f"):format(pr.confidence) or "",
        pr.note and pr.note:find(" agree") and ("  [%s]"):format(pr.note:match("^%d+/%d+") or "") or ""),
      id = book.id, style = pr.status == "accepted" and "ok" or nil,
    }
  end

  local function build()
    local rows = {}
    items = {}
    local say = M.banner and M.banner(views[at], function(action) return keys:key(action) end)
    if say then
      rows[1] = { say, style = "note" }
      items[1] = { banner = true }
    end
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
        -- with one row per field, a field's alternatives stand behind the one shown
        local done = {}
        local function put(pr)
          local of
          if rows_mode == "field" and M.single[pr.field] and pr.op == "set" then
            if done[pr.field] then return end
            done[pr.field] = true
            local group = {}
            for _, q in ipairs(by_book[id]) do
              if q.field == pr.field and q.op == "set" then group[#group + 1] = q end
            end
            if #group > 1 then
              table.sort(group, function(a, b)
                if sort == "evidence" then
                  local la, lb = verify.LEVELS[judge(a).level] or 0, verify.LEVELS[judge(b).level] or 0
                  if la ~= lb then return la > lb end
                end
                if (a.confidence or 0) ~= (b.confidence or 0) then return (a.confidence or 0) > (b.confidence or 0) end
                return a.id < b.id
              end)
              pr = shown_of(group)
              for i, q in ipairs(group) do
                if q == pr then of = { i, #group } end
              end
            end
          end
          rows[#rows + 1] = proposal_row(book, pr, of)
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

  -- A view with nothing in it gives way to the first that has something,
  -- unless it is a run still going on (what it finds will appear there).
  -- False when nothing waits anywhere.
  local function settle()
    local view = views[at]
    if view.count > 0 or (view.run and not view.run.finished) then return true end
    for i, other in ipairs(views) do
      if other.count > 0 or (other.run and not other.run.finished) then
        at = i
        return true
      end
    end
    return false
  end
  if not settle() or (asked and views[at] ~= asked and not args.run) then
    lulibre.notify(asked and "no proposals are waiting for that"
      or scope == "sync" and "no proposals for the sync folder (:run propose in:sync makes them)"
      or "no proposals to review (scripts such as :run propose make them)")
    return
  end
  rank_books()
  if views[at].run then runs.seen(views[at].run) end
  local rows = build()
  local function open_all()
    for _, it in ipairs(items) do
      if it.heading then open[it.book] = true end
    end
  end
  if lulibre.o.review_open ~= 0 then
    open_all()
    rows = build()
  end
  -- where the cursor starts in a view: on the first book's first line
  local function first_row()
    return (items[1] and items[1].banner and 1 or 0) + math.min(2, #rows)
  end
  local function title()
    return ("review%s  %d pending, %d accepted   %s   %s%s"):format(scope == "sync" and " (sync folder)" or "",
      #listed("pending"), #listed("accepted"), SORTS[sort] or "by id",
      rows_mode == "field" and ("one row per field (%s %s)"):format(keys:key("other") or "o", keys:key("other_all") or "O")
        or "every proposal",
      field_only and ("   only %s (%s%s shows all)"):format(field_only, keys:key("field") or "f", keys:key("field") or "f") or "")
  end
  local p <close> = panels.open("review", {
    title = title(), help = keys:hint("accept", "reject", "edit", "other", "about", "write"), follow = true, height = 0.42,
    keys = keys:own(), pass = panels.PASS, reloads = true, moves = true,
    columns = { { "", 2 }, { "Field", 12 }, { "Now", -2 }, { "Proposed", -3 }, { "From", 24 } },
    rows = rows, tabs = tab_names(), tab = at,
  })
  if not p then return end
  p:cursor(first_row())
  -- what the proposal under the cursor rests on, where the list is (the option review_context)
  local ctx
  local closing <close> = setmetatable({}, { __close = function()
    if ctx then pcall(ctx.close, ctx) end
  end })
  local function about(row)
    if not ctx then return end
    if not ctx:is_open() then
      ctx = nil
      return
    end
    local it = items[row]
    if it and not it.heading and not it.plain and not it.banner then
      local others = {}
      for _, q in ipairs(listed()) do
        if q.book == it.book and q.field == it.field and q.id ~= it.id then others[#others + 1] = q end
      end
      local ok, rows_ = pcall(M.context, it, others)
      ctx:rows(ok and rows_ or { { "", tostring(rows_), style = "error" } })
      ctx:title(("about this proposal   %s hides"):format(keys:key("about") or "i"))
    elseif it and it.book then
      local book = lulibre.book(it.book)
      local rows_ = { { ("book %d"):format(it.book), book and book.title or "", style = "head" } }
      if book then
        for _, field in ipairs(M.fields) do rows_[#rows_ + 1] = { field, edit.current(book, field) } end
      end
      ctx:rows(rows_)
      ctx:title("the book")
    end
  end
  local function toggle_about(row)
    if ctx and ctx:is_open() then
      ctx:close()
      ctx = nil
      return
    end
    ctx = lulibre.panel { side = "main", title = "about this proposal", columns = { { "", 14 }, { "", 0 } }, rows = {} }
    about(row)
  end
  if lulibre.o.review_context ~= 0 then toggle_about(first_row()) end
  -- other tasks reach this review here: a run that has finished asks for its
  -- view, and any change to the runs has the tabs written again
  local wanted
  M.live = {
    show = function(key)
      wanted = key
      p:send("<View>")
    end,
    changed = function() p:send("<Runs>") end,
  }
  -- go to view i: its own order, its books opened as the option says, the cursor at its top
  local to_top = false
  local function switch(i)
    at = ((i - 1) % #views) + 1
    if views[at].run and views[at].run.sort then sort = views[at].run.sort end
    if views[at].run then runs.seen(views[at].run) end
    to_top = true
  end
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
    if key == "<Move>" then
      about(row)
      goto next_key
    end
    local item = items[row]
    local keep = key_of(item) -- where the cursor should be after the rows change
    if item and item.banner then item = nil end
    local pr = item and not item.heading and not item.plain and item or nil
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
    if key == "<Tab>" then -- a tab was clicked
      make_views()
      if views[row] then switch(row) end
    elseif key == "<View>" then -- a run has finished and asks to be looked at
      make_views(wanted)
      switch(at)
    elseif key == "<Runs>" then
      make_views()
    elseif act == "next_view" or act == "prev_view" then
      make_views()
      if #views < 2 then lulibre.notify("there is one view only: everything that waits")
      else switch(at + (act == "next_view" and 1 or -1)) end
    elseif act == "drop" then
      make_views()
      local view = views[at]
      local stay = view.count - view.own
      local staying = stay > 0 and (" The %d that waited before stay."):format(stay) or ""
      if view.run and not view.run.finished then
        if lulibre.confirm(("stop this run, and drop the %d it has proposed so far?%s"):format(view.own, staying)) then
          lulibre.notify(("stopped; %d proposals dropped"):format(runs.drop(view.run)))
        end
      elseif view.count == 0 then
        lulibre.notify("nothing waits in this view")
      elseif view.own == 0 then
        lulibre.notify("nothing in this view is the run's own any more: what is here waited before it")
      elseif lulibre.confirm(("drop the %d proposal%s %s? (deleted, not rejected: they can be proposed again)%s"):format(
          view.own, view.own == 1 and "" or "s", view.run and "this run added" or "in this view", staying)) then
        local n = view.own
        if view.run then
          n = runs.drop(view.run)
        else
          local gone = {}
          for _, q in ipairs(proposals.list(nil, scope)) do
            if in_view(view, q) then gone[#gone + 1] = q.id end
          end
          for from = 1, #gone, 400 do
            lulibre.store(("DELETE FROM proposals WHERE id IN (%s)"):format(table.concat(gone, ",", from, math.min(from + 399, #gone))))
          end
        end
        lulibre.notify(("dropped %d proposal%s"):format(n, n == 1 and "" or "s"))
      end
    elseif act == "help" then
      keys:show("review", panels.also())
    elseif act == "peek" then
      peek()
    elseif act == "sort" then
      sort = sort == "evidence" and "confidence" or sort == "confidence" and "disputed" or sort == "disputed" and "id"
        or "evidence"
      rank_books()
    elseif act == "about" then
      toggle_about(row)
    elseif act == "rows" then
      rows_mode = rows_mode == "field" and "all" or "field"
      lulibre.notify(rows_mode == "field" and "one row per field: the surest proposal shown, o for the next source"
        or "every proposal a row of its own")
    elseif pr and (act == "other" or act == "other_all") then
      local group = alternatives(pr)
      if #group < 2 then
        lulibre.notify(("nothing else is proposed for this book's %s"):format(pr.field))
      elseif act == "other" then
        if rows_mode ~= "field" then rows_mode = "field" end
        local at_ = 1
        for i, q in ipairs(group) do
          if q.id == pr.id then at_ = i end
        end
        local nxt = group[at_ % #group + 1]
        chosen[pr.book .. "\0" .. pr.field] = nxt.id
        keep = "p" .. nxt.id
      else
        rows_mode = "field"
        -- the kinds of source proposing this field, in the order they first come
        local classes, seen = {}, {}
        for _, q in ipairs(listed()) do
          if q.field == pr.field and q.op == "set" then
            local c = context.source_class(q.source)
            if not seen[c] then
              seen[c] = true
              classes[#classes + 1] = c
            end
          end
        end
        local mine = context.source_class(pr.source)
        local want = classes[1]
        for i, c in ipairs(classes) do
          if c == mine then want = classes[i % #classes + 1] end
        end
        local n = 0
        for _, q in ipairs(listed()) do
          if q.field == pr.field and q.op == "set" and context.source_class(q.source) == want then
            local slot = q.book .. "\0" .. q.field
            local was = chosen[slot]
            local cur
            for _, x in ipairs(listed()) do
              if x.id == was then cur = x end
            end
            -- the surest of that kind, if a book has several
            if not cur or context.source_class(cur.source) ~= want or (q.confidence or 0) > (cur.confidence or 0) then
              chosen[slot] = q.id
              if not cur or context.source_class(cur.source) ~= want then n = n + 1 end
            end
            if q.book == pr.book then keep = "p" .. chosen[slot] end
          end
        end
        lulibre.notify(("%s: showing %s for %d book%s (the others keep theirs)"):format(pr.field, want, n, n == 1 and "" or "s"))
      end
    elseif act == "field" then
      -- the next key says which field: a letter as in :propose --only, or f again for all
      p:title(("show only: %s   (%s all)"):format("t title  a authors  s subject  i identifiers  d date  p publisher  e series", key))
      local second = p:wait()
      if not second then return end
      local propose = require "lulibre.propose"
      if second == key then
        field_only = nil
      elseif propose.FIELD[second] and #second == 1 then
        field_only = propose.FIELD[second]
        if #listed() == 0 then
          lulibre.notify(("no proposals for %s here"):format(field_only))
          field_only = nil
        end
      end
      rank_books()
    elseif key == "<Reload>" then
      verify.forget()
      judged = {}
      rank_books() -- the library changed under us: books may have gone, values may differ
    elseif act == "write" then
      if #listed("accepted") == 0 then
        lulibre.notify(("nothing accepted yet: %s accepts the proposal under the cursor"):format(keys:key("accept") or "accept"))
      else
        p:close()
        local r = proposals.apply_accepted(scope, books_of(views[at]))
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
    elseif item and item.heading and (act == "accept" or act == "reject" or act == "never") then
      -- on a book's own line the key speaks for all of its proposals
      local mine = {}
      for _, q in ipairs(listed()) do
        if q.book == item.book then mine[#mine + 1] = q end
      end
      local pending = 0
      for _, q in ipairs(mine) do
        if q.status == "pending" then pending = pending + 1 end
      end
      if act == "reject" or act == "never" then
        for _, q in ipairs(mine) do
          if q.status == "pending" then proposals.set_status(q.id, act == "never" and "barred" or "rejected") end
        end
        lulibre.notify(("%s the %d still pending for book %d"):format(act == "never" and "rejected for good" or "rejected",
          pending, item.book))
      elseif pending == 0 then
        -- all decided already: a second press takes the acceptances back
        for _, q in ipairs(mine) do proposals.set_status(q.id, "pending") end
      else
        -- one value per single-valued field: the surest wins (the list is ordered so)
        local taken, n = {}, 0
        for _, q in ipairs(mine) do
          if q.status == "accepted" and q.op == "set" then taken[q.field] = true end
        end
        for _, q in ipairs(mine) do
          if q.status == "pending" and not (q.op == "set" and taken[q.field]) then
            proposals.accept(q)
            if q.op == "set" then taken[q.field] = true end
            n = n + 1
          end
        end
        lulibre.notify(("accepted %d for book %d; %s writes them"):format(n, item.book, keys:key("write") or "write"))
      end
    elseif pr and act == "accept" then
      if pr.status == "accepted" then proposals.set_status(pr.id, "pending") else proposals.accept(pr) end
      keep = key_of(items[row + 1]) or keep
    elseif pr and (act == "reject" or act == "never") then
      proposals.set_status(pr.id, act == "never" and "barred" or "rejected")
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
    elseif item and not item.heading and act == "titlecase" then
      local book = lulibre.book(item.book)
      local was = pr and pr.value or book and edit.current(book, item.field) or ""
      local to = require("lulibre.titlecase").apply(was)
      if was == "" or to == was then lulibre.notify((pr and pr.field or item.field) .. " is in title case already")
      else answer(to) end
    elseif act == "accept_above" then
      local v = lulibre.input { prompt = "accept every pending proposal with confidence at least: ", default = "0.8" }
      local floor = tonumber(v or "")
      -- a blanket accept fills gaps without asking; replacing values a book
      -- already has is asked about, since those may well be the right ones
      local over, replacing = true, 0
      if floor then
        for _, q in ipairs(listed("pending")) do
          if (q.confidence or 0) >= floor and proposals.replaces(q) then replacing = replacing + 1 end
        end
        if replacing > 0 then
          over = lulibre.confirm(("%d of these would replace a value the book already has; accept those too?"):format(replacing))
        end
      end
      if floor then
        local n, taken = 0, {}
        for _, q in ipairs(listed("accepted")) do
          if q.op == "set" then taken[q.book .. "\0" .. q.field] = true end
        end
        for _, q in ipairs(listed("pending")) do
          -- one value per single-valued field: the strongest wins (the list is ordered so)
          local slot = q.book .. "\0" .. q.field
          if (q.confidence or 0) >= floor and not (q.op == "set" and taken[slot])
            and (over or not proposals.replaces(q)) then
            proposals.accept(q)
            taken[slot] = true
            n = n + 1
          end
        end
        lulibre.notify(("accepted %d%s; %s writes them"):format(n,
          (replacing > 0 and not over) and (", left %d that replace a value"):format(replacing) or "",
          keys:key("write") or "write"))
      end
    elseif act == "reject_rest" then
      if lulibre.confirm("reject every proposal still pending?") then
        for _, q in ipairs(listed("pending")) do proposals.set_status(q.id, "rejected") end
      end
    end
    -- the views again: a run nothing waits for any more is gone, and the counts have moved
    make_views()
    local was = views[at]
    if not settle() then
      lulibre.notify("nothing left to review")
      return
    end
    if views[at] ~= was then to_top = true end
    if to_top then
      rank_books()
      rows = build()
      if lulibre.o.review_open ~= 0 then open_all() end
    end
    rows = build()
    p:rows(rows)
    p:title(title())
    p:tabs(tab_names(), at)
    local at_row = row
    if to_top then
      to_top = false
      at_row = first_row()
      p:cursor(at_row)
    elseif keep then
      for i, it in ipairs(items) do
        if key_of(it) == keep then
          at_row = i
          p:cursor(i)
          break
        end
      end
    end
    about(at_row)
    ::next_key::
  end
end

return M
