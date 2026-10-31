-- Example grammar: Keith Conrad's expository papers
-- (kconrad.math.uconn.edu/blurbs/). The title is in capitals at the top of
-- the first page, on one line or two, with KEITH CONRAD below it.
--
-- To use it, copy this file to ~/.config/lulibre/lua/ and add
-- require "keith-conrad" to init.lua.
local expr, exprman = require "expr", require "exprman"
local P, R, S = expr.P, expr.R, expr.S

-- a line with no lower case
local caps = (1 - R "az" - S "\n\f") ^ 1

local title_case = require("lulib._titlecase").apply

local author = P "KEITH CONRAD"
local title = expr.page(1) * caps * (expr.eol * -author * caps) ^ -1

exprman.add("keith-conrad", expr.Ct(exprman.field("title", title / title_case) * expr.eol
                                    * exprman.field("authors", author / "Keith Conrad")), "Keith Conrad")
