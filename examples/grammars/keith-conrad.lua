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
local small = { a = true, an = true, ["and"] = true, ["for"] = true, ["in"] = true, of = true, on = true,
                the = true, to = true }

-- "GALOIS GROUPS OF CUBICS" as "Galois Groups of Cubics"
local function title_case(s)
  local first = true
  return (expr.lower(s):gsub("[%w\128-\255]+", function(w)
    local keep = small[w] and not first
    first = false
    if keep then return w end
    local head = w:match("^[\192-\255][\128-\191]*") or w:sub(1, 1)
    return expr.upper(head) .. w:sub(#head + 1)
  end))
end

local author = P "KEITH CONRAD"
local title = expr.page(1) * caps * (expr.eol * -author * caps) ^ -1

exprman.add("keith-conrad", expr.Ct(exprman.field("title", title / title_case) * expr.eol
                                    * exprman.field("authors", author / "Keith Conrad")), "Keith Conrad")
