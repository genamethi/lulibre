--- The packaged grammar: a front page's title and authors, from the
-- layout alone. Grammars written for a group of books (an author, a
-- publisher, a series) are added the same way, with lulibre.grammar.add.
--
-- @library lulibre.grammars
local lpeg = require "lpeg"
local grammar = require "lulibre.grammar"

local field, line, eol = grammar.field, grammar.line, grammar.eol

-- the title: the largest lines in the top half of the first page, one
-- after another; the authors: the line after them
local title_here = grammar.page(1) * grammar.largest * grammar.near_top(0.5)
local title = title_here * line * (eol * title_here * line) ^ 0

grammar.add("front", lpeg.Ct(grammar.skip_to(title_here) * field("title", title) * eol * field("authors", line)))
