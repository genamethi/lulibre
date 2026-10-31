--- :browse: the library as a tree in a column on the left: authors, the
-- subject hierarchy, series, publishers, years or formats, each with its count.
-- Moving through the tree narrows the list beside it.
--
-- The screen "browse": Enter opens or closes a branch, l opens it, h closes it
-- or steps out to its parent, / finds in the tree, s sorts by name or count, f and
-- F step through what it groups by; q closes. keymap.set("browse", key, action)
-- rebinds them.
--
-- @library lulib._browse
local bookman = require "bookman"
local expr = require "expr"
local mesr = require "mesr"
local sql = require "sql"
local sqlite3 = require "lsqlite3"

local M = {}

--- The ways the tree can group the library, in the order f steps through them.
M.facets = { "author", "subject", "series", "publisher", "year", "format" }

scrnman.create("browse", {
  actions = {
    { "toggle", "<CR>", "open or close the branch" },
    { "open", "l", "open the branch" },
    { "close", "h", "close the branch, or step out to its parent" },
    { "find", "/", "find in the tree" },
    { "sort", "s", "sort by name or by count" },
    { "facet", "f", "group by the next" },
    { "facet_back", "F", "group by the one before" },
  },
  hint = { "open", "find", "facet" },
})

local function quote(s)
  return '"' .. tostring(s):gsub('"', '\\"') .. '"'
end

local function index_rows(query)
  local db = sql.open(setman.get("path.indexdb"), sqlite3.OPEN_READONLY)
  local rows = sql.run(db, query)
  db:close()
  return rows
end

