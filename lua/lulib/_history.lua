--- :history: the journal's batches, newest first: what lulibre changed, and what
-- changed outside it. Enter shows a batch's rows, and u puts it back.
--
-- The screen "history": Enter shows or hides the batch's rows, u puts the batch back,
-- a shows lulibre's reading of what changed outside too or hides it; q closes.
-- keymap.set("history", key, action) rebinds them.
--
-- @library lulib._history
local sql = require "sql"
local sqlite3 = require "lsqlite3"

local M = {}

local STATE = { [0] = "waiting", [1] = "running", [2] = "", [3] = "failed", [4] = "undone" }

local function run(query, ...)
  local db = sql.open(setman.get("path.journaldb"), sqlite3.OPEN_READONLY)
  local rows = sql.run(db, query, ...)
  db:close()
  return rows
end

--- The recent batches, newest first: `{ {batch=, label=, ts=, books=, fields=, failed=, state=, store=}, ... }`.
-- @tparam[opt] integer limit 200 by default
function M.batches(limit)
  return run("SELECT batch, max(label) AS label, max(ts) AS ts, count(DISTINCT book) AS books, count(field) AS fields,"
             .. " sum(state = 3) AS failed, min(state) AS state, max(store) AS store, max(error) AS error"
             .. " FROM journal GROUP BY batch ORDER BY batch DESC LIMIT ?", limit or 200)
end

--- A batch's rows: `{ {book=, field=, old=, new=, state=, error=, argv=}, ... }`.
function M.rows(batch)
  return run("SELECT book, field, old, new, state, error, argv FROM journal WHERE batch = ? ORDER BY id", batch)
end

scrnman.create("history", {
  actions = {
    { "open", "<CR>", "show or hide the batch's rows" },
    { "undo", "u", "put the batch back" },
    { "outside", "a", "show or hide what changed outside lulibre" },
  },
  hint = { "open", "undo", "outside" },
})

--- Opens the list, and returns when it closes.
function M.open()
  local open, outside = {}, true
  local function items()
    local out = {}
    for _, b in ipairs(M.batches()) do
      if outside or b.label ~= "outside" then
        out[#out + 1] = b
        if open[b.batch] then
          for _, r in ipairs(M.rows(b.batch)) do out[#out + 1] = { row = r, batch = b.batch } end
        end
      end
    end
    if #out == 0 then out[1] = { note = "no changes yet" } end
    return out
  end
  uiman.list {
    title = "history", screen = "history", follow = true,
    columns = { { "Batch", 6 }, { "When", 16 }, { "Books", 5 }, { "What", -2 }, { "", 8 }, { "", -3 } },
    items = items,
    row = function(e)
      if e.note then return { e.note, style = "note" } end
      if e.row then
        local r = e.row
        local text = r.field and ("%s: %s → %s"):format(r.field, (r.old or ""):sub(1, 60), (r.new or ""):sub(1, 60))
          or (r.argv or ""):gsub("\t", " ")
        return { "", "", r.book and r.book ~= 0 and tostring(r.book) or "", text, STATE[r.state] or "", r.error or "",
                 id = r.book, style = "note" }
      end
      return { tostring(e.batch), os.date("%Y-%m-%d %H:%M", e.ts or 0), tostring(e.books), e.label or "",
               (e.failed or 0) > 0 and "failed" or STATE[e.state] or "", e.error or "",
               style = e.label == "outside" and "dim" or nil }
    end,
    actions = {
      open = function(e)
        local batch = e.batch
        if batch then open[batch] = not open[batch] or nil end
        return true
      end,
      undo = function(e)
        if not e.batch then return true end
        if e.label == "outside" then return nil, "what changed outside lulibre is put back by a snapshot: :snapshots" end
        local ok, err = require("store").undo(e.batch)
        if not ok then return nil, err end
        uiman.notify(("batch %d put back"):format(e.batch))
        return true
      end,
      outside = function()
        outside = not outside
        return true
      end,
    },
    refresh = { "records_changed" },
  }
end

return M
