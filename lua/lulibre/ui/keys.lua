--- Holds the keys of the screens written in Lua: each screen's actions and
-- the keys bound to each action.
--
-- A screen looks up which action a key means, so you can change the keys
-- without changing the screen. The hints in the screen's title bar and its
-- `?` help are written from the same table, so they show the current keys,
-- not the keys at the time the screen was written.
--
--    lulibre.map("review", "y", "accept")     -- in init.lua: y accepts too,
--                                             -- and is the key the hint shows
--    lulibre.map("review", "a", "")           -- a no longer does anything there
--
-- Moving within a panel (j k gg G, paging), closing it (q) and leaving it
-- (Esc) work the same in every panel. These keys are bound in one place,
-- "panel" (src/tui/ctxkeys.c): lulibre.map("panel", "n", "down"). A panel's
-- movement keys take precedence over a screen's own, so a key bound to both
-- moves.
--
-- @module lulibre.ui.keys
-- @usage
-- local keys = require("lulibre.ui.keys").of("review")
-- keys:action("a")                 --> "accept"
-- keys:hint("accept", "write")     --> "a accept   w write   ? keys"
-- keys:own()                       --> every key the screen answers to
-- keys:show("review")              --> the `?` overlay
local M = {}

-- screen -> list of { action, keys, label, what it does }. The first key of
-- an action is the one hints show.
local DEFAULTS = {
  edit = {
    { "edit", { "<CR>", "e" }, "edit", "type a value; a popup ranks suggestions and Tab takes the highlighted one" },
    { "suggest", { "<Space>" }, "suggest", "step through what the file itself and related books suggest" },
    { "fill", { "a" }, "fill gaps", "take the file's best suggestion for every field that is empty" },
    { "clear", { "c" }, "clear", "blank the field: the form shows (blank) where the value will be removed" },
    { "titlecase", { "t" }, "title case", "put the value in title case: Capitals for All but the Minor Words" },
    { "revert", { "x" }, "revert", "forget the change pending for this field" },
    { "about", { "i" }, "about this", "show, where the list is, what the file's pages say for each field (for several books: what they share and where they differ); again to hide it" },
    { "write", { "w" }, "write", "write the changes and close" },
  },
  review = {
    { "accept", { "a" }, "accept", "accept the proposal (again: back to pending); on a book's line, all of that book's" },
    { "reject", { "r" }, "reject", "reject the proposal; on a book's line, all of that book's still pending. A later run may propose it again (unless review_reject = \"always\")" },
    { "never", { "N" }, "never again", "reject the proposal, and never propose that value for this field of this book again; on a book's line, all of that book's still pending" },
    { "edit", { "e", "<CR>" }, "edit", "correct the proposed value, or type one for a field nothing was proposed for" },
    { "clear", { "c" }, "clear", "propose blanking this field" },
    { "titlecase", { "t" }, "title case", "put the value in title case, and accept that" },
    { "expand", { "x" }, "other fields", "show the book's other fields under its proposals, or hide them" },
    { "expand_all", { "X" }, "all", "show, or hide, every book's other fields" },
    { "accept_above", { "A" }, "accept all above…", "accept every pending proposal at or above a confidence you give" },
    { "reject_rest", { "R" }, "reject rest", "reject everything still pending" },
    { "sort", { "s" }, "sort", "order the books: best borne out by their pages first, the surest proposals first, those whose sources disagree most first, or by id" },
    { "field", { "f" }, "field…", "show one field's proposals only: then t title, a authors, s subject, i identifiers, d date, p publisher; f again for all" },
    { "peek", { "p" }, "more preview", "shrink this panel to give the preview room; again to bring it back" },
    { "other", { "o" }, "other source", "show the next source's proposal for this field (one row per field)" },
    { "other_all", { "O" }, "that source everywhere", "for this field, show the next kind of source in every book that has one (CrossRef, Open Library, the title page ...)" },
    { "rows", { "m" }, "rows", "one row per field, the surest proposal shown; or every proposal a row of its own" },
    { "about", { "i" }, "about this", "show, where the list is, what the proposal under the cursor rests on; again to hide it" },
    { "next_view", { "l", "<Right>" }, "next view", "the next tab: each run of proposing that has something waiting, then everything that waits" },
    { "prev_view", { "h", "<Left>" }, "previous view", "the tab before" },
    { "drop", { "D" }, "drop these", "drop every proposal in the view in front (deleted, not rejected: they can be proposed again); stops a run still going on" },
    { "write", { "w" }, "write", "write what has been accepted, as one change that can be undone" },
  },
  dupes = {
    { "keep", { "<Space>", "<CR>" }, "keep this copy", "keep the copy under the cursor instead" },
    { "skip", { "s" }, "skip group", "leave this group alone: nothing in it is removed" },
    { "mark", { "m" }, "mark the rest", "mark the surplus copies in the list" },
    { "filter", { "f" }, "filter", "narrow the list to books that have a duplicate" },
    { "take", { "t" }, "take from this", "propose this copy's values for the copy being kept, and review them" },
    { "edit", { "e" }, "edit", "open the edit form for the book under the cursor" },
    { "review", { "r" }, "review", "go through the proposals waiting for the book under the cursor" },
    { "peek", { "p" }, "more preview", "shrink this panel to give the preview room; again to bring it back" },
    { "about", { "i" }, "about this", "show, where the list is, the group's copies side by side, field by field; again to hide it" },
    { "remove", { "D" }, "remove the rest", "remove the surplus copies (to calibre's recycle bin)" },
  },
  orphans = {
    { "action", { "<Space>", "<CR>" }, "action", "change what will be done about this row; on a heading, about every row under it" },
    { "expand", { "x" }, "details", "show what the columns cut short: the verdict in full, the whole path" },
    { "expand_all", { "X" }, "all", "show, or hide, every row's details" },
    { "mark", { "m" }, "mark", "mark the records set to be removed" },
    { "filter", { "f" }, "filter", "narrow the list to books whose file is missing" },
    { "take", { "t" }, "take from this", "propose this record's values for the book that has the file, and review them" },
    { "edit", { "e" }, "edit", "open the edit form for the row's book" },
    { "review", { "r" }, "review", "go through the proposals waiting for the row's book" },
    { "peek", { "p" }, "more preview", "shrink this panel to give the preview room; again to bring it back" },
    { "about", { "i" }, "about this", "show, where the list is, the row's record beside the book that has its file, or the stray file and its twin; again to hide it" },
    { "write", { "w" }, "do it", "carry out the actions" },
  },
  beside = {
    { "add", { "S", "a" }, "add", "add this file to the library; the file stays in the folder" },
    { "move", { "X" }, "add and remove", "add it, then delete it from the sync folder" },
    { "drop", { "D" }, "drop", "take it out of the folder without adding it (undo puts it back)" },
    { "edit", { "<CR>", "e" }, "edit", "edit what the file will be added with" },
    { "review", { "r" }, "review", "go through the proposals waiting for this file" },
    { "match", { "m" }, "matches", "have the library's list follow with the books that look like the file, or leave it be" },
    { "rescan", { "R" }, "look again", "read the sync folder again" },
  },
  help = {
    { "toggle", { "<Space>", "<CR>" }, "open or close", "open the heading, or close it; on a key, show what the guides say about it" },
    { "open", { "<Right>", "l" }, "open", "open the heading" },
    { "close", { "<Left>", "h" }, "close", "close the heading the cursor is on, or under" },
    { "find", { "/" }, "search", "search every key and command as you type; an empty search shows all again" },
    { "clear", { "<BS>" }, "all again", "leave the search and show everything" },
    { "topic", { "K" }, "the guides", "what the guides say about the key or command under the cursor" },
    { "all", { "O" }, "open all", "open every heading" },
    { "none", { "C" }, "close all", "close every heading" },
  },
  form = {
    { "toggle", { "<Space>" }, "tick", "tick or untick a box; step through a choice" },
    { "change", { "<CR>" }, "change", "tick a box, step through a choice, type a value, or do what the line says" },
    { "next", { "<Right>", "l" }, "next", "the next of a choice" },
    { "prev", { "<Left>", "h" }, "previous", "the one before" },
    { "go", { "w" }, "go", "do the first thing the dialog offers, with things as they are set" },
  },
  weights = {
    { "set", { "<CR>", "e" }, "set", "say yourself how much this source is believed about this field (0 to 1)" },
    { "clear", { "x" }, "measured", "give the weight back to the measurement" },
    { "measure", { "M" }, "measure again", "measure every source against the library as it stands now" },
  },
  good = {
    { "confirm", { "<Space>", "<CR>" }, "confirm", "confirm the record as right, or take that back" },
    { "confirm_above", { "A" }, "confirm all above…", "confirm every record at or above a score you give" },
    { "view", { "v" }, "view", "show the records still to confirm, the confirmed ones, or all" },
    { "edit", { "e" }, "edit", "open the edit form for the record" },
    { "learn", { "L" }, "learn", "learn each subject's telling phrases from the confirmed records" },
    { "peek", { "p" }, "more preview", "shrink this panel to give the preview room; again to bring it back" },
  },
  terms = {
    { "drop", { "x" }, "drop", "drop the phrase: it will not be learned for this subject again (again: let it be)" },
    { "add", { "a" }, "add", "add a phrase of your own to the subject under the cursor" },
    { "find", { "f", "<CR>" }, "find", "narrow the list to the books whose pages hold the phrase" },
    { "dropped", { "d" }, "dropped", "show, or hide, the phrases that were dropped" },
    { "learn", { "L" }, "learn again", "learn again from the confirmed records" },
  },
  capture = {
    { "pattern", { "p", "<CR>" }, "pattern", "type the pattern; the table follows as you type" },
    { "source", { "s" }, "source", "choose what the pattern is run against" },
    { "write", { "w" }, "write", "write what the pattern captured" },
    { "propose", { "P" }, "propose", "turn what it captured into proposals for review" },
    { "mark", { "m" }, "mark matches", "mark the books the pattern matches" },
    { "save", { "S" }, "save rule", "save the pattern under a name" },
    { "load", { "L" }, "load rule", "use a saved pattern" },
  },
  config = {
    { "edit", { "<CR>", "e" }, "change", "give the option a value: it takes effect now and is written to init.lua" },
    { "default", { "d" }, "default", "put the option back to its default (its line in init.lua is commented out)" },
    { "editor", { "E" }, "edit init.lua", "open init.lua in your editor; what you write is read again when you leave it" },
    { "add", { "a" }, "add missing", "add the options that are not in init.lua, with their defaults (commented out, or set: config_add_as)" },
    { "comments", { "c" }, "comments", "what is written above an option put in init.lua: its help, the values it takes, or nothing" },
    { "changed", { "f" }, "changed only", "show only the options that differ from their defaults, or all" },
  },
  snapshots = {
    { "back", { "<CR>" }, "go back", "put the library back to the snapshot under the cursor (shows what it will do, then asks)" },
    { "take", { "n" }, "new", "take a snapshot now" },
    { "retire", { "x" }, "retire", "take the snapshot out of the list (again: bring it back); nothing is deleted" },
    { "all", { "a" }, "all", "show the retired snapshots too, or hide them" },
    { "exact", { "E" }, "exact", "going back also puts back what was changed outside lulibre" },
    { "unsync", { "U" }, "unsync", "going back takes books added from the sync folder since out of the library, to unsynced/" },
    { "fields", { "F" }, "fields only", "going back puts back fields only: no book is brought back, removed or taken out" },
  },
  browse = {
    { "open", { "l", "<Right>" }, "open", "open the branch" },
    { "toggle", { "<CR>" }, "open or close", "open the branch, or close it" },
    { "close", { "h", "<Left>" }, "close", "close the branch, or step out to its parent" },
    { "find", { "/" }, "find", "jump to a name as you type it" },
    { "sort", { "s" }, "sort", "order by name, or by number of books" },
    { "facet", { "f" }, "facet", "the next way of grouping: author, subject, series ..." },
    { "facet_back", { "F" }, "previous facet", "the previous way of grouping" },
  },
}
local HELP = { "help", { "?" }, "keys", "this list" }

