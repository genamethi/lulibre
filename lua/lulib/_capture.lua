--- :capture: type a pattern and see what it pulls out of each book, then
-- propose what it captured, adding it to the current review, or mark the
-- books it matches. A pattern is a template, `%author% - %title% (%year%)`, or a
-- Lua pattern and the names of its captures, `^(.-) %((%d+)%)$ => title, year`
-- (lulib._template). It can be saved under a name.
--
-- The screen "capture": p types the pattern, s says what it runs against, l
-- loads a saved one, S saves it, m marks the books it matches, a proposes what it
-- captured; q closes. keymap.set("capture", key, action) rebinds them.
--
-- @library lulib._capture
local bookman = require "bookman"
local kept = require "lulib._kept"
local sql = require "sql"
local sqlite3 = require "lsqlite3"
local template = require "lulib._template"
local txt = require "txt"
local wit = require "wit"

local M = {}

local db
local function run(query, ...)
  db = db or sql.open(setman.get("path.witdb"), sqlite3.OPEN_READWRITE)
  return sql.run(db, query, ...)
end

local function file_of(book) return kept.file_of(book) end

local function first_lines(book, n)
  local t <close> = txt.of(book)
  if not t then return "" end
  local out = {}
  for i = 1, math.min(n, #t) do out[i] = t:line(i).text end
  return table.concat(out, " | ")
end

--- What a pattern can run against: `{ name=, get = function(book) }`.
M.sources = {
  { name = "filename", get = function(book)
      local f = file_of(book)
      return f and (f.path:gsub("^.*/", ""):gsub("%.%w+$", "")) or ""
    end },
  { name = "title", get = function(book) return bookman.get(book, "title") or "" end },
  { name = "authors", get = function(book) return bookman.get(book, "authors") or "" end },
  { name = "embedded title", get = function(book) local f = file_of(book) return f and f.title or "" end },
  { name = "embedded author", get = function(book) local f = file_of(book) return f and f.author or "" end },
  { name = "first line", get = function(book) return first_lines(book, 1) end },
  { name = "first three lines", get = function(book) return first_lines(book, 3) end },
}

local function source_named(name)
  for _, s in ipairs(M.sources) do
    if s.name == name then return s end
  end
  return M.sources[1]
end

--- The saved patterns: `{ {name=, source=, spec=}, ... }`.
function M.rules()
  return run("SELECT name, source, spec FROM capture_rules ORDER BY name")
end

--- Saves a pattern under a name.
function M.save_rule(name, source, spec)
  run("INSERT OR REPLACE INTO capture_rules(name, source, spec) VALUES (?, ?, ?)", name, source, spec)
end

--- Runs a pattern over books: `{ {id=, text=, fields=}, ... }`, and the
-- compiled pattern; nil and why if it can't be read.
-- @tparam {integer,...} ids
-- @tparam string source_name
-- @tparam string spec
function M.capture(ids, source_name, spec)
  local compiled, err = template.compile(spec)
  if not compiled then return nil, err end
  local src, out = source_named(source_name), {}
  for i, id in ipairs(ids) do
    local text = src.get(id)
    out[i] = { id = id, text = text, fields = template.match(compiled, text) }
  end
  return out, compiled
end

--- Proposes what a capture's results give; how many.
function M.propose(results, spec)
  local n = 0
  for _, r in ipairs(results) do
    for name, value in pairs(r.fields or {}) do
      -- file-name style values: underscores stood in for spaces
      if not value:find(" ") then value = value:gsub("_", " ") end
      local field, v = template.canonical(name, value)
      local kind, id = tostring(v):match("^([%w_-]+):(.+)$")
      if field == "identifiers" and kind then field, v = "identifier:" .. kind, id end
      wit.add(r.id, { field = field, value = v, source = "capture: " .. spec })
      n = n + 1
    end
  end
  return n
end

scrnman.create("capture", {
  actions = {
    { "pattern", "p", "type the pattern" },
    { "source", "s", "say what the pattern runs against" },
    { "load", "l", "load a saved pattern" },
    { "save", "S", "save the pattern under a name" },
    { "mark", "m", "mark the books it matches" },
    { "propose", "a", "propose what it captured, in the current review" },
  },
  hint = { "pattern", "source", "propose" },
})

--- Opens the screen on the books, and returns when it closes.
-- @tparam {integer,...} ids
-- @tparam[opt] string spec a pattern to start with
function M.open(ids, spec)
  if #ids == 0 then return uiman.notify("no book selected", "error") end
  local source, results, compiled, problem = "title", nil, nil, nil
  spec = spec or ""
  local function recompute()
    results, compiled, problem = nil, nil, nil
    if spec ~= "" then
      local r, c = M.capture(ids, source, spec)
      if r then results, compiled = r, c else problem = c end
    end
  end
  local function view()
    local cols = { { source, -3 } }
    local fields = compiled and compiled.fields or {}
    for _, f in ipairs(fields) do cols[#cols + 1] = { f, -2 } end
    local rows, hits, src = {}, 0, source_named(source)
    for i, id in ipairs(ids) do
      local r = results and results[i]
      local row = { r and r.text or src.get(id), id = id }
      if r and r.fields then
        hits = hits + 1
        for _, f in ipairs(fields) do row[#row + 1] = r.fields[f] or "" end
        row.style = "ok"
      elseif results then
        row.style = "dim"
      end
      rows[i] = row
    end
    local title = problem and ("capture  " .. problem)
      or spec == "" and ("capture  %d books  (p types a pattern such as %%author%% - %%title%%)"):format(#ids)
      or ("capture  %d of %d match  %s"):format(hits, #ids, spec)
    return cols, rows, title
  end
  recompute()
  local cols, rows, title = view()
  local p <close> = uiman.panel { title = title, screen = "capture", columns = cols, rows = rows, follow = true }
  local function refresh()
    cols, rows, title = view()
    p:columns(cols)
    p:rows(rows)
    p:title(title)
  end
  while true do
    local act = p:wait()
    if not act then return end
    if act == "pattern" then
      local before = spec
      local v = uiman.input {
        prompt = "pattern: ", default = spec,
        suggestions = { { text = "%author% - %title%", detail = "example" },
                        { text = "%title% - %author% - %year%", detail = "example" },
                        { text = "^(.-)%s*%((%d%d%d%d)%)$ => title, year", detail = "example" } },
        on_change = function(text)
          spec = text
          recompute()
          refresh()
        end,
      }
      spec = v or before
      recompute()
    elseif act == "source" then
      local list = {}
      for i, s in ipairs(M.sources) do list[i] = s.name end
      local pick = uiman.pick(list, { title = "run the pattern against" })
      if pick then
        source = pick
        recompute()
      end
    elseif act == "load" then
      local rules, list = M.rules(), {}
      for i, r in ipairs(rules) do list[i] = { text = r.name, detail = r.spec } end
      if #list == 0 then
        uiman.notify("no saved patterns yet")
      else
        local _, i = uiman.pick(list, { title = "patterns" })
        if i then
          source, spec = rules[i].source, rules[i].spec
          recompute()
        end
      end
    elseif act == "save" and compiled then
      local name = uiman.input { prompt = "save this pattern as: " }
      if name and name ~= "" then
        M.save_rule(name, source, spec)
        uiman.notify("saved " .. name)
      end
    elseif act == "mark" and results then
      local n = 0
      for _, r in ipairs(results) do
        uiman.mark(r.id, r.fields ~= nil)
        if r.fields then n = n + 1 end
      end
      uiman.notify(("%d marked"):format(n))
    elseif act == "propose" and results then
      local n = M.propose(results, spec)
      uiman.notify(n == 0 and "the pattern matches none of the books"
                   or ("%d proposal%s in the review"):format(n, n == 1 and "" or "s"))
    end
    refresh()
  end
end

return M
