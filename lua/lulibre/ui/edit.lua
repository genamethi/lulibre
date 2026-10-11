-- The edit form: the fields of the selected book or books, each with ranked
-- suggestions. Nothing is written until w.
local edit = require "lulibre.edit"
local junk = require "lulibre.junk"
local suggest = require "lulibre.suggest"

local M = {}

local keys = require("lulibre.ui.keys").of("edit")

local function is_gap(field, value)
  if value == "" then return true end
  if field == "title" then return junk.title(value) or not value:find("%s") end
  return false
end

--- Open the form. args.ids: the books to edit; otherwise the selection.
function M.run(args)
  local ids = type(args) == "table" and args.ids or lulibre.selection()
  if #ids == 0 then
    lulibre.notify("no book selected", "error")
    return
  end
  local books = {}
  for i, id in ipairs(ids) do books[i] = lulibre.book(id) end

  local new, from = {}, {}       -- field -> pending value, and where it came from
  local options, at = {}, {}     -- field -> suggestions, and the one last shown

  local function now(field)
    local first = edit.current(books[1], field)
    for i = 2, #books do
      if edit.current(books[i], field) ~= first then return nil end
    end
    return first
  end

  local function suggestions(field)
    if not options[field] then
      lulibre.progress("reading the files…")
      options[field] = suggest.for_field(field, ids)
      lulibre.progress(nil)
    end
    return options[field]
  end

  local function rows()
    local out = {}
    for i, field in ipairs(edit.fields) do
      local cur = now(field)
      out[i] = { field, cur == nil and ("(%d different values)"):format(#books) or cur,
        new[field] == "" and edit.BLANK or new[field] or "", from[field] or "", style = new[field] and "ok" or nil }
    end
    return out
  end

  local title = #books == 1 and ("edit  %d  %s"):format(ids[1], books[1].title or "")
    or ("edit  %d books"):format(#books)
  local p <close> = lulibre.panel {
    title = title, help = keys:hint("edit", "suggest", "clear", "write"), height = 0.38,
    columns = { { "Field", 12 }, { "Now", -3 }, { "New", -3 }, { "From", 26 } },
    rows = rows(),
  }

  while true do
    local key, row = p:wait()
    if not key then return end
    local field = edit.fields[row]
    local act = keys:action(key)
    if act == "write" then break end
    if act == "help" then
      keys:show("edit")
    elseif field and act == "edit" then
      local list = edit.separator[field]
      local v = lulibre.input {
        prompt = field .. (list and #books > 1 and " (+add, -remove, or a new value): " or ": "),
        default = new[field] or now(field) or "",
        suggestions = suggestions(field),
        separator = list,
      }
      if v then
        -- catch a malformed date or identifier now, not at write time
        local ok, err = true, nil
        if not v:find("^%s*[+-]") then ok, err = pcall(edit.resolve, books[1], field, "set", v) end
        if ok then new[field], from[field] = v, "typed"
        else lulibre.notify(tostring(err), "error") end
      end
    elseif field and act == "suggest" then
      -- step through what the files and related books suggest
      local picks = {}
      for _, s in ipairs(suggestions(field)) do
        if s.kind ~= "library" then picks[#picks + 1] = s end
      end
      if #picks == 0 then
        lulibre.notify(("nothing to suggest for %s; %s to type a value"):format(field, keys:key("edit") or "edit"))
      else
        at[field] = (at[field] or 0) % #picks + 1
        new[field] = picks[at[field]].text
        from[field] = ("%d/%d  %s"):format(at[field], #picks, picks[at[field]].detail or "")
      end
    elseif field and act == "revert" then
      new[field], from[field], at[field] = nil, nil, nil
    elseif field and act == "clear" then
      if now(field) == "" then
        new[field], from[field], at[field] = nil, nil, nil
        lulibre.notify(field .. " is empty already")
      else
        new[field], from[field], at[field] = "", "cleared", nil
      end
    elseif act == "fill" then
      -- take the best suggestion from the files for every field that is empty
      local filled = 0
      for _, f in ipairs(edit.fields) do
        local cur = now(f)
        if not new[f] and cur ~= nil and is_gap(f, cur) then
          for _, s in ipairs(suggestions(f)) do
            if s.kind == "candidate" then
              new[f], from[f] = s.text, s.detail
              filled = filled + 1
              break
            end
          end
        end
      end
      lulibre.notify(filled > 0 and ("filled %d field%s; %s writes them"):format(filled, filled == 1 and "" or "s",
        keys:key("write") or ":w") or "no gaps the files could fill")
    end
    p:rows(rows())
  end

  local changes = {}
  for _, id in ipairs(ids) do
    for field, text in pairs(new) do
      for _, c in ipairs(edit.typed(id, field, text)) do changes[#changes + 1] = c end
    end
  end
  p:close()
  if #changes == 0 then
    lulibre.notify("nothing to write")
    return
  end
  local r = edit.apply(changes, { label = #ids == 1 and "edit" or ("edit of %d books"):format(#ids) })
  lulibre.notify(edit.summary(r), #r.failed > 0 and "error" or nil)
end

return M
