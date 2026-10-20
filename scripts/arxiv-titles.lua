-- Find books' arXiv numbers by their titles in arXiv's own snapshot, kept
-- on this machine (see :datasets), asking nobody. A paper whose title is the
-- book's, word for word, counts only if the book's own pages show its title
-- and name its people (lulibre.verify): then its arXiv number is proposed,
-- and :enrich --offline proposes the rest of what the record says.
--   :run arxiv-titles [filter]    books with no arXiv number (the selection, or a filter)
--   lulibre arxiv-titles ...
-- Books marked non-catalog are looked for too: an arXiv paper is not a
-- catalogue's record. One pass through the file takes a minute or so.
local edit = require "lulibre.edit"
local junk = require "lulibre.junk"
local net = require "lulibre.net"
local proposals = require "lulibre.proposals"
local verify = require "lulibre.verify"

local filter = table.concat({ ... }, " ")
local path = net.arxiv_snapshot_path()
if not path then error("no arXiv snapshot on this machine (:datasets fetches one)", 0) end

local books, wanted, n = {}, {}, 0
for _, id in ipairs(filter ~= "" and lulibre.ids(filter) or lulibre.selection()) do
  local book = lulibre.book(id)
  if book and not book.idents.arxiv and book.title and not junk.unlikely_title(book.title) and #verify.telling(book.title) >= 2 then
    local ev = verify.evidence(id)
    if ev then
      -- the title as the book has it, and its main part (before a colon)
      for _, t in ipairs { book.title, book.title:match("^(.-)%s*:%s") } do
        local key = net.title_key(t)
        if #key >= 12 then
          wanted[key] = true
          books[key] = books[key] or {}
          table.insert(books[key], id)
        end
      end
      n = n + 1
    end
  end
end
if n == 0 then
  print("no books to look for: each has an arXiv number already, or no title to go by, or a file that cannot be read")
  return
end
lulibre.progress(("looking for %d titles in arXiv's snapshot"):format(n))
local found, passed = net.arxiv_by_title(path, wanted, function(t) lulibre.progress("reading arXiv's snapshot: " .. t) end)
lulibre.progress(nil)
if not found then error(passed, 0) end

local proposed, refused, lines = 0, 0, {}
local done = {}
for key, arxiv_ids in pairs(found) do
  for _, book_id in ipairs(books[key] or {}) do
    if not done[book_id] then
      local ev = verify.evidence(book_id)
      for _, aid in ipairs(arxiv_ids) do
        local rec = net.kept_record("arxiv", aid)
        local j = rec and verify.record(ev, rec)
        if j and j.title == "shown" and (j.authors == "shown" or j.authors == "partly") then
          if proposals.add(book_id, "identifiers", "arxiv:" .. aid, { op = "add", confidence = 0.9,
              source = "arXiv's records (by title, on this machine)" }) then
            proposed = proposed + 1
          end
          done[book_id] = true
          lines[#lines + 1] = ("  %-6d arxiv:%-18s %s"):format(book_id, aid, (rec.title or ""):sub(1, 60))
          break
        else
          refused = refused + 1
        end
      end
    end
  end
end
table.sort(lines)
local out = { ("%d books looked for among %.1f million papers: %d found by title and borne out by their pages; %d same-titled papers left (their people are not on the book's pages)")
  :format(n, passed / 1e6, proposed, refused) }
for _, l in ipairs(lines) do out[#out + 1] = l end
if proposed > 0 then
  out[#out + 1] = require("lulibre.proposals").to_review() .. " Then :enrich --offline proposes what the records say."
end
print(table.concat(out, "\n"))
local _ = edit
