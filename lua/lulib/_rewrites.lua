--- Rewrites: a function from a field's value to a value, proposed under its
-- name in the current review, and written like any other proposal. Each is
-- a table here plus a function, and `run` is the one loop.
--
--     local rewrites = require "lulib._rewrites"
--     rewrites.list.shout = { field = "title", value = function(title) return title:upper() end }
--     rewrites.run("shout", ids)
--
-- A value function gets the field's value, the book and run's options, and
-- returns the new value, or nil to leave the book out.
--
-- @library lulib._rewrites
local bookman = require "bookman"
local names = require "lulib._names"
local notation = require "lulib._notation"
local taxonomy = require "lulib._taxonomy"
local titlecase = require "lulib._titlecase"
local titlepage = require "lulib._titlepage"
local txt = require "txt"
local expr = require "expr"
local wit = require "wit"

local M = {}

-- a title's letters, for telling whether a page has the same one
local function letters(s)
  return (expr.fold(s or ""):gsub("[^%w]", ""))
end

-- a title as its book's first page sets it, marked up, if that's this title
local function title_as_set(book, title)
  local t <close> = txt.of(book)
  if not t then return nil end
  local lines, pages = {}, {}
  for i = 1, #t do
    local l = t:line(i)
    if l.page > 2 then break end
    lines[l.page] = lines[l.page] or {}
    table.insert(lines[l.page], l)
  end
  for n = 1, 2 do pages[n] = lines[n] or {} end
  local tp = titlepage.classify_pages(pages)
  if tp.title_math and letters(tp.title) == letters(title) then return tp.title_math end
end

--- The rewrites, by name.
M.list = {
  titlecase = {
    field = "title",
    value = function(title, _, o)
      if o.all or titlecase.is_caps(title) then return titlecase.apply(title) end
    end,
  },
  notation = {
    field = "title",
    value = function(title, book)
      local marked = title_as_set(book, title)
      return marked and notation.title(marked, titlecase.proposed) or notation.title(title)
    end,
  },
  ["split-authors"] = {
    field = "authors",
    value = function(authors)
      local had, people = 0, {}
      for author in (authors .. " & "):gmatch("(.-) & ") do
        had = had + 1
        for _, person in ipairs(names.split(author)) do people[#people + 1] = names.titlecase(person) end
      end
      if #people > had then return table.concat(people, " & ") end
    end,
  },
  ["normalize-tags"] = {
    field = "tags",
    value = function(tags)
      local out, seen = {}, {}
      for tag in (tags .. ","):gmatch("%s*(.-)%s*,") do
        local name = taxonomy.alias[tag] or tag
        if name ~= "" and not seen[name] then
          seen[name] = true
          out[#out + 1] = name
        end
      end
      return table.concat(out, ", ")
    end,
  },
}

--- Runs a rewrite over the books: a proposal for each book whose value it
-- changes. Returns how many.
-- @tparam string name
-- @tparam {integer,...} ids
-- @tparam[opt] table o passed to the value function
function M.run(name, ids, o)
  local rw, n = M.list[name], 0
  o = o or {}
  for _, book in ipairs(ids) do
    local field = rw.field
    local value = wit.now(book, field) or ""
    if value ~= "" then
      local to = rw.value(value, book, o)
      if to and to ~= value then
        wit.add(book, { field = field, value = to, source = name })
        n = n + 1
      end
    end
  end
  return n
end

--- The letters and names of the fields :clear takes.
M.field_names = { t = "title", title = "title", a = "authors", author = "authors", authors = "authors",
                  s = "tags", subject = "tags", tag = "tags", tags = "tags",
                  i = "identifiers", id = "identifiers", ids = "identifiers", identifiers = "identifiers",
                  d = "pubdate", date = "pubdate", pubdate = "pubdate", p = "publisher", publisher = "publisher",
                  e = "series", series = "series" }

--- Proposes blanking fields in the books: a proposal for each that has a
-- value. Returns how many, or nil and why.
-- @tparam string list the fields, "title,authors" or "t,a"
-- @tparam {integer,...} ids
function M.clear(list, ids)
  local fields = {}
  for word in (list or ""):gmatch("[^,%s]+") do
    local field = M.field_names[word:lower()]
    if not field then return nil, ("no field %s: title authors tags identifiers pubdate publisher series, or t a s i d p e"):format(word) end
    fields[#fields + 1] = field
  end
  if #fields == 0 then return nil, "clear which fields? title authors tags identifiers pubdate publisher series, or t a s i d p e" end
  local n = 0
  for _, book in ipairs(ids) do
    for _, field in ipairs(fields) do
      if (bookman.get(book, field) or "") ~= "" then
        wit.add(book, { field = field, value = "", source = "clear" })
        n = n + 1
      end
    end
  end
  return n
end

return M
