-- The library held against its own files (lulibre.verify): for each book,
-- whether the opening pages show its title and its authors, and where each
-- DOI, ISBN and arXiv number it holds stands in the file.
--   :verify [filter]                   counts, and the books that look wrong
--   :verify --list title|authors|ids|unread [filter]   every book of one kind
--   lulibre verify ...
-- Changes nothing.
local verify = require "lulibre.verify"

local list, words = nil, {}
local args = { ... }
local i = 1
while i <= #args do
  local a = args[i]
  if a == "--list" then
    list = args[i + 1]
    if not ({ title = 1, authors = 1, ids = 1, unread = 1 })[list or ""] then
      error("--list takes title, authors, ids or unread", 0)
    end
    i = i + 1
  else
    words[#words + 1] = a
  end
  i = i + 1
end
local filter = table.concat(words, " ")

local n = { books = 0, unread = 0 }
local title, authors, where = {}, {}, {}
local bad = { title = {}, authors = {}, ids = {}, unread = {} }
local ids = lulibre.ids(filter)
for k, id in ipairs(ids) do
  if k % 100 == 0 then lulibre.progress(("checking %d/%d"):format(k, #ids)) end
  local v = verify.book(id)
  if v then
    n.books = n.books + 1
    if v.unread then
      n.unread = n.unread + 1
      table.insert(bad.unread, ("%6d  %-60s %s"):format(id, (v.title.value or ""):sub(1, 60), v.unread))
    else
      title[v.title.verdict] = (title[v.title.verdict] or 0) + 1
      authors[v.authors.verdict] = (authors[v.authors.verdict] or 0) + 1
      if v.title.verdict == "absent" then
        table.insert(bad.title, ("%6d  %-60s authors %s"):format(id, (v.title.value or ""):sub(1, 60), v.authors.verdict))
      end
      if v.authors.verdict == "absent" or v.authors.verdict == "partly" then
        table.insert(bad.authors, ("%6d  %-60s %s (%d of %d)"):format(id, (v.authors.value or ""):sub(1, 60), v.authors.verdict,
          v.authors.shown, v.authors.named))
      end
      for _, it in ipairs(v.idents) do
        where[it.where] = (where[it.where] or 0) + 1
        if it.where == "cited" or it.where == "absent" then
          table.insert(bad.ids, ("%6d  %-40s %-8s %s"):format(id, it.ident:sub(1, 40), it.where, (lulibre.book(id).title or ""):sub(1, 40)))
        end
      end
    end
  end
end
lulibre.progress(nil)

local out = {}
local function line(...) out[#out + 1] = string.format(...) end
if list then
  for _, l in ipairs(bad[list]) do out[#out + 1] = l end
  if #out == 0 then line("none") end
else
  local function counts(t, order)
    local parts = {}
    for _, k in ipairs(order) do
      if t[k] then parts[#parts + 1] = ("%d %s"):format(t[k], k) end
    end
    return table.concat(parts, ", ")
  end
  line("%d books; the files of %d could not be read, so nothing is known of them", n.books, n.unread)
  line("  title on its opening pages: %s", counts(title, { "shown", "partly", "absent", "unknown" }))
  line("  authors named there:        %s", counts(authors, { "shown", "partly", "absent", "unknown" }))
  line("  identifiers:                %s", counts(where, { "own", "front", "inside", "cited", "absent", "unknown" }))
  line("    (own: stands as the file's own; front/inside: in the opening pages / further in;")
  line("     cited: only in its reference list; absent: nowhere in what the index holds)")
  for _, kind in ipairs { "title", "authors", "ids" } do
    if #bad[kind] > 0 then
      line("")
      line("%s (%d; --list %s for all):", kind == "title" and "titles the pages do not show" or kind == "authors"
        and "authors the pages do not (all) name" or "identifiers that are cited or absent", #bad[kind], kind)
      for j = 1, math.min(12, #bad[kind]) do out[#out + 1] = bad[kind][j] end
    end
  end
end
if lulibre.headless then print(table.concat(out, "\n"))
else lulibre.show(out, "the library held against its files") end
