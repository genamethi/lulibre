-- Go back over what searching CrossRef by title brought in, with the rule
-- that search is held to now (net.title_match). Earlier it took a record
-- when two words in three of a short title agreed, and offered it at 0.95.
--   :run unmatch            look, and say what was found; nothing is changed
--   :run unmatch --fix      for the matches that do not hold:
--                             what still waits from them is withdrawn (and
--                             what was looked up under their DOI or ISBN), and
--                             for what was written, putting back what the
--                             book said before is proposed, for review
--   lulibre run unmatch [--fix]
-- Asks no service anything: it reads the answers kept from the searches.
local edit = require "lulibre.edit"
local json = require "lulibre.json"
local net = require "lulibre.net"
local proposals = require "lulibre.proposals"
local propose = require "lulibre.propose"

local fix = false
for _, a in ipairs({ ... }) do
  if a == "--fix" then fix = true
  else error(("unmatch takes --fix or nothing, not '%s'"):format(a), 0) end
end

-- every record a title search took, by its DOI: the title searched for, the record's title and authors
local taken = {}
for _, row in ipairs(lulibre.store("SELECT key, body FROM lookups WHERE service = 'crossref-title' AND status = 200")) do
  local ok, data = pcall(json.decode, row.body)
  local items = ok and type(data) == "table" and type(data.message) == "table" and data.message.items or {}
  for _, item in ipairs(type(items) == "table" and items or {}) do
    local title = type(item.title) == "table" and item.title[1]
    if type(title) == "string" and type(item.DOI) == "string" and net.same_title(row.key, title) then
      local authors = {}
      for _, a in ipairs(type(item.author) == "table" and item.author or {}) do
        local name = ((a.given or "") .. " " .. (a.family or a.name or "")):gsub("^%s+", ""):gsub("%s+$", "")
        if name ~= "" then authors[#authors + 1] = name end
      end
      local doi = item.DOI:lower()
      taken[doi] = taken[doi] or {}
      table.insert(taken[doi], { searched = row.key, title = title, authors = authors })
      break -- the first that passed was the one taken
    end
  end
end

local SOURCE = "CrossRef title search%"
local books = lulibre.store("SELECT DISTINCT book FROM proposals WHERE source LIKE ? ORDER BY abs(book)", SOURCE)
local run <close> = fix and require("lulibre.runs").join { ids = {}, label = "wrong title matches", steps = { "putting back" } } or nil
local held, wrong, withdrawn, back, lines = 0, 0, 0, 0, {}
for _, b in ipairs(books) do
  local book = lulibre.book(b.book)
  local mine = lulibre.store("SELECT * FROM proposals WHERE book = ? AND source LIKE ? ORDER BY id", b.book, SOURCE)
  local doi
  for _, pr in ipairs(mine) do
    doi = doi or (pr.field == "identifiers" and pr.value:match("^doi:(.+)$"))
  end
  local found = doi and taken[doi:lower()]
  if book and found then
    -- the authors the book had when the search was made: before this record's were written over them
    local was = lulibre.store([[SELECT old FROM journal WHERE book = ? AND field = 'authors' AND status = 'applied'
      AND undone = 0 ORDER BY id]], b.book)
    local who = edit.current(book, "authors")
    for _, pr in ipairs(mine) do
      if pr.field == "authors" and pr.status == "applied" and was[1] then who = was[#was].old or who end
    end
    local authors = propose.is_gap("authors", who, b.book) and {} or edit.split("authors", who)
    local holds
    for _, t in ipairs(found) do
      holds = holds or net.title_match(t.searched, t.title, authors, t.authors)
    end
    if holds then
      held = held + 1
    else
      wrong = wrong + 1
      -- what was then looked up under the wrong record's DOI or ISBN came from the same mistake
      local theirs = {}
      for _, pr in ipairs(mine) do
        local number = pr.field == "identifiers" and pr.value:match("^[%w_%-]+:(.+)$")
        if number then theirs[#theirs + 1] = number:lower() end
      end
      for _, pr in ipairs(lulibre.store("SELECT * FROM proposals WHERE book = ? AND source NOT LIKE ? ORDER BY id", b.book, SOURCE)) do
        for _, number in ipairs(theirs) do
          if (pr.source or ""):lower():find(number, 1, true) then
            mine[#mine + 1] = pr
            break
          end
        end
      end
      local waiting, written = 0, {}
      for _, pr in ipairs(mine) do
        if pr.status == "pending" or pr.status == "accepted" then
          waiting = waiting + 1
          if fix then lulibre.store("DELETE FROM proposals WHERE id = ?", pr.id) end
        elseif pr.status == "applied" then
          -- what the journal says the field held before this value went in, if the value is still there
          local now = edit.current(book, pr.field)
          for _, j in ipairs(lulibre.store([[SELECT old, new FROM journal WHERE book = ? AND field = ? AND status = 'applied'
              AND undone = 0 AND label = 'review' ORDER BY id DESC]], b.book, pr.field)) do
            local theirs = pr.field == "identifiers" and (j.new or ""):lower():find(pr.value:lower(), 1, true) ~= nil
              and not (j.old or ""):lower():find(pr.value:lower(), 1, true)
              or pr.field ~= "identifiers" and (j.new == pr.value or (pr.field == "pubdate" and (j.new or ""):sub(1, #pr.value) == pr.value))
            if theirs then
              if pr.field == "identifiers" then
                if now:lower():find(pr.value:lower(), 1, true) then written[#written + 1] = { field = pr.field, op = "remove", value = pr.value } end
              elseif now == j.new or (pr.field == "pubdate" and now:sub(1, #pr.value) == pr.value) then
                written[#written + 1] = { field = pr.field, op = "set", value = j.old or "" }
              end
              break
            end
          end
        end
      end
      withdrawn = withdrawn + waiting
      if fix then
        for _, w in ipairs(written) do
          if proposals.add(b.book, w.field, w.value, { op = w.op, source = "before a wrong title match", confidence = 0.9, again = true, as_is = true }) then
            back = back + 1
          end
        end
        if #written > 0 then table.insert(run.run.ids, b.book) end
      else
        back = back + #written
      end
      lines[#lines + 1] = ("  %-5d %s\n        was searched as: %s\n        took the record: %s%s"):format(b.book, book.title or "", found[1].searched,
        found[1].title, (waiting > 0 or #written > 0) and ("\n        %d waiting, %d written"):format(waiting, #written) or "")
    end
  end
end
if run then
  run.run.books = nil
  run:done()
end

local out = { ("%d book%s got a record from a search by title: %d hold under the rule as it is now, %d do not."):format(held + wrong,
  held + wrong == 1 and "" or "s", held, wrong) }
if wrong > 0 then
  out[#out + 1] = table.concat(lines, "\n")
  if fix then
    out[#out + 1] = ("%d waiting proposal%s withdrawn; putting back what the books said before is proposed for %d field%s.%s"):format(
      withdrawn, withdrawn == 1 and "" or "s", back, back == 1 and "" or "s", require("lulibre.proposals").to_review(" "))
  else
    out[#out + 1] = ("%d proposal%s from them still wait, and %d field%s were written. `unmatch --fix` withdraws the first and proposes putting the second back."):format(
      withdrawn, withdrawn == 1 and "" or "s", back, back == 1 and "" or "s")
  end
end
-- in the interface the list is a page to read, and its last line stays on the message line
if lulibre.headless or wrong == 0 then
  print(table.concat(out, "\n"))
else
  lulibre.show(table.concat(out, "\n"), "records taken by a search for the title")
  lulibre.notify(out[#out])
end
