--- Help: the keys, by what they are for, under headings that open and close,
-- with a search over all of them; and the guides, by topic.
--
--   ?              the keys: Enter opens a heading, / searches, K (or Enter on
--                  a key) shows what the guides say about it
--   :help          the same
--   :help TOPIC    the part of the guides about a word: `:help enrich`,
--                  `:help filters`, `:help group`
--
-- The guides are the files of docs/, installed beside lulibre's Lua code.
--
-- @module lulibre.ui.help
-- @usage
-- require("lulibre.ui.help").run()   -- as :help, ? does
local M = {}

local keys = require("lulibre.ui.keys").of("help")

-- What a command is for, by its first word. Anything not named here goes
-- under the last heading.
local SECTIONS = {
  { "Moving and finding", "move search prompt filter pick sort" },
  { "The list as a tree, and selecting", "group fold enter mark visual" },
  { "Changing what a book says", "edit change review propose propose-review enrich-dialog weights weigh capture titlecase clear undo enrich" },
  { "The preview", "preview addpages" },
  { "Copying", "yank" },
  { "Windows", "focus split close only resize console" },
  { "The sync folder", "sync sync-dialog source beside" },
  { "Looking after the library", "dupes orphans good noncatalog custom parts verify snapshot snapshots rollback terms learn refs junk datasets datasets-dialog arxiv-fetch browse reload" },
  { "lulibre itself", "help help-plain config features quit reload-cfg set echo lua run" },
}
local PLACES = { { "panel", "In a panel (review, the edit form ...)" }, { "line", "While typing" }, { "picker", "In a picker" },
  { "pager", "In a page of text such as a guide" }, { "console", "In the console" }, { "select", "Selecting text in the preview" } }
local SCREENS = { { "review", "Review" }, { "edit", "The edit form" }, { "dupes", "Duplicates" }, { "orphans", "Orphans" },
  { "beside", "The sync folder beside the library" }, { "good", "Known good records" }, { "terms", "Subject phrases" },
  { "capture", "Capture" }, { "browse", "The browse column" }, { "snapshots", "Snapshots" }, { "config", "The configuration window" } }

