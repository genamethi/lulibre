-- Check the library for orphans: records whose file is gone, files calibre
-- has no record of, and empty folders.
--   :orphans                      the panel: adjust each row's action, then w
--   lulibre run orphans           report what was found and what is suggested
--   lulibre run orphans --apply   carry out the suggested actions
-- Suggested: a record whose file turned up elsewhere in the library gets it
-- back; a record that another book with a file duplicates (same title, same
-- or unknown author) is removed; a stray file identical to a book's file is
-- moved out to ~/.local/share/lulibre/orphans/; a symbolic link in a folder
-- of your own that points at a book file calibre has since renamed is pointed
-- at the file again. Everything else is kept.
local edit = require "lulibre.edit"
local orphans = require "lulibre.orphans"

local apply
for _, a in ipairs({ ... }) do
  if a == "--apply" then apply = true end
end
if not lulibre.headless and not apply then
  require("lulibre.ui.orphans").run()
  return
end

local found = orphans.scan()
io.write(("records with no file: %d\n"):format(#found.records))
for _, r in ipairs(found.records) do
  io.write(("  %-8s %5d  %s%s   [%s]\n"):format(r.action, r.book.id, r.book.title or "",
    edit.is_unknown(r.book.author) and "" or ("  —  " .. r.book.author), r.verdict))
end
io.write(("files with no record: %d\n"):format(#found.strays))
for _, s in ipairs(found.strays) do
  io.write(("  %-8s %s   [%s]\n"):format(s.action, s.rel, s.verdict))
end
io.write(("links that lead nowhere: %d\n"):format(#found.links))
for _, l in ipairs(found.links) do
  io.write(("  %-8s %s   [%s]\n"):format(l.action, l.rel, l.verdict))
end
io.write(("empty folders: %d\n"):format(#found.empty))
for _, dir in ipairs(found.empty) do io.write("           ", dir:sub(#found.root + 2), "\n") end
local n = orphans.counts(found)
io.write(("suggested: re-attach %d, remove %d records, move %d files out, repair %d links, keep %d\n"):format(
  n.reattach, n.remove, n.move, n.relink, n.keep))
if apply then
  local carried = require("lulibre.dupes").propose(orphans.gather(found), "record with no file")
  if carried > 0 then io.write(("%d things the removed records knew are now proposals for their copies\n"):format(carried)) end
  local out = orphans.apply(found)
  io.write(orphans.summary(out), "\n")
  if #out.failed > 0 then error(out.failed[1], 0) end
end
