-- Snapshots of the library, and putting it back to one (lulibre.snapshots).
--   :snapshot [take] [NAME]          take one now (named by the time, without a name)
--   :snapshots, :snapshot list [--all]   the snapshots, with how much has changed since each
--   :snapshot plan SNAP [flags]      what going back to SNAP would do; nothing is changed
--   :snapshot rollback SNAP [flags]  go back to it (asks first); a snapshot is taken
--                                    before, and going back to that one rolls forward
--   :snapshot retire SNAP            take it out of the list (--all still shows it)
--   :snapshot unretire SNAP
--   :snapshot import FILE [NAME]     a snapshot from a copy of calibre's metadata.db
-- SNAP is a snapshot's number or name. Flags:
--   --exact   put back changes made outside lulibre too
--   --unsync  take books added from the sync folder since out of the library,
--             their files to the sync folder's unsynced/ (else they go back to
--             how they were when added)
--   --fields  fields only: no book is brought back, removed or taken out
--   --yes     do not ask (lulibre run snapshot rollback needs it)
--   lulibre run snapshot ...
local snapshots = require "lulibre.snapshots"

local args, flags = {}, {}
for _, a in ipairs({ ... }) do
  local flag = a:match("^%-%-(%a+)$")
  if flag then
    if not ({ exact = 1, unsync = 1, fields = 1, yes = 1, all = 1 })[flag] then
      error(("snapshot does not know --%s"):format(flag), 0)
    end
    flags[flag] = true
  else
    args[#args + 1] = a
  end
end
local verbs = { take = 1, list = 1, plan = 1, rollback = 1, retire = 1, unretire = 1, import = 1 }
local verb = verbs[args[1] or ""] and table.remove(args, 1) or "take"
if flags.all then verb = "list" end

local function say(lines, title)
  if type(lines) == "string" then lines = { lines } end
  if lulibre.headless then print(table.concat(lines, "\n"))
  elseif #lines == 1 then lulibre.notify(lines[1])
  else lulibre.show(lines, title) end
end

local function find()
  local snap, why = snapshots.find(table.concat(args, " "))
  if not snap then error(why, 0) end
  return snap
end

local function when(ts) return os.date("%Y-%m-%d %H:%M", ts) end

if verb == "take" then
  local snap = snapshots.take(table.concat(args, " "))
  say(("took snapshot %d, \"%s\""):format(snap.id, snap.name))
elseif verb == "list" then
  snapshots.observe()
  local out = {}
  for _, s in ipairs(snapshots.list { all = flags.all }) do
    out[#out + 1] = ("%4d  %s  %-44s %5d change%s on %d book%s since%s%s"):format(s.id, when(s.ts), s.name:sub(1, 44),
      s.changes, s.changes == 1 and " " or "s", s.books, s.books == 1 and "" or "s",
      s.auto == 1 and "  (taken by a rollback)" or "", s.retired and "  retired" or "")
    if s.note and s.note ~= "" then out[#out + 1] = "      " .. s.note end
  end
  if #out == 0 then out[1] = "no snapshots yet: :snapshot NAME takes one" end
  say(out, "snapshots   (:snapshot plan N shows what going back to N would do)")
elseif verb == "plan" then
  local plan = snapshots.plan(find(), flags)
  say(snapshots.describe(plan), "going back to a snapshot   (nothing has been changed)")
elseif verb == "rollback" then
  local snap = find()
  local plan = snapshots.plan(snap, flags)
  local lines = snapshots.describe(plan)
  if plan.books == 0 then
    say(lines[#lines]:gsub("^%s+", ""))
    return
  end
  if not flags.yes then
    if lulibre.headless then
      print(table.concat(lines, "\n"))
      print("(add --yes to do it)")
      return
    end
    lulibre.show(lines, "going back to a snapshot")
    if not lulibre.confirm(("go back to snapshot %d, \"%s\"?"):format(snap.id, snap.name)) then
      lulibre.notify("nothing changed")
      return
    end
  end
  local out = snapshots.rollback(snap, flags)
  say(snapshots.summary(out))
elseif verb == "retire" or verb == "unretire" then
  local snap = find()
  snapshots.retire(snap.id, verb == "retire")
  say(("snapshot %d, \"%s\", %s"):format(snap.id, snap.name, verb == "retire" and "retired" or "back in the list"))
elseif verb == "import" then
  local path = table.remove(args, 1)
  if not path then error("snapshot import takes a copy of calibre's metadata.db", 0) end
  local snap, n = snapshots.import(path, #args > 0 and table.concat(args, " ") or nil)
  if not snap then error(n, 0) end
  say({ ("snapshot %d, \"%s\": the library as of %s (%d books)"):format(snap.id, snap.name, when(snap.ts), n.books),
    ("  %d value%s the journal did not see (changed outside lulibre) go with it"):format(n.values, n.values == 1 and "" or "s"),
    n.gone > 0 and ("  %d of its books are gone from the library with no trace in the journal"):format(n.gone) or nil },
    "snapshot imported")
end
