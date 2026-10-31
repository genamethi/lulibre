--- The sync folder's files into the library. Each file waiting there is a
-- book with an id below 0 (db/stage.c): the list, filters, proposals and
-- review work on it as on any book, and what they change stays in lulibre
-- until it is added. `add` hands the files to calibre with what they then say,
-- as one batch :undo puts back, and proposals still waiting follow the file. With
-- `remove`, and for `drop`, a file goes to a holding folder (dropped/ beside the
-- index), from which :undo brings it back with its record.
--
--     local sync = require "lulib._sync"
--     uiman.notify(sync.summary(sync.add(bookman.ids("in:sync"), { remove = true })))
--
-- @library lulib._sync
local bookman = require "bookman"
local json = require "dkjson"
local sql = require "sql"
local sqlite3 = require "lsqlite3"
local store = require "store"
local wit = require "wit"

local M = {}

-- a staged file's row in the index
local function staged_row(book)
  local db = sql.open(setman.get("path.indexdb"), sqlite3.OPEN_READONLY)
  local row = sql.run(db, "SELECT path, title, twin FROM staged WHERE id = ?", -book)[1]
  db:close()
  return row
end
M.staged = staged_row

-- where a file goes when it is taken out of the folder
local function holding_path(path)
  local root = setman.get("path.sync"):gsub("/+$", "")
  local rel = path:sub(1, #root + 1) == root .. "/" and path:sub(#root + 2) or path:gsub("^.*/", "")
  local data = setman.get("path.indexdb"):gsub("/[^/]*$", "")
  return ("%s/dropped/%s/%s"):format(data, os.date("%Y%m%d-%H%M%S"), rel)
end

-- calibredb add's arguments for a staged book
local function add_args(book, path)
  local b = bookman.get(book)
  local args = { "add", "--duplicates" } -- lulibre has compared the bytes itself
  local function opt(flag, value)
    if value and value ~= "" then
      args[#args + 1] = flag
      args[#args + 1] = tostring(value)
    end
  end
  opt("--title", bookman.get(book, "title"))
  opt("--authors", bookman.get(book, "authors"))
  opt("--tags", bookman.get(book, "tags"))
  local series = bookman.get(book, "series")
  opt("--series", series)
  if series and series ~= "" then opt("--series-index", bookman.get(book, "series_index")) end
  for kind, value in pairs(b and b.idents or {}) do opt("--identifier", kind .. ":" .. value) end
  args[#args + 1] = path
  return args
end

-- proposals and fields of its own go with a file into the library
local function follow(from, to)
  wit.move(from, to)
  local db = sql.open(setman.get("path.customdb"), sqlite3.OPEN_READWRITE)
  sql.run(db, "UPDATE data SET book = ? WHERE book = ?", to, from)
  db:close()
end

--- Adds staged files to the library, and waits. A file the library already
-- holds isn't added again.
-- @tparam {integer,...} ids staged (negative) ids
-- @tparam[opt] table o `{ remove = true }`: take each file out of the folder once added
-- @treturn table `{ added=, held=, removed=, failed = { "why", ... }, batch= }`
function M.add(ids, o)
  o = o or {}
  local out = { added = 0, held = 0, removed = 0, failed = {} }
  local added, later, batch = {}, {}, nil
  for _, book in ipairs(ids) do
    local row = book < 0 and staged_row(book)
    if row then
      local into = row.twin
      if into then
        out.held = out.held + 1
      else
        local b, printed = store.command(add_args(book, row.path), { label = "sync: add", when = "any", batch = batch })
        local id = b and tonumber((printed or ""):match("Added book ids:%s*(%d+)"))
        if id then
          batch = b
          into = id
          added[#added + 1] = id
          local came = { from = row.path }
          for _, field in ipairs { "title", "authors", "tags", "series", "series_index", "publisher", "pubdate", "languages", "identifiers" } do
            came[field] = bookman.get(book, field) or ""
          end
          store.note(batch, id, "(added)", row.path, json.encode(came), "sync: add")
          out.added = out.added + 1
          for _, field in ipairs { "pubdate", "publisher" } do
            local value = bookman.get(book, field)
            if value and value ~= "" then later[#later + 1] = { book = id, field = field, value = value } end
          end
        else
          out.failed[#out.failed + 1] = (row.path:gsub("^.*/", "")) .. ": " .. tostring(printed or "calibredb add failed")
        end
      end
      if into then
        follow(book, into)
        if o.remove then
          local d, why = store.drop(book, holding_path(row.path), batch)
          if d then
            batch = batch or d
            out.removed = out.removed + 1
          else
            out.failed[#out.failed + 1] = why
          end
        end
      end
    end
  end
  if #added > 0 then
    store.command_undo(batch, { "remove", table.concat(added, ",") })
    store.reload()
    if #later > 0 then store.apply(later, "sync", batch) end
  end
  out.batch = batch
  return out
end

--- Takes staged files out of the folder without adding them. :undo puts them
-- back, their records too.
-- @tparam {integer,...} ids staged (negative) ids
-- @treturn table `{ dropped=, failed = { "why", ... }, batch= }`
function M.drop(ids)
  local out = { dropped = 0, failed = {} }
  for _, book in ipairs(ids) do
    local row = book < 0 and staged_row(book)
    if row then
      local d, why = store.drop(book, holding_path(row.path), out.batch)
      if d then
        out.batch = out.batch or d
        out.dropped = out.dropped + 1
      else
        out.failed[#out.failed + 1] = why
      end
    end
  end
  return out
end

--- One line about what `add` did.
function M.summary(out)
  local parts = {}
  if out.added > 0 then parts[#parts + 1] = ("added %d to the library"):format(out.added) end
  if out.held > 0 then parts[#parts + 1] = ("%d already there"):format(out.held) end
  if out.removed > 0 then parts[#parts + 1] = ("%d taken out of the sync folder"):format(out.removed) end
  if #out.failed > 0 then parts[#parts + 1] = ("%d failed: %s"):format(#out.failed, out.failed[1]) end
  return #parts > 0 and table.concat(parts, ", ") or "nothing to do"
end

return M
