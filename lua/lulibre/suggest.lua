-- Ranked values for a field: what the file itself suggests, what related
-- books have, then what the library already uses, most used first.
local edit = require "lulibre.edit"
local extract = require "lulibre.extract"

local M = {}

local function words_prefix(title)
  -- "titile -cfthistory", "Schaum's Outline of ..." : the first two words
  local a, b = (title or ""):match("^(%S+)%s+(%S+)")
  if a and #a + #b >= 6 then return a .. " " .. b end
end

--- Books that plausibly belong with this one: same leading words in the
-- title, or sharing an author.
function M.related(book)
  local seen, out = { [book.id] = true }, {}
  local function take(filter)
    local ok, ids = pcall(lulibre.ids, filter)
    if not ok then return end
    for _, id in ipairs(ids) do
      if not seen[id] and #out < 200 then
        seen[id] = true
        out[#out + 1] = id
      end
    end
  end
  local prefix = words_prefix(book.title)
  if prefix then take(('title:^"%s"'):format(prefix:gsub('"', '\\"'))) end
  if not edit.is_unknown(book.author) then
    for _, a in ipairs(book.authors) do take(('author:="%s"'):format(a:gsub('"', '\\"'))) end
  end
  return out
end

--- { {text=, detail=, kind=}, ... } for one field of the given books. kind
-- is "candidate" (from the file), "related", or "library".
function M.for_field(field, ids)
  local out, seen = {}, {}
  local function add(text, detail, kind)
    if not text or text == "" then return end
    local k = lulibre.fold(text)
    if seen[k] then return end
    seen[k] = true
    out[#out + 1] = { text = text, detail = detail, kind = kind }
  end

  -- from the files (only worth the time for a handful of books)
  for i = 1, math.min(#ids, 8) do
    for _, c in ipairs(extract.candidates(ids[i])) do
      if c.field == field then add(c.value, ("%s %.2f"):format(c.source, c.confidence), "candidate") end
    end
  end

  -- what related books have, most common first
  if field == "authors" or field == "tags" or field == "publisher" or field == "series" then
    local counts, order = {}, {}
    for i = 1, math.min(#ids, 4) do
      local book = lulibre.book(ids[i])
      if book then
        for _, rid in ipairs(M.related(book)) do
          local rb = lulibre.book(rid)
          local v = rb and edit.current(rb, field) or ""
          if v ~= "" then
            if not counts[v] then order[#order + 1] = v end
            counts[v] = (counts[v] or 0) + 1
          end
        end
      end
    end
    table.sort(order, function(a, b)
      if counts[a] ~= counts[b] then return counts[a] > counts[b] end
      return a < b
    end)
    for i = 1, math.min(#order, 6) do
      add(order[i], ("in %d related book%s"):format(counts[order[i]], counts[order[i]] == 1 and "" or "s"), "related")
    end
  end

  -- what the library already uses
  if field == "authors" then
    for _, a in ipairs(lulibre.authors()) do
      -- entries that are really lists of people are a defect, not a suggestion
      if not edit.is_unknown(a.name) and not a.name:find("[;]") then
        add(a.name, tostring(a.books), "library")
      end
    end
  elseif field == "tags" then
    for _, t in ipairs(lulibre.tags()) do add(t.name, tostring(t.books), "library") end
  elseif field == "publisher" or field == "series" then
    local rows = lulibre.sql(("SELECT %s AS v, count(*) AS n FROM books WHERE id > 0 AND %s IS NOT NULL GROUP BY 1 ORDER BY n DESC")
      :format(field, field))
    for _, r in ipairs(rows) do add(r.v, tostring(r.n), "library") end
  end
  return out
end

return M
