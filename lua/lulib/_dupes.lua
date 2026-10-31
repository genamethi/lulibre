--- The screen on books whose files hold the same bytes (:dupes), a uiman.panel.
-- Each group keeps one copy, the one whose record says most at first. Removing
-- the rest sends them to calibre's recycle bin, and what they knew that the kept
-- copy doesn't is proposed for it, in the current review.
--
-- The screen "dupes": Space or Enter keeps the copy under the cursor, s skips the
-- group, t proposes this copy's values for the kept one, e edits, r reviews, m marks
-- the rest, f narrows the list to books with a duplicate, i shows the group side by
-- side, D removes the rest; q closes. keymap.set("dupes", key, action) rebinds them.
--
-- @library lulib._dupes
local bookman = require "bookman"
local junk = require "lulib._junk"
local wit = require "wit"

local M = {}

M.FIELDS = { "title", "authors", "tags", "series", "publisher", "pubdate", "languages" }

--- How much a record says about its book.
function M.score(id)
  local s = 0
  local b = bookman.get(id)
  if (bookman.get(id, "authors") or "") ~= "" then s = s + 3 end
  local t = bookman.get(id, "title") or ""
  if not junk.unlikely_title(t) then s = s + 2 end
  if t ~= t:upper() then s = s + 1 end
  if (bookman.get(id, "tags") or "") ~= "" then s = s + 1 end
  if b and next(b.idents or {}) then s = s + 1 end
  for _, field in ipairs { "pubdate", "publisher", "series" } do
    if (bookman.get(id, field) or "") ~= "" then s = s + 1 end
  end
  return s
end

