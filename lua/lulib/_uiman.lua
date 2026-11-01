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

-- One of each screen at a time. A screen opened again while it is open goes to the
-- open one, so nothing it holds is lost and two of them are never up by chance. `:new
-- COMMAND` opens another all the same.
local newest = setmetatable({}, { __mode = "v" }) -- the screen's name -> the last one opened
local again = {} -- task id -> true: this task may open one that is open
local panel = uiman.panel

local function alive(q)
  local ok, open = pcall(q.is_open, q)
  return ok and open
end

--- uiman.panel, but for a screen open already (not one of its views, nor a dialog),
-- when it moves the cursor to the open one, says so, and returns nil.
function uiman.panel(spec)
  local name = not spec.view and not spec.dialog and spec.screen
  local open = name and newest[name]
  if open and alive(open) and not again[taskman.self()] then
    open:focus()
    uiman.notify(("%s is already open, and the cursor is in it (:new %s opens another)"):format(name, name))
    return nil
  end
  local p = panel(spec)
  if name then newest[name] = p end
  return p
end

-- what the commands made in Lua do, by name, for :new
local commands, create = {}, cmdman.create
function cmdman.create(name, fn, o)
  commands[name] = fn
  return create(name, fn, o)
end

--- Runs a command made in Lua so that it may open a second copy of a screen that
-- is already open. Returns true, or nil and why.
-- @tparam string name
-- @tparam table o what the command is given: `{ args=, selection= }`
function uiman.again(name, o)
  local fn = commands[name]
  if not fn then return nil, "no command " .. name .. " to open another of" end
  local task = taskman.self()
  again[task] = true
  local ok, err = pcall(fn, o)
  again[task] = nil
  if not ok then return nil, err end
  return true
end