-- { {label=, n=, filter=}, ... } from names and counts, and the books with none
local function grouped(list, term, none)
  local out = {}
  for _, r in ipairs(list) do
    out[#out + 1] = { label = tostring(r.name), n = r.books or r.n, filter = term:format(quote(r.name)) }
  end
  if none then
    local n = bookman.count(none)
    if n > 0 then out[#out + 1] = { label = "(none)", n = n, filter = none, last = true } end
  end
  return out
end

local flat = {
  author = function()
    local list = {}
    for _, a in ipairs(bookman.authors()) do
      if a.name ~= "Unknown" then list[#list + 1] = a end
    end
    return grouped(list, "author:=%s", "no:author")
  end,
  series = function() return grouped(bookman.series(), "series:=%s", "no:series") end,
  publisher = function()
    return grouped(index_rows("SELECT publisher AS name, count(*) AS n FROM books WHERE id > 0 AND publisher IS NOT NULL GROUP BY publisher"),
                   "publisher:=%s", "no:publisher")
  end,
  year = function()
    local out = grouped(index_rows("SELECT year AS name, count(*) AS n FROM books WHERE id > 0 AND year IS NOT NULL GROUP BY year"),
                        "year:%s", "no:date")
    for _, node in ipairs(out) do node.filter = node.filter:gsub('"', "") end
    return out
  end,
  format = function()
    local out = grouped(index_rows("SELECT lower(format) AS name, count(DISTINCT book) AS n FROM files WHERE book > 0 GROUP BY lower(format)"),
                        "format:%s")
    for _, node in ipairs(out) do node.filter = node.filter:gsub('"', "") end
    return out
  end,
}

-- The subject tree: every tag "a.b.c" (calibre's levels; "a/b/c" too) counts
-- towards a, a.b and a.b.c.
local function subjects()
  local nodes, roots, sets = {}, {}, {}
  for _, r in ipairs(index_rows("SELECT bt.book, t.name FROM book_tags bt JOIN tags t ON t.id = bt.tag WHERE bt.book > 0")) do
    local sep = r.name:find("/", 1, true) and "/" or "."
    local path, parent = nil, nil
    for part in r.name:gmatch("[^./]+") do
      path = path and (path .. sep .. part) or part
      local node = nodes[path]
      if not node then
        node = { label = part, path = path, n = 0, children = {},
                 filter = ("tag:=%s or tag:^%s"):format(quote(path), quote(path .. sep)) }
        nodes[path], sets[path] = node, {}
        table.insert(parent and parent.children or roots, node)
      end
      if not sets[path][r.book] then
        sets[path][r.book] = true
        node.n = node.n + 1
      end
      parent = node
    end
  end
  local none = bookman.count("no:tags")
  if none > 0 then roots[#roots + 1] = { label = "(none)", n = none, filter = "no:tags", children = {}, last = true } end
  return roots
end

local last_facet = "subject"

--- Opens the tree.
-- @tparam[opt] string args a facet ("author", "subject" ...); the last one used if not given
function M.open(args)
  local facet = (args or ""):match("%S+") or last_facet
  local valid = false
  for _, f in ipairs(M.facets) do valid = valid or f == facet end
  if not valid then return uiman.notify("browse: " .. tostring(args) .. " is not one of " .. table.concat(M.facets, ", "), "error") end
  last_facet = facet
  local by_name, open, tree, shown = false, {}, nil, nil
  local function order(list)
    table.sort(list, function(a, b)
      if (a.last or false) ~= (b.last or false) then return b.last or false end
      if not by_name and a.n ~= b.n then return a.n > b.n end
      if facet == "year" and by_name then return a.label > b.label end
      return expr.fold(a.label) < expr.fold(b.label)
    end)
    return list
  end
  local function load()
    tree = facet == "subject" and subjects() or flat[facet]()
  end
  local function build()
    local rows = {}
    shown = { { label = "(everything)", n = bookman.count(""), filter = "" } }
    rows[1] = { shown[1].label, tostring(shown[1].n), style = "dim" }
    local function walk(list, depth)
      for _, node in ipairs(order(list)) do
        local kids = node.children and #node.children > 0
        local mark = kids and (open[node.path] and "▾ " or "▸ ") or (facet == "subject" and "  " or "")
        shown[#shown + 1] = node
        rows[#rows + 1] = { ("  "):rep(depth) .. mark .. node.label, tostring(node.n), style = node.last and "dim" or nil }
        if kids and open[node.path] then walk(node.children, depth + 1) end
      end
    end
    walk(tree, 0)
    return rows
  end
  load()
  local rows = build()
  local function title() return ("browse  %s  (%d)"):format(facet, #shown - 1) end
  local p <close> = uiman.panel {
    title = title(), screen = "browse", side = "left", width = 0.27, moves = true,
    columns = { { facet, -1 }, { "", 5 } }, rows = rows,
  }
  if not p then return end
  local applied
  local function apply(node)
    if node and node.filter ~= applied then
      applied = node.filter
      uiman.filter(node.filter)
    end
  end
  local function refresh(keep)
    p:rows(build())
    p:title(title())
    for i, node in ipairs(shown) do
      if node == keep then
        p:cursor(i)
        break
      end
    end
  end
  while true do
    local act, row = p:wait()
    if not act then return end
    local node = shown[row]
    if act == "<Move>" then
      apply(node)
    elseif act == "toggle" or act == "open" then
      if node and node.children and #node.children > 0 then
        if act == "toggle" then open[node.path] = not open[node.path] or nil else open[node.path] = true end
        refresh(node)
      end
      apply(node)
    elseif act == "close" then
      if node and node.path then
        if open[node.path] then
          open[node.path] = nil
          refresh(node)
        else
          local parent = node.path:match("^(.*)[./][^./]+$")
          for i, other in ipairs(shown) do
            if other.path == parent then
              p:cursor(i)
              apply(other)
              break
            end
          end
        end
      end
    elseif act == "sort" then
      by_name = not by_name
      refresh(node)
    elseif act == "facet" or act == "facet_back" then
      local at = 1
      for i, f in ipairs(M.facets) do
        if f == facet then at = i end
      end
      facet = M.facets[(at - 1 + (act == "facet" and 1 or -1)) % #M.facets + 1]
      last_facet = facet
      load()
      p:columns { { facet, -1 }, { "", 5 } }
      refresh()
      p:cursor(1)
      apply(shown[1])
    elseif act == "find" then
      if facet == "subject" then
        local function all(list)
          for _, n in ipairs(list) do
            if n.children and #n.children > 0 then
              open[n.path] = true
              all(n.children)
            end
          end
        end
        all(tree)
        refresh(node)
      end
      local function seek(text)
        if text == "" then return end
        local best, best_i
        for i = 2, #shown do
          local score = mesr.fuzzy(text, shown[i].path or shown[i].label)
          if score and (not best or score > best) then best, best_i = score, i end
        end
        if best_i then p:cursor(best_i) end
      end
      local text = uiman.input { prompt = "find in " .. facet .. ": ", on_change = seek }
      if text then apply(shown[p:cursor() or 1]) elseif row then p:cursor(row) end
    end
  end
end

return M
