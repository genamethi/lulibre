--- :verify: the books' records held against their files, a uiman.list. For
-- each book, how much of its title and its authors' names its pages hold,
-- and whether each identifier it has is the file's own, only mentioned, or
-- not found. It goes by what was kept (lulib._kept), reading only files not
-- read before, and changes nothing.
--
-- The screen "verify": r proposes for the book under the cursor, adding it to
-- the current review; R does so for every book listed; z shows the books the
-- pages bear out too; q closes. keymap.set("verify", key, action) rebinds
-- them.
--
-- @library lulib._verify
local bookman = require "bookman"
local check = require "lulib._check"
local ids = require "lulib._ids"
local kept = require "lulib._kept"
local mesr = require "mesr"

local M = {}
local own, get = require "lulib._expose" (M) -- internal (expose_modules)

--- What a book's pages say of its record: `{ id=, title=, authors=, idents=,
-- unread= }`; title `{ value=, found=, words=, score= }`, authors `{ value=,
-- found=, words= }`, idents `{ {kind=, value=, where = "own"|"mentioned"|"absent"},
-- ... }`; unread, why the file can't say.
-- @tparam integer book
-- @tparam table c lulib._check.settings()
-- @tparam integer top the setting id_top
function M.book(book, c, top)
  local b = bookman.get(book)
  if not b then return nil end
  local out = { id = book }
  local file = kept.file_of(book)
  if not file then out.unread = "no file"; return out end
  if not file.text then out.unread = "no text"; return out end
  if file.usable == false then out.unread = "text can't be read"; return out end
  local k <close> = kept.open(file.id, file.indexed)
  local text <close> = kept.reader(file)
  local title = bookman.get(book, "title")
  if title and title ~= "" then
    local found, words = check.count("title", title, k, text)
    out.title = { value = title, found = found, words = words, score = found and check.title(found, words, c) }
  end
  local authors = bookman.get(book, "authors")
  if authors and authors ~= "" then
    local found, words = check.count("authors", authors, k, text)
    out.authors = { value = authors, found = found, words = words }
  end
  local here = {}
  for _, f in ipairs(ids.of(file, k, text, top)) do here[f.kind .. ":" .. f.value] = f.own end
  out.idents = {}
  for kind, value in pairs(b.idents or {}) do
    local canon = mesr.canonical(kind, value) or value
    local is = here[kind .. ":" .. canon]
    local where = is and "own" or is == false and "mentioned" or nil
    if not where then
      local key = "place\0" .. kind .. ":" .. canon .. "\0" .. top
      where = k:get("ids", key)
      if not where then
        where = ids.place(kind, canon, text.get().text, top, file.pages, setman.get("id_refs_from"))
        k:put("ids", key, where)
      end
    end
    out.idents[#out.idents + 1] = { kind = kind, value = value, where = where }
  end
  table.sort(out.idents, function(a, z) return a.kind < z.kind end)
  return out
end

--- Whether a book's pages leave something of its record unborne: a title or
-- authors below check_same or none of whose words are there, an identifier that
-- stands only among the file's references, or a file that can't say. An identifier
-- not found says nothing: only the first pages are read, and many don't print it.
function M.doubtful(v, c)
  if v.unread then return true end
  if v.title and (v.title.score or 0) < c.same then return true end
  if v.authors and v.authors.words and v.authors.words > 0 and v.authors.found == 0 then return true end
  for _, i in ipairs(v.idents or {}) do
    if i.where == "cited" then return true end
  end
  return false
end

-- a found-of-words count as words
local function count(x)
  if not x or not x.found then return "" end
  return ("%d/%d"):format(x.found, x.words)
end

--- A book's cells: its id, title, the title's and the authors' counts, its
-- identifiers, why its file can't say.
function M.cells(v)
  local names = {}
  for _, i in ipairs(v.idents or {}) do names[#names + 1] = i.kind .. " " .. i.where end
  local title = bookman.get(v.id, "title")
  return { tostring(v.id), title or "", count(v.title), count(v.authors), v.unread or table.concat(names, ", ") }
end

-- The screen, and what each of its actions does (see lulib._review):
-- a row's report v, and the view's state
own.screen = {
  actions = {
    { "review", "r", "propose for this book, adding it to the current review" },
    { "review_all", "R", "propose for every book listed, adding them to the current review" },
    { "all", "z", "show the books the pages bear out too" },
  },
  hint = { "review", "review_all", "all" },
}
own.actions = {
  review = function(v)
    local propose = require "lulib._propose"
    local n = propose.propose(v.id, propose.settings()) or 0
    uiman.notify(("%d field%s proposed: :review shows them"):format(n, n == 1 and "" or "s"))
    return true
  end,
  review_all = function(_, view)
    local propose = require "lulib._propose"
    local w <const> = propose.settings()
    local n = 0
    for _, v in ipairs(view.listed()) do
      if (propose.propose(v.id, w) or 0) > 0 then n = n + 1 end
    end
    uiman.notify(("proposals for %d book%s: :review shows them"):format(n, n == 1 and "" or "s"))
    return true
  end,
  all = function(_, view)
    view.all = not view.all
    return true
  end,
}
scrnman.create("verify", own.screen)

--- Opens the report on the books, and returns when it closes.
-- @tparam {integer,...} books
function M.open(books)
  local c <const> = check.settings()
  local top <const> = setman.get("id_top")
  local all = {}
  for i, book in ipairs(books) do
    if i % 100 == 0 then uiman.progress(("checking %d/%d"):format(i, #books)) end
    all[#all + 1] = M.book(book, c, top)
  end
  uiman.progress(nil)
  local view = { all = false }
  function view.listed()
    local out = {}
    for _, v in ipairs(all) do
      if view.all or M.doubtful(v, c) then out[#out + 1] = v end
    end
    return out
  end
  local actions = {}
  for _, a in ipairs(get("screen").actions) do
    actions[a[1]] = function(v) return get("actions")[a[1]](v, view) end
  end
  uiman.list {
    title = function() return ("the records against their files: %d of %d books"):format(#view.listed(), #all) end,
    screen = "verify", follow = true,
    columns = { { "Book", 7 }, "Title", { "Title", 6 }, { "Authors", 7 }, "Identifiers" },
    items = view.listed,
    row = function(v)
      local r = M.cells(v)
      r.id = v.id
      return r
    end,
    actions = actions,
    refresh = { "records_changed" },
  }
end

return M
