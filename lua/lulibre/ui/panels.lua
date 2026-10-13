-- What the screens built on panels share.
local M = {}

-- The global commands whose keys still work with the cursor in a screen that
-- follows the list: paging and scrolling the preview, the page as an image
-- (P), copying (yy, yb ...), the console.
M.PASS = "preview yank console"

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

--- Run fn(...) on top of panel p: p leaves the screen while fn's own panel is
-- up, so the list and preview keep their room, and comes back afterwards
-- with the cursor where it was, whether fn returned or failed.
function M.over(p, fn, ...)
  p:hide()
  local r = table.pack(pcall(fn, ...))
  p:show()
  if not r[1] then error(r[2], 0) end
  return table.unpack(r, 2, r.n)
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
