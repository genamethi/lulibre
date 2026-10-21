--- Pattern capture: type a pattern, see what it pulls out of each selected
-- book, then apply the captured fields, mark the books that match, or keep
-- the pattern as a named rule.
--
-- @module lulibre.ui.capture
-- @usage
-- require("lulibre.ui.capture").run()   -- as :capture, gc does
local edit = require "lulibre.edit"
local json = require "lulibre.json"
local proposals = require "lulibre.proposals"
local template = require "lulibre.template"

local M = {}

local keys = require("lulibre.ui.keys").of("capture")

local function basename(path)
  return ((path or ""):gsub("^.*/", ""):gsub("%.%w+$", ""))
end

--- Where the text a pattern runs against comes from.
M.sources = {
  { name = "filename", get = function(b)
      local f = lulibre.files(b.id)[1]
      return f and basename(f.path) or ""
    end },
  { name = "title", get = function(b) return b.title or "" end },
  { name = "authors", get = function(b) return b.author or "" end },
  { name = "embedded title", get = function(b)
      local f = lulibre.files(b.id)[1]
      return f and f.title or ""
    end },
  { name = "embedded author", get = function(b)
      local f = lulibre.files(b.id)[1]
      return f and f.author or ""
    end },
  { name = "first line", get = function(b)
      local l = lulibre.lines(b.id, 1)[1]
      return l and l.text or ""
    end },
  { name = "first three lines", get = function(b)
      local out = {}
      for i, l in ipairs(lulibre.lines(b.id, 1)) do
        if i > 3 then break end
        out[i] = l.text
      end
      return table.concat(out, " | ")
    end },
}

local function source_named(name)
  for _, s in ipairs(M.sources) do
    if s.name == name then return s end
  end
  return M.sources[1]
end

--- Saved rules: { name = { source=, spec= }, ... }
-- @treturn table
function M.rules()
  local out = {}
  for _, row in ipairs(lulibre.store("SELECT key, value FROM kv WHERE key LIKE 'rule:%' ORDER BY key")) do
    local ok, rule = pcall(json.decode, row.value)
    if ok and type(rule) == "table" then out[row.key:sub(6)] = rule end
  end
  return out
end

--- Keep a rule under a name, for the next time.
-- @tparam string name
-- @tparam string source what it is matched against
-- @tparam string spec the pattern
function M.save_rule(name, source, spec)
  lulibre.store("INSERT OR REPLACE INTO kv(key, value) VALUES(?, ?)", "rule:" .. name,
    json.encode({ source = source, spec = spec }))
end

--- Run a pattern over books without the screen: returns
-- { { id=, text=, fields={name=value} or nil }, ... }.
-- @tparam {integer,...} ids
-- @tparam string source_name what is matched: "filename", "title", "authors", "embedded title", "first line" ...
-- @tparam string spec the pattern
-- @treturn {table,...}
function M.capture(ids, source_name, spec)
  local compiled, err = template.compile(spec)
  if not compiled then return nil, err end
  local src = source_named(source_name)
  local out = {}
  for i, id in ipairs(ids) do
    local b = lulibre.book(id)
    local text = b and src.get(b) or ""
    out[i] = { id = id, text = text, fields = template.match(compiled, text) }
  end
  return out, compiled
end

--- The changes a capture stands for.
local function changes_of(results)
  local out = {}
  for _, r in ipairs(results) do
    for name, value in pairs(r.fields or {}) do
      -- file-name style values: underscores stood in for spaces
      if not value:find(" ") then value = value:gsub("_", " ") end
      local field, v = template.canonical(name, value)
      out[#out + 1] = { id = r.id, field = field, value = v,
        op = (field == "identifiers" or field == "tags") and "add" or "set" }
    end
  end
  return out
end

