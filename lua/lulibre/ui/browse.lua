-- The library as a tree, in a column on the left: authors, the subject
-- hierarchy, series, publishers, years or formats, each with its count.
-- Moving through it narrows the list beside it; Tab crosses to the list.
local M = {}

M.facets = { "author", "subject", "series", "publisher", "year", "format" }

local keys = require("lulibre.ui.keys").of("browse")

local function quote(s)
  return '"' .. tostring(s):gsub('"', '\\"') .. '"'
end

local function count(filter)
  local ok, n = pcall(lulibre.count, filter)
  return ok and n or 0
end

-- { {label=, n=, filter=}, ... } from a two-column query (name, n)
local function grouped(sql, term, none)
  local out = {}
  for _, r in ipairs(lulibre.sql(sql)) do
    out[#out + 1] = { label = tostring(r.name), n = r.n, filter = term:format(quote(r.name)) }
  end
  if none then
    local n = count(none)
    if n > 0 then out[#out + 1] = { label = "(none)", n = n, filter = none, last = true } end
  end
  return out
end

local flat = {
  author = function()
    return grouped("SELECT name, n_books AS n FROM authors WHERE id > 0 AND n_books > 0 AND name <> 'Unknown'",
      "author:=%s", "no:author")
  end,
  series = function()
    return grouped("SELECT series AS name, count(*) AS n FROM books WHERE id > 0 AND series IS NOT NULL GROUP BY series",
      "series:=%s", "no:series")
  end,
  publisher = function()
    return grouped("SELECT publisher AS name, count(*) AS n FROM books WHERE id > 0 AND publisher IS NOT NULL GROUP BY publisher",
      "publisher:=%s", "no:publisher")
  end,
  year = function()
    local out = grouped("SELECT year AS name, count(*) AS n FROM books WHERE id > 0 AND year IS NOT NULL GROUP BY year",
      "year:%s", "no:date")
    for _, node in ipairs(out) do node.filter = node.filter:gsub('"', "") end
    return out
  end,
  format = function()
    return grouped("SELECT lower(format) AS name, count(DISTINCT book) AS n FROM files WHERE book > 0 GROUP BY lower(format)", "fmt:%s")
  end,
}

-- The subject tree: every tag "a/b/c" counts towards a, a/b and a/b/c.
local function subjects()
  local nodes, roots, sets = {}, {}, {}
  for _, r in ipairs(lulibre.sql("SELECT bt.book, t.name FROM book_tags bt JOIN tags t ON t.id = bt.tag WHERE bt.book > 0")) do
    local path, parent = nil, nil
    for part in r.name:gmatch("[^/]+") do
      path = path and (path .. "/" .. part) or part
      local node = nodes[path]
      if not node then
        node = { label = part, path = path, n = 0, children = {},
          filter = ("tag:=%s or tag:^%s"):format(quote(path), quote(path .. "/")) }
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
  local none = count("no:tags")
  if none > 0 then roots[#roots + 1] = { label = "(none)", n = none, filter = "no:tags", children = {}, last = true } end
  return roots
end

function M.run(args)
  local facet = (args or ""):match("%S+") or lulibre.store("SELECT value FROM kv WHERE key = 'browse:facet'")[1]
  if type(facet) == "table" then facet = facet.value end
  local valid = false
  for _, f in ipairs(M.facets) do valid = valid or f == facet end
  if not valid then
    if args and args:match("%S") then
      lulibre.notify("browse: " .. args .. " is not one of " .. table.concat(M.facets, ", "), "error")
      return
    end
    facet = "subject"
  end

  local by_name = false   -- sort by count unless asked
  local open = {}         -- subject path -> shown opened
  local tree, shown       -- the facet's nodes; the rows on screen as nodes

  local function order(list)
    table.sort(list, function(a, b)
      if (a.last or false) ~= (b.last or false) then return b.last or false end
      if not by_name and a.n ~= b.n then return a.n > b.n end
      if facet == "year" and by_name then return a.label > b.label end
      return lulibre.fold(a.label) < lulibre.fold(b.label)
    end)
    return list
  end

  local function load()
    tree = facet == "subject" and subjects() or flat[facet]()
  end

  local function build()
    local rows = {}
    shown = { { label = "(everything)", n = count(""), filter = "" } }
    rows[1] = { shown[1].label, shown[1].n, style = "dim" }
    local function walk(list, depth)
      for _, node in ipairs(order(list)) do
        local kids = node.children and #node.children > 0
        local mark = kids and (open[node.path] and "▾ " or "▸ ") or (facet == "subject" and "  " or "")
        shown[#shown + 1] = node
        node.depth = depth
        rows[#rows + 1] = { ("  "):rep(depth) .. mark .. node.label, node.n, style = node.last and "dim" or nil }
        if kids and open[node.path] then walk(node.children, depth + 1) end
      end
    end
    walk(tree, 0)
    return rows
  end

  load()
  local function title()
    return ("browse  %s  (%d)"):format(facet, #shown - 1)
  end
  local rows = build()
  local p <close> = lulibre.panel {
    title = title(), help = keys:hint("open", "find", "facet"), side = "left", width = 0.27, moves = true,
    columns = { { facet, -1 }, { "", 5 } }, rows = rows,
  }

  local applied
  local function apply(node)
    if node and node.filter ~= applied then
      applied = node.filter
      lulibre.filter(node.filter)
    end
  end
  local function refresh(keep)
    p:rows(build())
    p:title(title())
    if keep then
      for i, node in ipairs(shown) do
        if node == keep then
          p:cursor(i)
          break
        end
      end
    end
  end
  local function switch(to)
    facet = to
    lulibre.store("INSERT OR REPLACE INTO kv(key, value) VALUES('browse:facet', ?)", facet)
    load()
    p:columns { { facet, -1 }, { "", 5 } }
    refresh()
    p:cursor(1)
  end

  while true do
    local key, row = p:wait()
    if not key then return end
    local node = shown[row]
    local act = keys:action(key)
    if key == "<Move>" then
      apply(node)
    elseif act == "help" then
      keys:show("browse")
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
          -- step out to the parent
          local parent = node.path:match("^(.*)/[^/]+$")
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
      switch(M.facets[(at - 1 + (act == "facet" and 1 or -1)) % #M.facets + 1])
      apply(shown[1])
    elseif act == "find" then
      if facet == "subject" then
        -- look through the whole tree, not only what is opened
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
          local score = lulibre.fuzzy(text, shown[i].path or shown[i].label)
          if score and (not best or score > best) then best, best_i = score, i end
        end
        if best_i then p:cursor(best_i) end
      end
      local text = lulibre.input { prompt = "find in " .. facet .. ": ", on_change = seek }
      if text then apply(shown[p:cursor() or 1]) elseif row then p:cursor(row) end
    end
  end
end

return M