--- Readies the groups (:dupes's): `books` by score, `keep` the first.
function M.groups(found)
  local out = {}
  for _, g in ipairs(found) do
    local seen, books = {}, {}
    for _, f in ipairs(g.files) do
      if not seen[f.book] then
        seen[f.book] = true
        books[#books + 1] = { id = f.book, score = M.score(f.book), path = f.path }
      end
    end
    if #books > 1 then
      table.sort(books, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        return a.id < b.id
      end)
      out[#out + 1] = { md5 = g.md5, size = g.size, books = books, keep = books[1].id }
    end
  end
  return out
end

--- The books removed if each group kept its chosen copy.
function M.surplus(groups)
  local ids = {}
  for _, g in ipairs(groups) do
    if not g.skip then
      for _, b in ipairs(g.books) do
        if b.id ~= g.keep then ids[#ids + 1] = b.id end
      end
    end
  end
  return ids
end

local function identifiers(id)
  local out = {}
  for kind, value in pairs((bookman.get(id) or {}).idents or {}) do out[kind] = value end
  return out
end

local function tags_of(id)
  local out = {}
  for tag in ((bookman.get(id, "tags") or "") .. ","):gmatch("%s*(.-)%s*,") do
    if tag ~= "" then out[tag] = true end
  end
  return out
end

--- Proposes what a copy says that another doesn't, in the current review:
-- fields the other has empty (or all that differ with `all`), tags and identifiers
-- it hasn't. How many.
-- @tparam integer from
-- @tparam integer to
-- @tparam[opt] table o `{ all = true }`
function M.pull(from, to, o)
  local n, source = 0, ("book %d"):format(from)
  for _, field in ipairs(M.FIELDS) do
    if field ~= "tags" then
      local theirs, mine = bookman.get(from, field) or "", bookman.get(to, field) or ""
      if theirs ~= "" and theirs ~= mine and (mine == "" or (o and o.all)) then
        wit.add(to, { field = field, value = theirs, source = source })
        n = n + 1
      end
    end
  end
  local have = tags_of(to)
  for tag in pairs(tags_of(from)) do
    if not have[tag] then
      wit.add(to, { field = "tags", value = tag, source = source, op = "add" })
      n = n + 1
    end
  end
  local mine = identifiers(to)
  for kind, value in pairs(identifiers(from)) do
    if not mine[kind] then
      wit.add(to, { field = "identifier:" .. kind, value = value, source = source, op = "add" })
      n = n + 1
    end
  end
  return n
end

scrnman.create("dupes", {
  actions = {
    { "keep", "<Space>", "keep the copy under the cursor instead" },
    { "skip", "s", "leave this group alone: nothing in it is removed" },
    { "take", "t", "propose this copy's values for the copy being kept" },
    { "edit", "e", "open the edit form for the book under the cursor" },
    { "review", "r", "the review, for the book under the cursor" },
    { "mark", "m", "mark the surplus copies in the list" },
    { "filter", "f", "narrow the list to books that have a duplicate" },
    { "remove", "D", "remove the surplus copies (to calibre's recycle bin)" },
  },
  hint = { "keep", "skip", "take", "remove" },
  views = { about = { kind = "band", size = 0.35 } },
})

local function human(bytes)
  if bytes >= 2 ^ 30 then return ("%.1f GB"):format(bytes / 2 ^ 30) end
  if bytes >= 2 ^ 20 then return ("%.1f MB"):format(bytes / 2 ^ 20) end
  return ("%.0f kB"):format(bytes / 1024)
end
M.human = human

--- Opens the screen on the groups (:dupes's), and returns when it closes.
function M.open(found)
  local groups = M.groups(found)
  if #groups == 0 then return uiman.notify("no two books hold the same file") end
  local at
  local function build()
    local rows = {}
    at = {}
    for _, g in ipairs(groups) do
      rows[#rows + 1] = { ("%d copies   %s each   md5 %s%s"):format(#g.books, human(g.size), g.md5,
        g.skip and "   skipped: nothing in this group will be removed" or ""), id = g.keep, style = "head" }
      at[#rows] = { g }
      for _, b in ipairs(g.books) do
        local keep = b.id == g.keep
        rows[#rows + 1] = { g.skip and "" or (keep and "✓" or "×"), tostring(b.id), bookman.get(b.id, "title") or "",
          bookman.get(b.id, "authors") or "", bookman.get(b.id, "tags") or "", bookman.get(b.id, "pubdate") or "",
          id = b.id, style = g.skip and "dim" or (keep and "ok" or nil) }
        at[#rows] = { g, b }
      end
    end
    return rows
  end
  local function title()
    local n, bytes = 0, 0
    for _, g in ipairs(groups) do
      if not g.skip then
        n = n + #g.books - 1
        bytes = bytes + g.size * (#g.books - 1)
      end
    end
    return ("duplicates  %d groups, %d surplus books, %s"):format(#groups, n, human(bytes))
  end
  local p <close> = uiman.panel {
    title = title(), screen = "dupes", follow = true, moves = true, reloads = true,
    columns = { { "", 1 }, { "Id", 9 }, { "Title", -4 }, { "Authors", -2 }, { "Subject", -2 }, { "Date", 10 } },
    rows = build(),
  }
  p:cursor(2)
  -- the group's copies, field by field
  local function about(r)
    local g, b = at[r] and at[r][1], at[r] and at[r][2]
    if not g then return {} end
    local copies, out = {}, {}
    for i = 1, math.min(3, #g.books) do copies[i] = g.books[i] end
    local head = { "copy", style = "ok" }
    for i, c in ipairs(copies) do
      head[i + 1] = ("%s%d%s"):format(c.id == g.keep and "✓ " or "", c.id, b and c.id == b.id and "  ←" or "")
    end
    out[1] = head
    for _, field in ipairs(M.FIELDS) do
      local row, first, same = { field }, nil, true
      for i, c in ipairs(copies) do
        local v = bookman.get(c.id, field) or ""
        row[i + 1] = v
        if i == 1 then first = v elseif v ~= first then same = false end
      end
      row.style = same and "dim" or "warn"
      out[#out + 1] = row
    end
    return out
  end
  local band <close> = uiman.panel {
    title = "the group's copies, field by field", screen = "dupes", view = "about", focus = false,
    columns = { { "", 12 }, { "", -1 }, { "", -1 }, { "", -1 } }, rows = about(2),
  }
  local function refresh()
    for i = #groups, 1, -1 do
      local g = groups[i]
      for k = #g.books, 1, -1 do
        if not bookman.get(g.books[k].id) then table.remove(g.books, k) end
      end
      local kept = false
      for _, b in ipairs(g.books) do kept = kept or b.id == g.keep end
      if #g.books < 2 then table.remove(groups, i)
      elseif not kept then g.keep = g.books[1].id end
    end
  end
  while true do
    local act, row = p:wait()
    if not act then return end
    local g, b = at[row] and at[row][1], at[row] and at[row][2]
    local id = b and b.id or g and g.keep
    if act == "<Move>" then
      band:rows(about(row))
    else
      if act == "<Reload>" then
        refresh()
      elseif g and act == "take" then
        if not b or b.id == g.keep then
          uiman.notify("this is the copy being kept: put the cursor on the copy to take from")
        else
          local n = M.pull(b.id, g.keep, { all = true })
          uiman.notify(n == 0 and ("book %d says nothing that book %d does not"):format(b.id, g.keep)
                       or ("%d proposal%s for book %d: :review shows them"):format(n, n == 1 and "" or "s", g.keep))
        end
      elseif id and act == "edit" then
        uiman.jump(id)
        uiman.exec("edit")
        refresh()
      elseif id and act == "review" then
        require("lulib._review").open { id }
        refresh()
      elseif g and b and act == "keep" then
        g.keep, g.skip = b.id, nil
      elseif g and act == "skip" then
        g.skip = not g.skip or nil
      elseif act == "mark" then
        local ids = M.surplus(groups)
        for _, one in ipairs(ids) do uiman.mark(one, true) end
        uiman.notify(("marked %d surplus books; they are now the selection"):format(#ids))
      elseif act == "filter" then
        uiman.filter("is:dupe")
      elseif act == "remove" then
        local ids = M.surplus(groups)
        if #ids == 0 then
          uiman.notify("nothing to remove")
        else
          local answer = uiman.input { prompt = ("remove %d surplus book%s from calibre? they go to its recycle bin (y/N) "):format(#ids, #ids == 1 and "" or "s") }
          if answer and answer:lower():sub(1, 1) == "y" then
            local carried = 0
            for _, one in ipairs(groups) do
              if not one.skip then
                for _, copy in ipairs(one.books) do
                  if copy.id ~= one.keep then carried = carried + M.pull(copy.id, one.keep) end
                end
              end
            end
            local b, err = require("store").remove(ids, "duplicates")
            local msg = ("removed %d duplicate book%s"):format(#ids, #ids == 1 and "" or "s")
            if carried > 0 then msg = msg .. ("; %d value%s only they had proposed for the copies kept: :review"):format(carried, carried == 1 and "" or "s") end
            uiman.notify(b and msg or err, not b and "error" or nil)
            return
          end
        end
      end
      if #groups == 0 then return uiman.notify("no duplicates are left") end
      p:rows(build())
      p:title(title())
      band:rows(about(row))
    end
  end
end

return M
