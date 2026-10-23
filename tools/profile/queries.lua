-- Filters run by the profile's query step: plain fields, full text, and a
-- regrouping of the whole library.
local filters = { "", "author:smith", "title:algebra", 'text:"spectral sequence"', "text:~lemma%s+%d", "-has:isbn",
  "is:needsocr", "year:<2000", "tag:math" }
for _, f in ipairs(filters) do
  for _ = 1, 5 do lulibre.count(f) end
end
