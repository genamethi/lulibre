-- What the grammars of publications (lulibre.grammars) make of the books:
-- which books each grammar matches, and the fields it sets from their
-- opening lines.
--   :run grammars [filter]           say what each grammar finds; nothing is changed
--   :run grammars --apply [filter]   and keep it: the whole each is a part of
--                                    (:parts), the non-catalog mark where the
--                                    grammar says such works have no record
-- What they say of titles and authors is proposed by :propose, like what
-- the title page says.
local grammars = require "lulibre.grammars"
local parts = require "lulibre.parts"

local apply, words = false, {}
for _, a in ipairs({ ... }) do
  if a == "--apply" then apply = true else words[#words + 1] = a end
end
local ids = lulibre.ids(#words > 0 and table.concat(words, " ") or "in:library")

local by, order = {}, {}
local kept, marked, pending = 0, {}, {}
for k, id in ipairs(ids) do
  if k % 100 == 0 then lulibre.progress(("reading %d/%d"):format(k, #ids)) end
  local doc = grammars.doc(id)
  for _, m in ipairs(doc and grammars.match(doc) or {}) do
    local g = m.grammar
    if not by[g.name] then
      by[g.name] = {}
      order[#order + 1] = g.name
    end
    table.insert(by[g.name], { id = id, fields = m.fields })
    if apply then
      if m.fields.part_of then
        pending[#pending + 1] = { id = id, whole = m.fields.part_of, part = tonumber(m.fields.part), parts = tonumber(m.fields.parts) }
        kept = kept + 1
      end
      if g.noncatalog then marked[#marked + 1] = id end
    end
  end
end
lulibre.progress(nil)
-- the parts, as one change (journaled: undo takes it back)
if #pending > 0 then parts.set(pending, "grammars") end
local nc
if apply and #marked > 0 then nc = require("lulibre.noncatalog").set(marked, true) end

local out = { ("%d books read"):format(#ids) }
for _, name in ipairs(order) do
  local list = by[name]
  out[#out + 1] = ""
  out[#out + 1] = ("%s: %d"):format(name, #list)
  for i = 1, math.min(8, #list) do
    local f = list[i].fields
    local book = lulibre.book(list[i].id)
    out[#out + 1] = ("  %6d  %-48s %s%s"):format(list[i].id, (f.title or (book and book.title) or ""):sub(1, 48),
      f.authors or "", f.part_of and ("   part %s of %s"):format(tostring(f.part or "?"), f.part_of) or "")
  end
  if #list > 8 then out[#out + 1] = ("  ... and %d more"):format(#list - 8) end
end
if apply then
  out[#out + 1] = ""
  out[#out + 1] = ("kept: %d parts of a whole (:parts lists them)%s"):format(kept,
    nc and ("; %d marked non-catalog (%d waiting proposals withdrawn)"):format(#marked, nc.withdrawn) or "")
else
  out[#out + 1] = ""
  out[#out + 1] = "--apply keeps the parts and the non-catalog marks; :propose offers the titles and authors"
end
if lulibre.headless then print(table.concat(out, "\n")) else lulibre.show(out, "the grammars of publications") end
