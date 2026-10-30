--- uiman.list and uiman.form, written in Lua on uiman.panel: a sequence
-- shown one item to a row, and a record one field to a row. Each waits
-- until it closes, and reads its items again after each key it handles
-- and each event it refreshes on.
--
--     scrnman.create("review", { actions = { { "accept", "a", "accept the proposal" } }, hint = { "accept" } })
--     uiman.list {
--       title = "review", screen = "review", columns = { "Field", "Record", "Proposed" }, follow = true,
--       items = function() return entries(books) end,
--       row = function(e) return { e.field, e.now, e.value, id = e.book } end,
--       actions = { accept = function(e) return wit.accept(e.id) end },
--       refresh = { "records_changed" },
--     }
--
--     uiman.form {
--       title = "settings",
--       record = function() return { pages = setman.get("pages"), ocr = setman.get("ocr") } end,
--       fields = { "pages", { "ocr", "OCR" } },
--       edit = function(field, value) setman.set(field, value) end,
--     }
--
-- @library lulib._uiman
local M = {}
local own, get = require "lulib._expose" (M) -- internal functions (expose_modules)

-- the options uiman.panel takes as they are
local passed = { "title", "help", "columns", "follow", "preview", "height", "side", "focus", "dialog", "pass", "screen" }

-- a form's own screen, for a form given none: e and Enter edit
scrnman.create("form", { actions = { { "edit", "e <CR>", "edit the field under the cursor" } }, hint = { "edit" } })

-- items: a list, an iter, or a function giving either, read again each time
function own.read(items)
  if type(items) == "function" then items = items() end
  if type(items) == "table" and items.totable then items = items:totable() end
  return items or {}
end

-- a key's action, its error shown: it raised, or returned nil and why
function own.act(fn, ...)
  local ok, r, why = pcall(fn, ...)
  if not ok then uiman.notify(tostring(r), "error")
  elseif r == nil and why then uiman.notify(tostring(why), "error") end
end

--- Shows a sequence, one item to a row, and waits until it is closed.
-- @tparam table o `{ items=, row=, screen=, actions=, refresh= }` and
-- uiman.panel's title, help, columns, follow, preview, height, side,
-- focus, dialog and pass. items: a list, an iter, or a function giving one, read again after
-- each key and each refresh; row(item): its cells, with `id=` (the book)
-- and `style=` as a panel's rows have them (by default the item, a row
-- already, or the item as text);
-- screen: the screen it is (scrnman.create), whose actions its keys mean;
-- actions: `{ [action] = function(item, i) }`, what one of the screen's
-- actions does to the item under the cursor, whose error (raised, or nil
-- and why) is shown;
-- refresh: event kinds that read the items again, as a list, or
-- `{ [kind] = function(ev) }` to run first. Without the interface
-- (lulibre run), the rows are printed, their cells two spaces apart.
function M.list(o)
  local items = get("read")(o.items)
  local function rows()
    local out = {}
    for i, item in ipairs(items) do
      out[i] = o.row and o.row(item) or type(item) == "table" and item or { tostring(item) }
    end
    return out
  end
  if lulib.headless then
    for _, r in ipairs(rows()) do print(table.concat(r, "  ")) end
    return
  end
  local spec = { rows = rows() }
  for _, k in ipairs(passed) do spec[k] = o[k] end
  if not spec.columns then -- untitled, as many as the widest row has cells: a panel draws its rows in columns
    local n = 1
    for _, r in ipairs(spec.rows) do n = math.max(n, #r) end
    spec.columns = {}
    for c = 1, n do spec.columns[c] = "" end
  end
  local p <close> = uiman.panel(spec)
  local ids = {}
  local _ <close> = setmetatable({}, { __close = function() for _, id in ipairs(ids) do evman.rm(id) end end })
  for k, v in pairs(o.refresh or {}) do
    -- a kind in the list, or a kind and its function
    local kind, fn = k, v
    if type(k) == "number" then kind, fn = v, nil end
    ids[#ids + 1] = evman.add(kind, function(ev)
      if fn then get("act")(fn, ev) end
      p:send("<Refresh>")
    end)
  end
  while true do
    local action, i = p:wait()
    if not action then break end
    local fn = (o.actions or {})[action]
    if fn and items[i] ~= nil then get("act")(fn, items[i], i) end
    items = get("read")(o.items)
    p:rows(rows())
  end
end

-- a value as one line: a list joined by commas
function own.shown(v)
  if type(v) == "table" then return table.concat(v, ", ") end
  return v == nil and "" or tostring(v)
end

--- Shows a record, one field to a row, and waits until it is closed: e or
-- Enter edits the field under the cursor.
-- @tparam table o `{ record=, fields=, edit=, screen=, actions=, refresh= }` and the
-- options uiman.list passes to the panel. record: a table, or a function
-- giving it, read again as list's items are; fields: the fields shown, in
-- order, each a name or `{ name, label }` (by default every field, by
-- name); edit(field, value, record): takes an edited value (nil and why
-- refuses it), on the screen's action edit (the screen "form" when none is
-- given: e and Enter); actions: `{ [action] = function(field, record) }`.
function M.form(o)
  local function record() return (type(o.record) == "function" and o.record() or o.record) or {} end
  local function fields()
    local rec, out = record(), {}
    local list = o.fields
    if not list then
      list = {}
      for name in pairs(rec) do list[#list + 1] = name end
      table.sort(list)
    end
    for _, f in ipairs(list) do
      local name, label = f, f
      if type(f) == "table" then name, label = f[1], f[2] or f[1] end
      out[#out + 1] = { name = name, label = label, value = rec[name], record = rec }
    end
    return out
  end
  local actions = {}
  for name, fn in pairs(o.actions or {}) do actions[name] = function(f) return fn(f.name, f.record) end end
  if o.edit and not actions.edit then
    actions.edit = function(f)
      local v = uiman.input { prompt = f.label .. ": ", default = get("shown")(f.value) }
      if v ~= nil then return o.edit(f.name, v, f.record) end
      return true
    end
  end
  local spec = {}
  for k, v in pairs(o) do spec[k] = v end
  spec.screen = o.screen or "form"
  spec.columns = o.columns or { { "Field", 16 }, "Value" }
  spec.items, spec.row, spec.actions = fields, function(f) return { f.label, get("shown")(f.value) } end, actions
  return M.list(spec)
end

uiman.list, uiman.form = M.list, M.form

return M