local screens

local function copy(list)
  local s = { order = {}, keys = {}, label = {}, about = {}, by_key = {} }
  local function add(def)
    local action = def[1]
    s.order[#s.order + 1] = action
    s.keys[action], s.label[action], s.about[action] = {}, def[3], def[4]
    for i, k in ipairs(def[2]) do
      s.keys[action][i] = k
      s.by_key[k] = action
    end
  end
  for _, def in ipairs(list) do add(def) end
  add(HELP)
  return s
end

--- Resets every screen's keys to the defaults.
function M.reset()
  screens = {}
  for name, list in pairs(DEFAULTS) do screens[name] = copy(list) end
end
M.reset()

--- Defines the key table of a script's own screen. Defining a screen again
-- replaces its table.
-- @tparam string screen
-- @tparam {table,...} list `{ {action, {keys}, label, description}, ... }`
function M.define(screen, list)
  DEFAULTS[screen] = list
  screens[screen] = copy(list)
end

--- Returns true if the screen has a key table.
-- @tparam string screen
-- @treturn boolean
function M.has(screen)
  return screens[screen] ~= nil
end

--- Returns the screens that have key tables.
-- @treturn {string,...}
function M.names()
  local out = {}
  for name in pairs(screens) do out[#out + 1] = name end
  table.sort(out)
  return out
end

--- Binds a key to an action of a screen. The hints then show this key. An
-- empty action unbinds the key.
-- @tparam string screen
-- @tparam string key "<CR>", "a", "<C-x>" ...
-- @tparam string action
function M.set(screen, key, action)
  local s = screens[screen]
  if not s then error(("no screen named '%s' (there are: %s)"):format(tostring(screen), table.concat(M.names(), ", ")), 2) end
  if action ~= "" and not s.keys[action] then
    error(("the %s screen has no action '%s' (it has: %s)"):format(screen, tostring(action), table.concat(s.order, ", ")), 2)
  end
  local had = s.by_key[key]
  if had then
    for i = #s.keys[had], 1, -1 do
      if s.keys[had][i] == key then table.remove(s.keys[had], i) end
    end
  end
  s.by_key[key] = nil
  if action ~= "" then
    table.insert(s.keys[action], 1, key)
    s.by_key[key] = action
  end
end

local SPOKEN = { ["<CR>"] = "Enter", ["<Space>"] = "Space", ["<Tab>"] = "Tab", ["<BS>"] = "Backspace",
  ["<Left>"] = "←", ["<Right>"] = "→", ["<Up>"] = "↑", ["<Down>"] = "↓" }

--- Returns a key in readable form: "<CR>" becomes "Enter".
-- @tparam string key
-- @treturn string
function M.spoken(key)
  return SPOKEN[key] or key
end

local View = {}
View.__index = View

--- Returns the action a key means on this screen, or nil.
function View:action(key)
  return screens[self.screen].by_key[key]
end

--- Returns the key bound to an action, in readable form, or nil if the
-- action has no key.
function View:key(action)
  local keys = screens[self.screen].keys[action]
  return keys and keys[1] and M.spoken(keys[1])
end

--- Returns every key this screen responds to, in key-map notation.
function View:own()
  local out = {}
  for key in pairs(screens[self.screen].by_key) do out[#out + 1] = key end
  table.sort(out)
  return out
end

--- Returns a line for the title bar: the named actions with their keys,
-- then how to see the rest. Actions without a key are left out.
function View:hint(...)
  local s, parts = screens[self.screen], {}
  for _, action in ipairs { ... } do
    local key = self:key(action)
    if key then parts[#parts + 1] = key .. " " .. s.label[action] end
  end
  local help = self:key("help")
  if help then parts[#parts + 1] = help .. " keys" end
  return table.concat(parts, "   ")
end

--- Returns every action as lines: the action, its keys, and what it does.
function View:lines()
  local s, out = screens[self.screen], {}
  for _, action in ipairs(s.order) do
    local keys = {}
    for i, k in ipairs(s.keys[action]) do keys[i] = M.spoken(k) end
    if #keys > 0 and action ~= "help" then
      out[#out + 1] = ("  %-22s %s"):format(table.concat(keys, "  "), s.about[action])
    end
  end
  return out
end

--- Shows the `?` overlay. `extra` is lines to add under the screen's own
-- keys, listing what else works there.
function View:show(title, extra)
  local out = { "KEYS HERE" }
  for _, line in ipairs(self:lines()) do out[#out + 1] = line end
  out[#out + 1] = ""
  -- moving and closing are the same in every panel, and bound in one place
  local first = true
  for line in (lulibre.place_keys("panel") or ""):gmatch("[^\n]+") do
    out[#out + 1] = first and "MOVING, IN ANY PANEL" or line
    first = false
  end
  out[#out + 1] = ("  %-22s %s"):format("Tab  <C-w>…  :", "the other windows; a command")
  for _, line in ipairs(extra or {}) do out[#out + 1] = line end
  out[#out + 1] = ""
  out[#out + 1] = ("These keys can be changed in init.lua: lulibre.map(\"%s\", key, action) for this"):format(self.screen)
  out[#out + 1] = "screen's, lulibre.map(\"panel\", key, action) for moving (down, up, top, bottom, close ...)."
  local actions = {}
  for _, action in ipairs(screens[self.screen].order) do
    if action ~= "help" then actions[#actions + 1] = action end
  end
  out[#out + 1] = "Actions: " .. table.concat(actions, ", ") .. "."
  lulibre.show(out, title or self.screen)
end

--- Returns the keys of one screen.
-- @tparam string screen
-- @treturn table with `:action(key)`, `:key(action)`, `:hint(...)`, `:own()`, `:lines()`, `:show(title, extra)`
function M.of(screen)
  if not screens[screen] then error("no screen named " .. tostring(screen), 2) end
  return setmetatable({ screen = screen }, View)
end

return M
