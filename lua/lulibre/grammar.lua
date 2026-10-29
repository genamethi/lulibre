--- Grammars: patterns (expr) over a book's text (txt; design 11, 14, 15).
--
-- A grammar's pattern matches the text from its start and captures a
-- table of fields, each made by `field`: the value with its start and end
-- position, so the lines follow. A grammar gives no confidence: ranking
-- does (lulibre.rank). The predicates below test the line at the current
-- position (expr.where).
--
--     local expr = require "expr"
--     local grammar = require "lulibre.grammar"
--     grammar.add("my-publisher", expr.Ct(
--       expr.upto(grammar.bold) * grammar.field("title", expr.line) * expr.eol
--       * grammar.field("authors", expr.line)), "My Publisher")
--
-- @library lulibre.grammar
local lpeg = require "lpeg"
local stringx = require "pl.stringx"
local expr = require "expr"

local M = {}

local C, Cg, Ct, Cp = lpeg.C, lpeg.Cg, lpeg.Ct, lpeg.Cp
local where = expr.where

--- Succeeds where the line at the position is the largest on its page.
M.largest = where(function(line, t) return line.size == t:largest(line.page) end)
--- Succeeds where the line at the position is bold.
M.bold = where(function(line) return line.bold end)
--- Succeeds where the line at the position starts a paragraph.
M.block = where(function(line) return line.block end)
--- Succeeds where the line at the position is on the page given.
function M.page(n)
  return where(function(line) return line.page == n end)
end
--- Succeeds where the line at the position lies in the top share of its page.
-- @tparam number share 0 to 1
function M.near_top(share)
  return where(function(line, t) return line.y0 <= share * t:height(line.page) end)
end

--- A field: patt's match is the value, `{ value=, start=, stop= }` under
-- the field's name in the parse; start and stop as string.sub takes them.
-- @tparam string name title, authors, publisher, series, year, tags, or an
-- identifier's type
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
