-- The keys of the screens written in Lua: for each screen, its actions and
-- the keys each is on. A screen asks which action a key means, so the keys
-- can be changed without touching it, and the hints in its title bar and its
-- `?` help are written from the same table, so they say what the keys are
-- now, not what they were when the screen was written.
--
--   lulibre.map("review", "y", "accept")     -- in init.lua: y accepts too,
--                                            -- and is the key the hint shows
--   lulibre.map("review", "a", "")           -- a no longer does anything there
--
--   local keys = require("lulibre.ui.keys").of("review")
--   keys:action("a")                 --> "accept"
--   keys:hint("accept", "write")     --> "a accept   w write   ? keys"
--   keys:own()                       --> every key the screen answers to
--   keys:show("review")              --> the `?` overlay
--
-- Moving within a panel (j k gg G, paging) and closing it (q, Esc) are the
-- panel's own and are the same everywhere; they are not in these tables.
local M = {}

-- screen -> list of { action, keys, label, what it does }. The first key of
-- an action is the one hints show.
local DEFAULTS = {
  edit = {
    { "edit", { "<CR>", "e", "i" }, "edit", "type a value; a popup ranks suggestions and Tab takes the highlighted one" },
    { "suggest", { "<Space>" }, "suggest", "step through what the file itself and related books suggest" },
    { "fill", { "a" }, "fill gaps", "take the file's best suggestion for every field that is empty" },
    { "clear", { "c" }, "clear", "blank the field: the form shows (blank) where the value will be removed" },
    { "revert", { "x" }, "revert", "forget the change pending for this field" },
    { "write", { "w" }, "write", "write the changes and close" },
  },
  review = {
    { "accept", { "a" }, "accept", "accept the proposal (again: back to pending)" },
    { "reject", { "r" }, "reject", "reject the proposal" },
    { "edit", { "e", "<CR>" }, "edit", "correct the proposed value, or type one for a field nothing was proposed for" },
    { "clear", { "c" }, "clear", "propose blanking this field" },
    { "expand", { "x" }, "other fields", "show the book's other fields under its proposals, or hide them" },
    { "expand_all", { "X" }, "all", "show, or hide, every book's other fields" },
    { "accept_above", { "A" }, "accept all above…", "accept every pending proposal at or above a confidence you give" },
    { "reject_rest", { "R" }, "reject rest", "reject everything still pending" },
    { "sort", { "s" }, "sort", "order the books by their surest proposal, or by id" },
    { "peek", { "p" }, "more preview", "shrink this panel to give the preview room; again to bring it back" },
    { "write", { "w" }, "write", "write what has been accepted, as one change that can be undone" },
  },
  dupes = {
    { "keep", { "<Space>", "<CR>" }, "keep this copy", "keep the copy under the cursor instead" },
    { "skip", { "s" }, "skip group", "leave this group alone: nothing in it is removed" },
    { "mark", { "m" }, "mark the rest", "mark the surplus copies in the list" },
    { "filter", { "f" }, "filter", "narrow the list to books that have a duplicate" },
    { "edit", { "e" }, "edit", "open the edit form for the book under the cursor" },
    { "review", { "r" }, "review", "go through the proposals waiting for the book under the cursor" },
    { "peek", { "p" }, "more preview", "shrink this panel to give the preview room; again to bring it back" },
    { "remove", { "D" }, "remove the rest", "remove the surplus copies (to calibre's recycle bin)" },
  },
  orphans = {
    { "action", { "<Space>", "<CR>" }, "action", "change what will be done about this row" },
    { "expand", { "x" }, "details", "show what the columns cut short: the verdict in full, the whole path" },
    { "expand_all", { "X" }, "all", "show, or hide, every row's details" },
    { "mark", { "m" }, "mark", "mark the records set to be removed" },
    { "filter", { "f" }, "filter", "narrow the list to books whose file is missing" },
    { "edit", { "e" }, "edit", "open the edit form for the row's book" },
    { "review", { "r" }, "review", "go through the proposals waiting for the row's book" },
    { "peek", { "p" }, "more preview", "shrink this panel to give the preview room; again to bring it back" },
    { "write", { "w" }, "do it", "carry out the actions" },
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

--- Put every screen's keys back as they come.
function M.reset()
  screens = {}
  for name, list in pairs(DEFAULTS) do screens[name] = copy(list) end
end
M.reset()

--- Give a script's own screen a key table: list is { {action, {keys}, label,
-- description}, ... }. Defining a screen again replaces it.
function M.define(screen, list)
  DEFAULTS[screen] = list
  screens[screen] = copy(list)
end

function M.has(screen)
  return screens[screen] ~= nil
end

function M.names()
  local out = {}
  for name in pairs(screens) do out[#out + 1] = name end
  table.sort(out)
  return out
end

--- Put a key on an action of a screen; it becomes the key the hints show.
-- An empty action takes the key away from whatever had it.
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

--- A key as a person would read it: "<CR>" is "Enter".
function M.spoken(key)
  return SPOKEN[key] or key
end

local View = {}
View.__index = View

--- The action a key means on this screen, or nil.
function View:action(key)
  return screens[self.screen].by_key[key]
end

--- The key an action is on, as it is read; nil if it has none.
function View:key(action)
  local keys = screens[self.screen].keys[action]
  return keys and keys[1] and M.spoken(keys[1])
end

--- Every key this screen answers to, in key-map notation.
function View:own()
  local out = {}
  for key in pairs(screens[self.screen].by_key) do out[#out + 1] = key end
  table.sort(out)
  return out
end

--- A line for the title bar: the named actions with their keys, then how to
-- see the rest. Actions that have lost their key are left out.
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

--- The whole list, as lines: every action, its keys, what it does.
function View:lines()
  local s, out = screens[self.screen], {}
  for _, action in ipairs(s.order) do
    local keys = {}
    for i, k in ipairs(s.keys[action]) do keys[i] = M.spoken(k) end
    if #keys > 0 and action ~= "help" then
      out[#out + 1] = ("  %-16s %s"):format(table.concat(keys, "  "), s.about[action])
    end
  end
  return out
end

--- Show the `?` overlay. extra: lines to add under the screen's own keys
-- (what else works there).
function View:show(title, extra)
  local out = { "KEYS HERE" }
  for _, line in ipairs(self:lines()) do out[#out + 1] = line end
  out[#out + 1] = ""
  out[#out + 1] = "MOVING"
  out[#out + 1] = "  j  k  gg  G      up, down, top, bottom;  <C-d> <C-u> <C-f> <C-b> page"
  out[#out + 1] = "  q  Esc           close"
  out[#out + 1] = "  Tab  <C-w>…      the other windows;  : a command"
  for _, line in ipairs(extra or {}) do out[#out + 1] = line end
  out[#out + 1] = ""
  out[#out + 1] = ("These keys can be changed: lulibre.map(\"%s\", key, action) in init.lua."):format(self.screen)
  local actions = {}
  for _, action in ipairs(screens[self.screen].order) do
    if action ~= "help" then actions[#actions + 1] = action end
  end
  out[#out + 1] = "Actions: " .. table.concat(actions, ", ") .. "."
  lulibre.show(out, title or self.screen)
end

--- The keys of one screen.
function M.of(screen)
  if not screens[screen] then error("no screen named " .. tostring(screen), 2) end
  return setmetatable({ screen = screen }, View)
end

return M
