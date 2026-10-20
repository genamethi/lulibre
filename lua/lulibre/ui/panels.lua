-- What the screens built on panels share.
local M = {}

-- The global commands whose keys still work with the cursor in a screen that
-- follows the list: paging and scrolling the preview, the page as an image
-- (P), copying (yy, yb ...), the console, and the tabs along the top (1 2 3:
-- source, config), so a screen left open is there again on coming back.
M.PASS = "preview yank console source config"

--- Lines for a screen's ? overlay saying which of the list's keys work there
-- too, by the keys they are on now.
function M.also()
  return {
    "",
    "ALSO HERE, as in the list",
    ("  %-22s %s"):format(lulibre.hint("preview graphic"), "the page as an image, or as text again"),
    ("  %-22s %s"):format(lulibre.hint("preview page +1") .. "  " .. lulibre.hint("preview page -1"), "next and previous page"),
    ("  %-22s %s"):format(lulibre.hint("preview scroll +3") .. "  " .. lulibre.hint("preview scroll -3"), "scroll the preview"),
    ("  %-22s %s"):format(lulibre.hint("yank title"), "copy the title (and the other copying keys)"),
    ("  %-22s %s"):format(lulibre.hint("console"), "the log console"),
  }
end

-- the "about" panel each screen has open (M.about), by the screen's panel
local abouts = setmetatable({}, { __mode = "k" })

--- Run fn(...) on top of panel p: p leaves the screen while fn's own panel is
-- up, so the list and preview keep their room, and comes back afterwards
-- with the cursor where it was, whether fn returned or failed. Its "about"
-- panel goes and comes back with it.
function M.over(p, fn, ...)
  local about = abouts[p]
  if about then about:hide() end
  p:hide()
  local r = table.pack(pcall(fn, ...))
  p:show()
  if about then about:show() end
  if not r[1] then error(r[2], 0) end
  return table.unpack(r, 2, r.n)
end

--- What the row under the cursor of a screen's panel p is about, shown where
-- the list is, as review shows what a proposal rests on: the list is
-- covered while it is up and comes back when it goes. spec: title (the
-- panel's, or a function of the row), columns ({ {name, width}, ... }, two
-- by default), fill(row) -> rows (and a title). It opens at once when the
-- option review_context is 1; the screen's "about" key (i) shows it or hides
-- it. Returns a handle: :update(row), :toggle(row), :hide(), :show(),
-- :close(), and :open() (is it up?). Close it with the screen, in a <close>
-- variable.
function M.about(p, spec, row)
  local h = { spec = spec }
  local ctx
  local function hint() return require("lulibre.ui.keys").of(spec.keys or "review"):key("about") or "i" end
  function h:update(r)
    row = r or row
    if not ctx then return end
    if not ctx:is_open() then
      ctx = nil
      return
    end
    local ok, rows, title = pcall(spec.fill, row)
    ctx:rows(ok and (rows or {}) or { { "", tostring(rows), style = "error" } })
    ctx:title(("%s   %s hides"):format(ok and title or spec.title or "about this", hint()))
  end
  function h:toggle(r)
    if ctx and ctx:is_open() then
      ctx:close()
      ctx = nil
      return
    end
    ctx = lulibre.panel { side = "main", title = spec.title or "about this", columns = spec.columns or { { "", 14 }, { "", 0 } },
      rows = {}, focus = false }
    h:update(r)
  end
  function h:hide() if ctx and ctx:is_open() then ctx:hide() end end
  function h:show() if ctx and ctx:is_open() then ctx:show() end end
  function h:open() return ctx ~= nil and ctx:is_open() end
  function h:close()
    if ctx then pcall(ctx.close, ctx) end
    ctx = nil
    abouts[p] = nil
  end
  setmetatable(h, { __close = function(self) self:close() end })
  abouts[p] = h
  if lulibre.o.review_context ~= 0 then h:toggle(row) end
  return h
end

--- A function that gives the preview room: it shrinks p to a few rows, and
-- puts it back to `normal` (its share of the screen) when called again.
function M.peeker(p, normal)
  local small = false
  return function()
    small = not small
    p:height(small and 0.16 or normal)
    return small
  end
end

--- Bring a list of books up to date after something may have changed them:
-- each table keeps what else it carried, gets the record's fields afresh,
-- and those whose book is gone are taken out. Returns how many went.
function M.refresh_books(books)
  local gone = 0
  for i = #books, 1, -1 do
    local fresh = lulibre.book(books[i].id)
    if fresh then
      for k, v in pairs(fresh) do books[i][k] = v end
      for _, k in ipairs { "year", "pubdate", "publisher", "series", "series_index", "lang" } do
        if fresh[k] == nil then books[i][k] = nil end
      end
    else
      table.remove(books, i)
      gone = gone + 1
    end
  end
  return gone
end

return M
