-- Example grammar: chapters of the Stacks project
-- (stacks.math.columbia.edu). A chapter opens with its name in capitals,
-- then its tag (four figures and capitals, "01H8"), "Contents", or its
-- copyright line. A chapter gets "The Stacks Project" as its author and as
-- lulibre's own field #partof; when a book in the library holds the table
-- "Chapters in reading order" (| # | Chapter | Pages | PDF |), its number
-- in #part.
--
-- To use it, copy this file to ~/.config/lulibre/lua/ and add
-- require "stacks-project" to init.lua.
local expr, exprman, bookman = require "expr", require "exprman", require "bookman"
local sql, sqlite3 = require "sql", require "lsqlite3"
local C, Cmt, Carg, R, S = expr.C, expr.Cmt, expr.Carg, expr.R, expr.S

-- a line with no lower case
local caps = (1 - R "az" - S "\n\f") ^ 1

local title_case = require("lulib._titlecase").apply

-- the line after the name: the tag, "Contents", or the copyright
local second = Cmt(C(expr.line), function(_, pos, l)
  if (l:match("^%w%w%w%w$") and l:find("%d")) or l == "Contents" or l:match("^Copyright %(C%) %d+") then return pos end
  return false
end)

-- chapter name -> its number, from the table in the index; read once
local order
local function reading_order()
  if order ~= nil then return order end
  order = false
  local db = sql.open(setman.get("path.indexdb"), sqlite3.OPEN_READONLY)
  local row = sql.run(db, "SELECT file FROM lines WHERE text LIKE '%Chapters in reading order%' LIMIT 1")[1]
  if row then
    local text = {}
    for _, p in ipairs(sql.run(db, "SELECT text FROM pages WHERE file = ? ORDER BY page", row.file)) do
      text[#text + 1] = p.text
    end
    local found = {}
    for num, stem in table.concat(text, "\n"):gmatch("|%s*(%d+)%s*|%s*([%w%-_]+)%s*|") do
      found[stem:lower()] = tonumber(num)
    end
    if next(found) then order = found end
  end
  db:close()
  return order
end

-- the chapter's number: by calibre's title (the file's name, when it came
-- from it), else by the name's first word
local function part(book, name)
  local o = reading_order()
  if not o then return nil end
  local keys = { expr.fold(bookman.get(book, "title") or ""):gsub("[^%w]+", ""), expr.fold(name):match("^(%w+)") }
  for _, k in ipairs(keys) do
    if k and o[k] then return { value = tostring(o[k]) } end
  end
end

exprman.add("stacks-project", expr.Ct(exprman.field("title", caps / title_case) * expr.eol * second) * Carg(2)
  / function(fields, book)
    fields.authors = { value = "The Stacks Project" }
    fields["#partof"] = { value = "The Stacks Project" }
    fields["#part"] = book and part(book, fields.title.value) or nil
    return fields
  end) -- no group: most chapters never print the project's name in their first pages
