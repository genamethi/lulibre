--- Grammars: LPeg patterns over a reading's text (design 11, 14, 15).
--
-- A grammar's pattern matches the reading's text from its start and
-- captures a table of fields, each made by `field`: the value with its
-- start and end position, so the lines follow. A grammar gives no
-- confidence: ranking does (lulibre.rank).
--
-- The predicates test the line at the current position. lpeg.match gets
-- the reading as its extra argument, and each predicate reads the reading
-- with lpeg.Carg(1), so a predicate holds no state of its own.
--
--     local grammar = require "lulibre.grammar"
--     local P, line, eol = grammar.P, grammar.line, grammar.eol
--     grammar.add("my-publisher", lpeg.Ct(
--       grammar.skip_to(grammar.bold) * grammar.field("title", line) * eol
--       * grammar.field("authors", line)), "My Publisher")
--
-- @library lulibre.grammar
local lpeg = require "lpeg"

local M = {}

local P, S, C, Cg, Ct, Cp, Cmt, Carg = lpeg.P, lpeg.S, lpeg.C, lpeg.Cg, lpeg.Ct, lpeg.Cp, lpeg.Cmt, lpeg.Carg

M.P = P
--- A line's text: up to its line or page break.
M.line = (1 - S "\n\f") ^ 1
--- The breaks after a line: one, or two before a paragraph.
M.eol = P "\n" ^ 1
--- A line with the breaks after it.
M.any_line = M.line * M.eol ^ -1

local function at(test)
  return Cmt(Carg(1), function(_, pos, reading)
    local line = reading:line_at(pos)
    return line ~= nil and test(line, reading) and pos
  end)
end
M.at = at

--- Succeeds where the line at the position is the largest on its page.
M.largest = at(function(line, reading) return line.size == reading:largest(line.page) end)
--- Succeeds where the line at the position is bold.
M.bold = at(function(line) return line.bold end)
--- Succeeds where the line at the position starts a paragraph.
M.block = at(function(line) return line.block end)
--- Succeeds where the line at the position is on the page given.
function M.page(n)
  return at(function(line) return line.page == n end)
end
--- Succeeds where the line at the position lies in the top share of its page.
-- @tparam number share 0 to 1
function M.near_top(share)
  return at(function(line, reading) return line.y0 <= share * reading:height(line.page) end)
end

--- Whole lines up to the first line where test holds at its start; test is
-- a predicate (it consumes nothing). Fails at a page break.
function M.skip_to(test)
  return (M.any_line - #test) ^ 0 * #test
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
  return (value:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
end

--- Returns the parse of each grammar that matches the reading.
-- @param reading a reading (lulibre.reading), held by the caller
-- @treturn {table,...} each `{ grammar=, fields = { [field] = {value=,
-- start=, stop=} } }`, by grammar name
function M.parse(reading)
  local parses, text = {}, reading.text
  local names = {}
  for name in pairs(M.grammars) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    local fields = lpeg.match(M.grammars[name].pattern, text, 1, reading)
    if type(fields) == "table" and next(fields) then
      for _, f in pairs(fields) do f.value = M.clean(f.value) end
      parses[#parses + 1] = { grammar = name, fields = fields }
    end
  end
  return parses
end

return M
