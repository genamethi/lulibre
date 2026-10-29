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

--- A field: patt's match is the value, `{ value=, start=, stop= }` under
-- the field's name in the parse; start and stop as string.sub takes them.
-- @tparam string name a field as calibre names it: title, authors,
-- publisher, series, pubdate, tags, or identifier:TYPE (identifier:isbn)
-- @param patt an LPeg pattern
function M.field(name, patt)
  local value = Ct(Cg(Cp(), "start") * Cg(C(patt), "value") * Cg(Cp() / function(p) return p - 1 end, "stop"))
  return Cg(value, name)
end

--- The grammars, by name: `{ pattern=, group= }`.
M.grammars = {}

--- Adds a grammar, or replaces the one of that name.
-- @tparam string name
-- @param pattern an LPeg pattern capturing a table of fields (`field`)
-- @tparam[opt] string group what the grammar was written for: an author, a
-- publisher, a series
function M.add(name, pattern, group)
  M.grammars[name] = { pattern = pattern, group = group }
end

--- Removes a grammar.
function M.remove(name)
  M.grammars[name] = nil
end

--- A captured value as a field's value: its lines joined by spaces.
function M.clean(value)
  return stringx.strip((value:gsub("%s+", " ")))
end

--- Returns the parse of each grammar that matches the text.
-- @param t a text (txt), held by the caller
-- @treturn {table,...} each `{ grammar=, fields = { [field] = {value=,
-- start=, stop=} } }`, by grammar name
function M.parse(t)
  local parses, text = {}, t.text
  local names = {}
  for name in pairs(M.grammars) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    local fields = lpeg.match(M.grammars[name].pattern, text, 1, t)
    if type(fields) == "table" and next(fields) then
      for _, f in pairs(fields) do f.value = M.clean(f.value) end
      parses[#parses + 1] = { grammar = name, fields = fields }
    end
  end
  return parses
end

return M
