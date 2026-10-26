--- Grammars: LPeg patterns over a reading's text (design 11, 14, 15).
--
-- A grammar's pattern matches the reading's text and captures a table of
-- fields; each field's value comes with its start and end position, so the
-- lines follow. A grammar gives no confidence: ranking does (lulibre.rank).
--
-- The predicates test the line at the current position. lpeg.match gets
-- the reading as its extra argument, and each predicate reads the reading
-- with lpeg.Carg(1), so a predicate holds no state of its own.
--
-- @library lulibre.grammar
local lpeg = require "lpeg"

local M = {}

local function at(test)
  return lpeg.Cmt(lpeg.Carg(1), function(_, pos, reading)
    local line = reading:line_at(pos)
    return line ~= nil and test(line, reading) and pos
  end)
end

--- Succeeds where the line at the position is the largest on its page.
M.largest = at(function(line, reading) return line.size == reading:largest(line.page) end)
--- Succeeds where the line at the position is bold.
M.bold = at(function(line) return line.bold end)
--- Succeeds where the line at the position starts a paragraph.
M.block = at(function(line) return line.block end)
--- Succeeds where the line at the position lies in the top share of its page.
-- @tparam number share 0 to 1
function M.near_top(share)
  return at(function(line, reading) return line.y0 <= share * reading:height(line.page) end)
end

--- Adds a grammar.
-- @tparam string name
-- @param pattern an LPeg pattern capturing a table of fields; each field
-- a table `{ value, start, stop }`
-- @tparam[opt] string group what the grammar was written for: an author, a
-- publisher, a series
function M.add(name, pattern, group)
  error("not written yet", 2)
end

--- Returns the parse of each grammar that matches the reading.
-- @param reading a reading (lulibre.reading), held by the caller
-- @treturn {table,...} each `{ grammar=, fields = { [field] = {value=, start=, stop=} } }`
function M.parse(reading)
  error("not written yet", 2)
end

return M
