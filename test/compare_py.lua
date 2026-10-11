-- Compare the Lua title-page parser with the proposals the Python scripts
-- produced for the same books (scratch/classify_proposals.jsonl).
--   lulibre run test/compare_py.lua /path/to/classify_proposals.jsonl [-v]
local json = require "lulibre.json"
local names = require "lulibre.names"
local taxonomy = require "lulibre.taxonomy"
local titlepage = require "lulibre.titlepage"

local path, verbose = ...
local f = assert(io.open(path), "cannot open " .. tostring(path))

local function norm(s)
  return lulibre.fold(s or ""):gsub("[^%w]+", " "):gsub("^ +", ""):gsub(" +$", "")
end

local n, missing = 0, 0
local auth = { both = 0, same = 0, only_py = 0, only_lua = 0, differ = 0 }
local subj = { both = 0, same = 0, only_py = 0, only_lua = 0, differ = 0 }
local diffs = {}

for line in f:lines() do
  local rec = json.decode(line)
  local lines = lulibre.lines(rec.book_id, 1)
  if #lines == 0 then
    missing = missing + 1
  else
    n = n + 1
    local r = titlepage.classify(lines)
    local people = {}
    for i, a in ipairs(r.authors) do people[i] = names.titlecase(a) end
    local lua_auth = #people > 0 and table.concat(people, "; ") or nil
    local py_auth = rec.authors

    local function tally(t, py, lua, what)
      if py and lua then
        t.both = t.both + 1
        if norm(py) == norm(lua) then t.same = t.same + 1
        else
          t.differ = t.differ + 1
          diffs[#diffs + 1] = ("%-8s %5d  py: %-40s lua: %s"):format(what, rec.book_id, py, lua)
        end
      elseif py then
        t.only_py = t.only_py + 1
        diffs[#diffs + 1] = ("%-8s %5d  py: %-40s lua: -"):format(what, rec.book_id, py)
      elseif lua then
        t.only_lua = t.only_lua + 1
        diffs[#diffs + 1] = ("%-8s %5d  py: %-40s lua: %s"):format(what, rec.book_id, "-", lua)
      end
    end
    tally(auth, py_auth, lua_auth, "authors")
    -- the Python maps used other names for a few subjects; compare canonical forms
    tally(subj, rec.subject and taxonomy.canonical(rec.subject), r.subject and taxonomy.canonical(r.subject), "subject")
  end
end
f:close()

print(("books compared: %d   (no indexed lines for %d more)"):format(n, missing))
for _, pair in ipairs({ { "authors", auth }, { "subject", subj } }) do
  local name, t = pair[1], pair[2]
  print(("%-8s both found %3d (same %3d, differ %3d)   only python %3d   only lua %3d")
    :format(name, t.both, t.same, t.differ, t.only_py, t.only_lua))
end
if verbose then
  table.sort(diffs)
  for _, d in ipairs(diffs) do print(d) end
end