-- What the keys that come with lulibre do, in a few words: a binding of
-- your own shows its description, or its command.
local ABOUT = {
  ["move +1"] = "down a row", ["move -1"] = "up a row", ["move top"] = "the first row", ["move bottom"] = "the last row",
  ["move half-down"] = "half a page down", ["move half-up"] = "half a page up", ["move page-down"] = "a page down",
  ["move page-up"] = "a page up", ["prompt search"] = "search: jump to matches without narrowing the list",
  ["search next"] = "the next match", ["search prev"] = "the match before", ["prompt filter"] = "filter: narrow the list as you type",
  ["prompt command"] = "type a command", ["pick books"] = "find a book by typing some of its title",
  ["pick authors"] = "pick an author: the list narrows to theirs", ["pick subjects"] = "pick a subject: the list narrows to it",
  ["pick filters"] = "pick a ready-made filter: no author, no date, marked ...", ["filter"] = "show everything again",
  ["pick group"] = "set the list out as a tree: choose what by", ["group none"] = "the plain list again",
  ["pick sort"] = "choose the order of the books", ["enter"] = "open or close a heading; on a book, the edit form",
  ["fold open"] = "open the heading", ["fold close"] = "close it (on a closed one: step out to the heading it is within)",
  ["fold toggle"] = "open or close the heading", ["fold all"] = "open every heading", ["fold none"] = "close every heading",
  ["mark toggle"] = "mark the book; on a heading, every book under it", ["visual"] = "select a range of rows (again, or Esc: stop)",
  ["preview scroll +3"] = "scroll the preview down", ["preview scroll -3"] = "scroll the preview up",
  ["preview page +1"] = "the next page", ["preview page -1"] = "the page before", ["preview graphic"] = "the page as an image, or as text again",
  ["preview zoom +1"] = "zoom the image in", ["preview zoom -1"] = "zoom out", ["preview zoom 0"] = "zoom back to the page's width",
  ["preview pan -6"] = "pan the image left", ["preview pan +6"] = "pan it right",
  ["preview select"] = "select text with the keys: a cursor comes out in the page",
  ["preview add"] = "read this file as far as the page being shown",
  ["focus next"] = "the next window (list, previews, console)", ["focus prev"] = "the window before",
  ["focus panel"] = "the panels: the one last in, then the next", ["focus panel prev"] = "the panel before", ["focus h"] = "the window to the left", ["focus j"] = "the window below",
  ["focus k"] = "the window above", ["focus l"] = "the window to the right", ["split v preview"] = "another preview, beside",
  ["split h preview"] = "another preview, below", ["close"] = "close this window", ["only"] = "close every other window",
  ["resize +1"] = "grow this window", ["resize -1"] = "shrink it", ["resize left"] = "move the line beside this window left",
  ["resize right"] = "move it right", ["resize up"] = "move it up", ["resize down"] = "move it down",
  ["edit"] = "the edit form, for what is selected", ["capture"] = "pull fields out of file names or titles by a pattern",
  ["titlecase"] = "put the title in title case", ["propose"] = "propose metadata for what is selected, from the files themselves",
  ["propose-review"] = "a dialog: what to ask, for which fields, what review shows; then propose and review",
  ["weights"] = "how much each kind of source is believed, field by field",
  ["enrich-dialog"] = "a dialog: look the selected books up; what would be asked of whom, then go",
  ["change"] = "a dialog: one change to every selected book at once",
  ["datasets-dialog"] = "a dialog: the databases kept here, with boxes for which to fetch",
  ["sync-dialog"] = "a dialog: add, move or drop the selected waiting files",
  ["mark none"] = "unmark every book",
  ["review"] = "go through the proposals: what was just proposed, else everything that waits", ["review selection"] = "go through the proposals of what is selected",
  ["browse"] = "a tree of the library in a column on the left", ["dupes"] = "books whose files are the same, byte for byte",
  ["orphans"] = "records with no file, files with no record, broken links", ["good"] = "confirm records as right; they are learned from",
  ["noncatalog"] = "works no catalogue has a record of: no DOI or ISBN is looked for",
  ["verify"] = "the library held against its files: titles, authors and identifiers the pages bear out",
  ["backup"] = "copies of calibre's database: list them, make one now, say when they are made",
  ["units"] = "lulibre's systemd units around calibre's content server, as server_hook, opf_writer and server_restart_at ask",
  ["offline"] = "what waits for the content server to be stopped (a new calibre column); restart it for them now",
  ["snapshot"] = "take a snapshot of the library, or plan, import, retire one",
  ["custom"] = "fields of your own beside calibre's (#partof ...): list, declare, set",
  ["parts"] = "the books that are parts of a whole, in order, with what is missing",
  ["config"] = "the configuration window: every option, its value and what it does; E edits init.lua",
  ["features"] = "the features that need programs of their own: installed or not, on or off",
  ["snapshots"] = "the snapshot browser: what going back to each would do; go back, take, retire",
  ["rollback"] = "put the library back to a snapshot (shows what it will do, then asks)",
  ["sync"] = "read the sync folder and show it", ["beside"] = "the sync folder in a column beside the library",
  ["source library"] = "show the library", ["sync add"] = "add the selected waiting files to the library",
  ["sync move"] = "add them, and delete them from the sync folder", ["sync drop"] = "take them out of the sync folder without adding them",
  ["undo"] = "undo the last change", ["yank bib"] = "copy as BibTeX", ["yank key"] = "copy the citation key",
  ["yank path"] = "copy the file's path", ["yank title"] = "copy the title", ["reload"] = "read calibre's metadata again now",
  ["reload-cfg"] = "read init.lua again", ["help"] = "this: the keys, by what they are for", ["console"] = "the log console",
  ["quit"] = "leave lulibre",
}

-- the first things to know, for somebody who has just arrived
local function start()
  local h = lulibre.hint
  return {
    { h("pick group"), "set the list out as a tree: by subject, author, series, folder ...", "pick group" },
    { h("enter"), "open a heading; on a book, the edit form", "enter" },
    { h("prompt filter") .. "  " .. h("prompt search"), "narrow the list as you type; jump between matches", "prompt filter" },
    { h("mark toggle") .. "  " .. h("visual"), "mark a book (or every book under a heading); select a range", "mark toggle" },
    { h("propose"), "propose metadata for what is selected, from the files themselves", "propose" },
    { h("review selection") .. "  " .. h("review"), "go through the proposals: for what is selected, or all of them", "review" },
    { h("edit"), "edit what is selected, with suggestions", "edit" },
    { h("undo"), "undo the last change", "undo" },
    { ":help TOPIC", "what the guides say about a word: :help enrich, :help filters", "help" },
  }