-- the options uiman.panel takes as they are
local passed = { "title", "help", "columns", "follow", "preview", "height", "side", "focus", "dialog", "pass", "screen", "form", "view" }

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
-- uiman.panel's title (or a function giving it, read again with the items),
-- help, columns, follow, preview, height, side, focus, dialog and pass. items: a list, an iter, or a function giving one, read again after
-- each key and each refresh; row(item): its cells, with `id=` (the book)
-- and `style=` as a panel's rows have them (by default the item, a row
-- already, or the item as text);
-- screen: the screen it is (scrnman.create), whose actions its keys mean;
-- actions: `{ [action] = function(item, i) }`, what one of the screen's
-- actions does to the item under the cursor, whose error (raised, or nil
-- and why) is shown;
-- band: `{ view=, title=, columns=, rows = function(item, i) }`, a view of the
-- screen (scrnman.create's views) that says more of the item under the cursor;
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
  local title = spec.title
  if type(title) == "function" then spec.title = title() end
  if not spec.columns then -- untitled, as many as the widest row has cells: a panel draws its rows in columns
    local n = 1
    for _, r in ipairs(spec.rows) do n = math.max(n, #r) end
    spec.columns = {}
    for c = 1, n do spec.columns[c] = "" end
  end
  if o.band then spec.moves = true end
  local p <close> = uiman.panel(spec)
  if not p then return end
  -- a view of the screen that says more of the item under the cursor
  local band <close> = o.band and uiman.panel {
    title = o.band.title or "", screen = o.screen, view = o.band.view, focus = false,
    columns = o.band.columns or { { "", 12 }, { "", 0 } },
    rows = items[1] ~= nil and o.band.rows(items[1], 1) or {},
  } or nil
  local function about(i)
    if band and items[i] ~= nil then
      local ok, r = pcall(o.band.rows, items[i], i)
      band:rows(ok and r or { { "", tostring(r), style = "error" } })
    end
  end
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
    local action, i, value = p:wait()
    if not action then break end
    if action ~= "<Move>" then
      local fn = (o.actions or {})[action]
      if fn and items[i] ~= nil then get("act")(fn, items[i], i, value) end
      items = get("read")(o.items)
      p:rows(rows())
      if type(title) == "function" then p:title(title()) end
    end
    about(i or p:cursor() or 1)
  end
end

-- a value as one line: a list joined by commas
function own.shown(v)
  if type(v) == "table" then return table.concat(v, ", ") end
  return v == nil and "" or tostring(v)
end

scrnman.create("dialog", {
  actions = {
    { "toggle", "<Space>", "tick or untick a box; step through a choice" },
    { "change", "<CR>", "tick a box, step through a choice, type a value, or do what the line says" },
    { "next", "l", "the next of a choice" },
    { "prev", "h", "the one before" },
    { "go", "w", "do the first thing the dialog offers, with things as they are set" },
  },
  hint = { "toggle", "change", "go" },
})

-- uiman.form with sections: boxes, choices, typed values and actions under
-- headings; returns the action chosen and the values, nil if it is closed
function own.dialog(spec)
  local at -- row -> item
  local function build()
    local rows = {}
    at = {}
    for _, section in ipairs(spec.sections) do
      if section.title and section.title ~= "" then
        rows[#rows + 1] = { "── " .. section.title .. " " .. ("─"):rep(math.max(4, 60 - #section.title)), style = "head" }
      end
      for _, item in ipairs(section.items) do
        local mark, value = "", ""
        if item.kind == "check" then mark = item.value and not item.off and "[x]" or "[ ]"
        elseif item.kind == "choice" then mark, value = " ‹›", tostring(item.choices[item.value] or "")
        elseif item.kind == "number" or item.kind == "text" then mark, value = "  =", tostring(item.value or "")
        elseif item.kind == "action" then mark = "  ▶" end
        if item.kind == "note" then
          rows[#rows + 1] = { "      " .. item.label, style = "note" }
        else
          rows[#rows + 1] = { mark, item.label, item.off and ("(%s)"):format(item.off) or value ~= "" and value or (item.hint or ""),
                              style = item.off and "dim" or item.kind == "action" and "accent" or nil }
        end
        at[#rows] = item
      end
    end
    return rows
  end
  local p <close> = uiman.panel {
    title = spec.title or "", help = spec.help, screen = spec.screen or "dialog", height = spec.height or 0.7, dialog = true,
    columns = { { "", 4 }, { "", spec.label_width or 44 }, { "", -1 } }, rows = build(),
  }
  -- start on the first thing that can be changed
  local rows = 0
  for i in pairs(at) do rows = math.max(rows, i) end
  for i = 1, rows do
    if at[i] and at[i].kind ~= "note" and not at[i].off then
      p:cursor(i)
      break
    end
  end
  local function values()
    local v = {}
    for _, section in ipairs(spec.sections) do
      for _, item in ipairs(section.items) do
        if item.id and item.kind ~= "action" and item.kind ~= "note" then
          if item.off and item.kind == "check" then v[item.id] = false
          else v[item.id] = item.value end
        end
      end
    end
    return v
  end
  local function redraw(row)
    p:rows(build())
    if row then p:cursor(row) end
  end
  while true do
    local act, row = p:wait()
    if not act then return nil end
    local item = at[row]
    if act == "go" then
      for _, section in ipairs(spec.sections) do
        for _, it in ipairs(section.items) do
          if it.kind == "action" and not it.off then return it.id, values() end
        end
      end
    elseif item and item.off then
      uiman.notify(item.off)
    elseif item and (act == "toggle" or act == "change" or act == "next" or act == "prev") then
      if item.kind == "check" and act ~= "next" and act ~= "prev" then
        item.value = not item.value
        redraw(row)
      elseif item.kind == "choice" then
        item.value = ((item.value or 1) - 1 + (act == "prev" and -1 or 1)) % #item.choices + 1
        redraw(row)
      elseif (item.kind == "number" or item.kind == "text") and act == "change" then
        local typed = uiman.input { prompt = item.label .. ": ", default = tostring(item.value or "") }
        if typed then
          if item.kind == "number" then
            local n = tonumber(typed)
            if n then item.value = n else uiman.notify(("'%s' is not a number"):format(typed), "error") end
          else
            item.value = typed
          end
          redraw(row)
        end
      elseif item.kind == "action" and act == "change" then
        return item.id, values()
      end
    end
  end
end

--- Shows a record, one field to a row, and waits until it is closed: a
-- form of lulibre's (uiman.panel's form), whose keys are the place form's:
-- edit (e or Enter) asks for the field's value on the line.
-- @tparam table o `{ record=, fields=, edit=, screen=, actions=, refresh= }` and the
-- options uiman.list passes to the panel. record: a table, or a function
-- giving it, read again as list's items are; fields: the fields shown, in
-- order, each a name or `{ name, label }` (by default every field, by
-- name); edit(field, value, record): takes an edited value (nil and why
-- refuses it); screen: a screen whose actions it has too, `actions`
-- saying what they do: `{ [action] = function(field, record) }`.
-- With `sections` it is a dialog: `{ title=, sections = { {title=, items = {
-- {id=, kind=, label=, value=, choices=, hint=, off=}, ... }}, ... }, height=,
-- label_width= }`, kind check, choice, number, text, action or note; off says
-- why an item can't be changed. It returns the id of the action chosen and each
-- item's value by id, or nil when closed.
function M.form(o)
  if o.sections then return get("dialog")(o) end
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
    actions.edit = function(f, _, value) return o.edit(f.name, value, f.record) end
  end
  local spec = {}
  for k, v in pairs(o) do spec[k] = v end
  spec.form = true
  spec.items, spec.row, spec.actions = fields, function(f) return { f.label, get("shown")(f.value) } end, actions
  return M.list(spec)
end

uiman.list, uiman.form = M.list, M.form

return M
