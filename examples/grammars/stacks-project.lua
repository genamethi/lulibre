-- Example grammar: chapters of the Stacks project (stacks.math.columbia.edu).
-- A chapter's name is in capitals, followed by its tag ("01H8") or its
-- contents. Matching chapters get "The Stacks Project" as author and as the
-- whole they belong to, and are marked as having no catalogue record. If a
-- book in the library contains the table "Chapters in reading order"
-- (| # | Chapter | Pages | PDF |), each chapter also gets its number.
--
-- To use it, copy this file to ~/.config/lulibre/lua/grammars/ and add
-- require "grammars.stacks-project" to init.lua.
local G = require "exprman._front"

-- The Stacks project: each chapter opens with its name in capitals and then
-- its tag (four characters, 01H8) or its contents. The reading order is in
-- the project's Makefile; a book whose text holds that table ("Chapters in
-- reading order", | # | Chapter | Pages | PDF |) gives each chapter its number.
local stacks_order -- stem -> { n=, pages= }, and the count; read once
local function read_stacks_order()
  if stacks_order ~= nil then return stacks_order end
  stacks_order = false
  local row = lulibre.sql([[SELECT p.text FROM pages p JOIN files f ON f.id = p.file
    WHERE p.text LIKE '%Chapters in reading order%' LIMIT 1]])[1]
  if not row then return false end
  local fid = lulibre.sql([[SELECT p.file FROM pages p WHERE p.text LIKE '%Chapters in reading order%' LIMIT 1]])[1].file
  local text = {}
  for _, r in ipairs(lulibre.sql("SELECT text FROM pages WHERE file = ? ORDER BY page", fid)) do text[#text + 1] = r.text end
  local order, n = {}, 0
  for num, stem, pages in table.concat(text, "\n"):gmatch("|%s*(%d+)%s*|%s*([%w%-_]+)%s*|%s*(%d+)%s*|") do
    order[stem:lower()] = { n = tonumber(num), pages = tonumber(pages) }
    n = math.max(n, tonumber(num))
  end
  if n == 0 then return false end
  stacks_order = { order = order, count = n }
  return stacks_order
end

G.add {
  name = "stacks-project",
  kind = "chapter of the Stacks project",
  noncatalog = true,
  lines = {
    G.line { upper = true, take = "title", case = "title" },
    G.either {
      G.line { pattern = "^%w%w%w%w$" },  -- its tag
      G.line { pattern = "^Contents$" },
      G.line { pattern = "^Copyright %(C%) %d+ %-%- %d+ Johan de Jong" },
    },
  },
  read = function(doc, got)
    -- a tag is four characters of figures and capitals, with a figure among them
    local first = doc.lines and doc.lines[2] and doc.lines[2].text or ""
    if first:match("^%w%w%w%w$") and not first:find("%d") then return false end
    local fields = { authors = "The Stacks Project", part_of = "The Stacks Project" }
    local ord = read_stacks_order()
    if ord then
      fields.parts = ord.count
      -- the chapter by its file's name (calibre's title, when it came from it), else by its title's first word, and its length
      local book = lulibre.book(doc.id)
      local keys = { lulibre.fold(book and book.title or ""):gsub("[^%w]+", ""), (lulibre.fold(got.title or ""):match("^(%w+)")) }
      for _, k in ipairs(keys) do
        local hit = k and ord.order[k]
        if hit and (not hit.pages or not doc.pages or math.abs(hit.pages - doc.pages) <= 1) then
          fields.part = hit.n
          break
        end
      end
    end
    return fields
  end,
  confidence = 0.9,
}
