--- The packaged grammar: a front page's title and authors, from the
-- layout alone. Grammars written for a group of books (an author, a
-- publisher, a series) are added the same way, with exprman.add.
--
-- @library exprman._front
local expr = require "expr"
local exprman = require "exprman"

local field, line, eol = exprman.field, expr.line, expr.eol

-- the title: the largest lines in the top half of the first page, one
-- after another; the authors: the line after them
local title_here = expr.page(1) * expr.largest * expr.near_top(0.5)
local title = title_here * line * (eol * title_here * line) ^ 0

exprman.add("front", expr.Ct(expr.upto(title_here) * field("title", title) * eol * field("authors", line)))