end

--- The folder the guides are in, or nil: docs/ beside the lua/ this file is under.
-- @treturn string|nil
function M.docs_dir()
  local src = debug.getinfo(1, "S").source:gsub("^@", "")
  local root = src:match("^(.*)/lua/lulibre/ui/help%.lua$")
  if not root then return nil end
  for _, dir in ipairs { root .. "/docs", root:gsub("/build/%.%.$", "") .. "/docs" } do
    local f = io.open(dir .. "/workflows.md", "r")
    if f then
      f:close()
      return dir
    end
  end
  return nil
end

M.guides = { { "workflows", "what lulibre does and how: editing, proposals, review, lookups, the sync folder ..." },
  { "keys", "every key and command" }, { "filters", "the filter language of & and /" },
  { "configuration", "the options, init.lua, themes" }, { "api", "the Lua API, for scripts and init.lua" },
  { "development", "building, testing, how the code is laid out" } }

--- Markdown as plain lines for the pager: links as their text, tables as
-- columns, fences dropped.
-- @tparam string text
-- @treturn {string,...}
function M.plain(text)
  local out, fenced = {}, false
  for raw in (text .. "\n"):gmatch("(.-)\n") do
    if raw:match("^```") then
      fenced = not fenced
    elseif fenced then
      out[#out + 1] = "    " .. raw
    elseif not raw:match("^|[%s:%-|]+|%s*$") then -- the rule under a table's head
      local line = raw:gsub("%[([^%]]+)%]%([^)]+%)", "%1"):gsub("%*%*", "")
      if line:match("^|") then
        -- a row of a table: its cells side by side when they fit, else the
        -- first on a line of its own and the others under it
        local cells = {}
        for cell in (line:gsub("^|%s*", ""):gsub("%s*|%s*$", "") .. "|"):gmatch("%s*(.-)%s*|") do cells[#cells + 1] = cell:gsub("`", "") end
        local flat = "  " .. table.concat(cells, "   ·   ")
        if #flat <= 96 or #cells < 2 then
          line = flat
        else
          out[#out + 1] = "  " .. cells[1]
          for i = 2, #cells do
            local rest = cells[i]
            while #rest > 0 do
              local take = rest
              if #take > 88 then
                local cut = take:sub(1, 88):match("^.*()%s") or 88
                take = rest:sub(1, cut)
              end
              out[#out + 1] = "        " .. take:gsub("%s+$", "")
              rest = rest:sub(#take + 1):gsub("^%s+", "")
            end
          end
          line = nil
        end
      end
      if line then
      local hashes, title = line:match("^(#+)%s+(.*)$")
      if hashes then
        line = (#hashes <= 2) and title:upper() or title
        if #out > 0 and out[#out] ~= "" then out[#out + 1] = "" end
      end
      out[#out + 1] = (line:gsub("`", ""))
      end
    end
  end
  return out
end

-- the parts of a guide: { title=, level=, text= }, the text from its heading to the next of its level or above
local function parts_of(text)
  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
  local parts, fenced = {}, false
  for i, line in ipairs(lines) do
    if line:match("^```") then fenced = not fenced end
    local hashes, title = line:match("^(#+)%s+(.*)$")
    if hashes and not fenced then parts[#parts + 1] = { title = title, level = #hashes, from = i } end
  end
  for k, part in ipairs(parts) do
    local to = #lines
    for j = k + 1, #parts do
      if parts[j].level <= part.level then
        to = parts[j].from - 1
        break
      end
    end
    part.text = table.concat(lines, "\n", part.from, to)
  end
  return parts
end

local function read(name)
  local dir = M.docs_dir()
  local f = dir and io.open(dir .. "/" .. name .. ".md", "r")
  if not f then return nil end
  local text = f:read("a")
  f:close()
  return text
end

--- What the guides say about a word: the parts whose heading holds it, the
-- nearest first. Returns { {guide=, title=, text=}, ... }.
-- @tparam string word
-- @treturn {table,...}
function M.find(word)
  local want = lulibre.fold(word)
  local found = {}
  for _, g in ipairs(M.guides) do
    local text = read(g[1])
    for _, part in ipairs(text and parts_of(text) or {}) do
      local title = lulibre.fold(part.title)
      local at = title:find(want, 1, true)
      if at then
        -- a heading that is the word, or names it as a key or a command, comes first
        local exact = title == want or part.title:find("`:?" .. word:gsub("%p", "%%%0") .. "[` ]") ~= nil
        found[#found + 1] = { guide = g[1], title = part.title, text = part.text, rank = (exact and 0 or 100) + part.level * 10 + #title / 100 }
      end
    end
  end
  table.sort(found, function(a, b) return a.rank < b.rank end)
  return found
end

--- Show what the guides say about a word (a guide's own name shows all of it).
-- @tparam string word
function M.topic(word)
  word = (word or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("^:", "")
  if not M.docs_dir() then
    lulibre.notify("the guides are not installed here (docs/ beside lulibre's Lua code)", "error")
    return false
  end
  for _, g in ipairs(M.guides) do
    if g[1] == word then
      lulibre.show(M.plain(read(word) or ""), "help: " .. word)
      return true
    end
  end
  local found = M.find(word)
  if #found == 0 then
    -- no heading names it: the lines that do, across the guides
    local lines = {}
    for _, g in ipairs(M.guides) do
      for line in ((read(g[1]) or "") .. "\n"):gmatch("(.-)\n") do
        if lulibre.fold(line):find(lulibre.fold(word), 1, true) and #lines < 60 then
          lines[#lines + 1] = ("%-14s %s"):format(g[1], (line:gsub("`", "")))
        end
      end
    end
    if #lines == 0 then
      lulibre.notify(("the guides say nothing about '%s'"):format(word))
      return false
    end
    table.insert(lines, 1, ("No part of the guides is headed '%s'. It is mentioned here:"):format(word))
    table.insert(lines, 2, "")
    lulibre.show(lines, "help: " .. word)
    return true
  end
  local out = M.plain(found[1].text)
  if #found > 1 then
    out[#out + 1] = ""
    out[#out + 1] = "SEE ALSO"
    for i = 2, math.min(#found, 8) do out[#out + 1] = ("  :help %-12s %s"):format(found[i].guide, found[i].title:gsub("`", "")) end
  end
  lulibre.show(out, ("help: %s  (%s)"):format(word, found[1].guide))
  return true
end

-- every heading with its entries: { title=, entries = { {keys, what, word}, ... } }
local function gather()
  local sections, of_word = {}, {}
  sections[1] = { title = "Start here", entries = start(), open = true }
  for i, def in ipairs(SECTIONS) do
    sections[i + 1] = { title = def[1], entries = {} }
    for w in def[2]:gmatch("%S+") do of_word[w] = sections[i + 1] end
  end
  local rest = { title = "Other keys", entries = {} }
  -- the same command on several keys is one line
  local by_command, order = {}, {}
  for _, b in ipairs(lulibre.maps()) do
    if not b.hidden then
      local e = by_command[b.command]
      if not e then
        e = { keys = {}, command = b.command, about = b.about, visual_only = b.modes == "v" }
        by_command[b.command] = e
        order[#order + 1] = e
      end
      e.keys[#e.keys + 1] = b.keys
      if b.modes ~= "v" then e.visual_only = false end
    end
  end
  local commands = {}
  for _, c in ipairs(lulibre.commands()) do commands[c.name] = c.help end
  for _, e in ipairs(order) do
    local word = e.command:match("^%S+") or ""
    local what = e.about or ABOUT[e.command] or e.command
    local section = of_word[word] or rest
    section.entries[#section.entries + 1] = { table.concat(e.keys, "  "), what .. (e.visual_only and "   (while selecting)" or ""), word }
  end
  if #rest.entries > 0 then sections[#sections + 1] = rest end
  for _, place in ipairs(PLACES) do
    local entries = {}
    local first = true
    for line in (lulibre.place_keys(place[1]) or ""):gmatch("[^\n]+") do
      local k, what = line:match("^%s+(.-)%s%s+(.+)$")
      if not first and k then entries[#entries + 1] = { k, what, place[1] } end
      first = false
    end
    sections[#sections + 1] = { title = place[2], entries = entries }
  end
  local screens = require "lulibre.ui.keys"
  for _, screen in ipairs(SCREENS) do
    if screens.has(screen[1]) then
      local entries = {}
      for _, line in ipairs(screens.of(screen[1]):lines()) do
        local k, what = line:match("^%s+(.-)%s%s+(.+)$")
        if k then entries[#entries + 1] = { k, what, screen[1] } end
      end
      sections[#sections + 1] = { title = "Screen: " .. screen[2], entries = entries }
    end
  end
  local all = {}
  for name, help in pairs(commands) do all[#all + 1] = { ":" .. name, help, name } end
  table.sort(all, function(a, b) return a[1] < b[1] end)
  sections[#sections + 1] = { title = "Commands (type : then the name)", entries = all }
  local guides = {}
  for _, g in ipairs(M.guides) do guides[#guides + 1] = { ":help " .. g[1], g[2], g[1] } end
  sections[#sections + 1] = { title = "The guides", entries = guides }
  return sections
end

--- Open help, or the guides on a word.
-- @tparam[opt] string args a word: what the guides say about it
function M.run(args)
  if type(args) == "string" and args:match("%S") then return M.topic(args) end
  local sections = gather()
  local query -- what is being searched for, folded; nil when nothing is
  local at    -- row -> { section, entry }
  local function build()
    local rows = {}
    at = {}
    for _, s in ipairs(sections) do
      local shown = {}
      for _, e in ipairs(s.entries) do
        if not query or lulibre.fold(e[1] .. " " .. e[2] .. " " .. (e[3] or "")):find(query, 1, true) then shown[#shown + 1] = e end
      end
      if not query or #shown > 0 then
        local open = s.open or query ~= nil
        rows[#rows + 1] = { ("%s%s   (%d)"):format(open and "▾ " or "▸ ", s.title, #shown), style = "head" }
        at[#rows] = { s }
        if open then
          for _, e in ipairs(shown) do
            rows[#rows + 1] = { "    " .. e[1], e[2] }
            at[#rows] = { s, e }
          end
        end
      end
    end
    return rows
  end
  local function title()
    return query and ("help   keys and commands matching '%s'"):format(query) or "help   keys, by what they are for"
  end
  local p <close> = require("lulibre.ui.panels").open("help", {
    title = title(), help = keys:hint("toggle", "find", "topic", "all"), side = "left", width = 0.62, keys = keys:own(),
    columns = { { "", 30 }, { "", -1 } }, rows = build(),
  })
  if not p then return end
  local function refresh(keep)
    p:rows(build())
    p:title(title())
    for i, a in ipairs(at) do
      if a[1] == keep and not a[2] then
        p:cursor(i)
        break
      end
    end
  end
  while true do
    local key, row = p:wait()
    if not key then return end
    local a = at[row]
    local act = keys:action(key)
    if act == "help" then
      keys:show("help")
    elseif act == "toggle" or act == "open" or act == "close" then
      if a and not a[2] then
        if act == "toggle" then a[1].open = not a[1].open else a[1].open = act == "open" end
        refresh(a[1])
      elseif a and act == "close" then
        a[1].open = false
        refresh(a[1])
      elseif a and act == "toggle" then
        M.topic(a[2][3]) -- Enter on a key: what the guides say about it
      end
    elseif act == "topic" then
      if a and a[2] then M.topic(a[2][3]) elseif a then M.topic((a[1].title:match("^Screen: (.+)$") or a[1].title):match("%a+")) end
    elseif act == "all" or act == "none" then
      for _, s in ipairs(sections) do s.open = act == "all" end
      refresh(a and a[1])
    elseif act == "find" then
      local text = lulibre.input { prompt = "search the keys and commands: ", on_change = function(typed)
        query = typed ~= "" and lulibre.fold(typed) or nil
        p:rows(build())
        p:title(title())
      end }
      if not text or text == "" then query = nil end
      refresh()
      if query then p:cursor(2) end
    elseif act == "clear" then
      query = nil
      refresh(a and a[1])
    end
  end
end

return M
