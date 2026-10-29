-- Example grammar: Keith Conrad's expository papers
-- (kconrad.math.uconn.edu/blurbs/). The title is in capitals, with KEITH
-- CONRAD below it. Matching papers get that title and author, and are
-- marked as having no catalogue record.
--
-- To use it, copy this file to ~/.config/lulibre/lua/grammars/ and add
-- require "grammars.keith-conrad" to init.lua.
local G = require "exprman._front"

G.add {
  name = "keith-conrad",
  kind = "handout",
  noncatalog = true,
  lines = {
    G.line { upper = true, take = "title", case = "title" },
    G.opt(G.line { upper = true, take = "title", case = "title" }),
    G.line { pattern = "^KEITH CONRAD$", give = { authors = "Keith Conrad" } },
  },
  confidence = 0.95,
}
