--- Grammars: patterns (expr) over a book's text (txt; design 11, 14, 15).
--
-- A grammar's pattern matches the text from its start and captures a
-- table of fields, each made by `field`: the value with its start and end
-- position, so the lines follow. A grammar gives no confidence: ranking
-- does (lulib._rank). expr's line predicates (expr.bold, expr.page, ...)
-- say where a field is.
--
--     local expr, exprman = require "expr", require "exprman"
--     exprman.add("my-publisher", expr.Ct(
--       expr.upto(expr.bold) * exprman.field("title", expr.line) * expr.eol
--       * exprman.field("authors", expr.line)), "My Publisher")
--
-- @library exprman
local lpeg = require "lpeg"
local stringx = require "pl.stringx"
local expr = require "expr"

local M = {}

local C, Cg, Ct, Cp = lpeg.C, lpeg.Cg, lpeg.Ct, lpeg.Cp

--- A field: `{ value=, start=, stop= }` under the field's name in the
-- parse, its value what patt captures, or what it matches when it captures
-- nothing (`P"KEITH CONRAD" / "Keith Conrad"` gives the value its own
-- spelling); start and stop as string.sub takes them, around the match.
-- @tparam string name a field as calibre names it: title, authors,
-- publisher, series, pubdate, tags, identifier:TYPE (identifier:isbn), or
-- one of lulibre's own (#partof)
-- @param patt an LPeg pattern
function M.field(name, patt)
  local value = C(patt) / function(whole, captured) return captured or whole end
  return Cg(Ct(Cg(Cp(), "start") * Cg(value, "value") * Cg(Cp() / function(p) return p - 1 end, "stop")), name)
end

--- The grammars, by name: `{ pattern=, group=, version= }`.
M.grammars = {}

--- Adds a grammar, or replaces the one of that name. What it finds in a file
-- is kept (lulib._kept) until the file is read again or `version` changes.
-- @tparam string name
-- @param pattern an LPeg pattern capturing a table of fields (`field`); or a
-- function given the text and the book (`fn(t, book)`), returning fields as
-- values, or as `{ value=, start=, stop=, how=, sure=, also= }`: how, what reading gave
-- it, shown as where it came from; sure, how sure that is, 0 to 1; also, other values
-- for the field in the same form. A value found in the text as it stands takes its
-- place there
-- @tparam[opt] string group what the grammar was written for: an author, a
-- publisher, a series. It runs only for a book that says so: the record, an online
-- record or another grammar has it, or its words are on the pages. What it finds
-- there is surer, by the setting rank_group. Leave it out for a grammar whose pattern
-- is the test, for books that may not name what they belong to
-- @param[opt] version change it when you change the pattern
function M.add(name, pattern, group, version)
  M.grammars[name] = { pattern = pattern, group = group, version = version }
end

--- The grammars' names, in the order they run.
function M.names()
  local names = {}
  for name in pairs(M.grammars) do names[#names + 1] = name end
  table.sort(names)
  return names
end

--- Removes a grammar.
function M.remove(name)
  M.grammars[name] = nil
end

--- A captured value as a field's value: its lines joined by spaces.
function M.clean(value)
  return stringx.strip((value:gsub("%s+", " ")))
end

--- Returns the parse of each grammar that matches the text. A grammar's
-- pattern gets the text and the book as LPeg's extra arguments
-- (`expr.Carg(1)`, `expr.Carg(2)`), so one can read what is not in the text
-- (the book's record) in a match-time capture; a field it makes so takes
-- `{ value= }` and no positions.
-- @param t a text (txt), held by the caller
-- @tparam[opt] integer book the book the text is of
-- @tparam[opt] {string,...} names only these grammars
-- @treturn {table,...} each `{ grammar=, fields = { [field] = {value=,
-- start=, stop=} } }`, by grammar name
function M.parse(t, book, names)
  local parses, text = {}, t.text
  for _, name in ipairs(names or M.names()) do
    local pattern, fields = M.grammars[name].pattern, nil
    if type(pattern) == "function" then
      fields = pattern(t, book)
      for field, f in pairs(fields or {}) do
        if type(f) ~= "table" then
          f = { value = tostring(f) }
          fields[field] = f
        end
        for _, one in ipairs { f, table.unpack(f.also or {}) } do
          if not one.start then one.start, one.stop = text:find(one.value, 1, true) end
        end
      end
    else
      fields = lpeg.match(pattern, text, 1, t, book)
    end
    if type(fields) == "table" and next(fields) then
      for _, f in pairs(fields) do
        f.value = M.clean(f.value)
        for _, other in ipairs(f.also or {}) do other.value = M.clean(other.value) end
      end
      parses[#parses + 1] = { grammar = name, fields = fields }
    end
  end
  return parses
end

return M