--- Open on the selected books.
-- @tparam[opt] string args a pattern to start with
function M.run(args)
  local ids = lulibre.selection()
  if #ids == 0 then
    lulibre.notify("no book selected", "error")
    return
  end
  local source, spec = "title", (args and args ~= "") and args or ""
  local results, compiled, problem

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
    local rows, hits = {}, 0
    local src = source_named(source)
    for i, id in ipairs(ids) do
      local r = results and results[i]
      local text = r and r.text
      if not text then
        local b = lulibre.book(id)
        text = b and src.get(b) or ""
      end
      local row = { text, id = id }
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
      or spec == "" and ("capture  %d books  (p to type a pattern such as %%author%% - %%title%%)"):format(#ids)
      or ("capture  %d of %d match  %s"):format(hits, #ids, spec)
    return cols, rows, title
  end

  recompute()
  local cols, rows, title = view()
  local p <close> = require("lulibre.ui.panels").open("capture", { title = title, help = keys:hint("pattern", "source", "write", "propose"), follow = true, columns = cols, rows = rows, height = 0.45,
    keys = keys:own(), pass = require("lulibre.ui.panels").PASS })
  if not p then return end
  local function refresh()
    cols, rows, title = view()
    p:columns(cols)
    p:rows(rows)
    p:title(title)
  end

  while true do
    local key = p:wait()
    if not key then return end
    local act = keys:action(key)
    if act == "help" then
      keys:show("capture")
    elseif act == "pattern" then
      local saved, sugg = M.rules(), {}
      for name, rule in pairs(saved) do sugg[#sugg + 1] = { text = rule.spec, detail = name } end
      sugg[#sugg + 1] = { text = "%author% - %title%", detail = "example" }
      sugg[#sugg + 1] = { text = "%title% - %author% - %year%", detail = "example" }
      sugg[#sugg + 1] = { text = "^(.-)%s*%((%d%d%d%d)%)$ => title, year", detail = "example" }
      local before = spec
      local v = lulibre.input {
        prompt = "pattern: ", default = spec, suggestions = sugg,
        on_change = function(text) -- the table follows the typing
          spec = text
          recompute()
          refresh()
        end,
      }
      spec = v or before
      recompute()
    elseif act == "source" then
      local names = {}
      for i, s in ipairs(M.sources) do names[i] = s.name end
      local pick = lulibre.pick(names, { title = "run the pattern against" })
      if pick then
        source = pick
        recompute()
      end
    elseif act == "load" then
      local saved, names = M.rules(), {}
      for name, rule in pairs(saved) do names[#names + 1] = { text = name, detail = rule.spec } end
      if #names == 0 then
        lulibre.notify(("no saved rules yet: %s saves the current pattern"):format(keys:key("save") or "save"))
      else
        local pick = lulibre.pick(names, { title = "rules" })
        if pick then
          source, spec = saved[pick.text].source, saved[pick.text].spec
          recompute()
        end
      end
    elseif act == "save" and compiled then
      local name = lulibre.input { prompt = "save this pattern as: " }
      if name and name ~= "" then
        M.save_rule(name, source, spec)
        lulibre.notify("saved rule " .. name)
      end
    elseif act == "mark" and results then
      local n = 0
      for _, r in ipairs(results) do
        lulibre.mark(r.id, r.fields ~= nil)
        if r.fields then n = n + 1 end
      end
      lulibre.notify(("%d marked"):format(n))
    elseif (act == "write" or act == "propose") and results then
      local changes = changes_of(results)
      if #changes == 0 then
        lulibre.notify("the pattern matches nothing here")
      elseif act == "propose" then
        local n = 0
        for _, c in ipairs(changes) do
          if proposals.add(c.id, c.field, c.value, { op = c.op, source = "capture: " .. spec, confidence = 0.7 }) then
            n = n + 1
          end
        end
        lulibre.notify(("%d proposals added.%s"):format(n, require("lulibre.proposals").to_review(" ")))
      else
        p:close()
        local r = edit.apply(changes, { label = "capture: " .. spec })
        lulibre.notify(edit.summary(r), #r.failed > 0 and "error" or nil)
        return
      end
    end
    refresh()
  end
end

return M
