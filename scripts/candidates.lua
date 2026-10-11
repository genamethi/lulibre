-- Show what lulibre can infer about the selected books next to what calibre
-- has now. Changes nothing.
--   in the interface:  :run candidates        (acts on the selection)
--   from the shell:    lulibre run candidates 'author:unknown fmt:pdf'
local extract = require "lulibre.extract"

local filter = table.concat({ ... }, " ")
local ids = (lulibre.headless or filter ~= "") and lulibre.ids(filter) or lulibre.selection()

local out = {}
for _, id in ipairs(ids) do
  local b = lulibre.book(id)
  out[#out + 1] = ("%d  %s"):format(id, b.title or "(no title)")
  out[#out + 1] = ("     now          %s  |  %s"):format(b.author or "-",
    #b.tags > 0 and table.concat(b.tags, ", ") or "no subject")
  for _, c in ipairs(extract.candidates(id)) do
    out[#out + 1] = ("     %-12s %s   [%s, %.2f]"):format(c.field, c.value, c.source, c.confidence)
  end
  out[#out + 1] = ""
end
if #ids == 0 then out[1] = "no books selected" end
lulibre.show(out, ("candidates for %d book%s"):format(#ids, #ids == 1 and "" or "s"))
