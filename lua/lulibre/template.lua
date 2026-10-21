--- Pulls named fields out of a string with a pattern, and fills a pattern
-- from a book's fields.
--
-- Wherever a pattern is asked for, two forms are accepted:
--
--   %author% - %title% (%year%)         a template: named fields between
--                                        literal text
--   ^(.-) %- (.-) %((%d+)%)$ => author, title, year
--                                        a Lua pattern, followed by the
--                                        names of its captures
--
-- Both forms compile to a Lua pattern and a list of field names, so a match
-- is a table indexed by field name.
--
-- @module lulibre.template
-- @usage
-- local template = require "lulibre.template"
-- local c = template.compile("%author% - %title% (%year%)")
-- template.match(c, "Serre - Trees (1980)")  --> { author = "Serre", title = "Trees", year = "1980" }
-- template.format("%author% - %title%", book) --> "Jean-Pierre Serre - Trees"
local M = {}

-- what a field may look like when the template does not say
local shapes = { year = "(%d%d%d%d)", id = "(%d+)", index = "(%d+%.?%d*)", isbn = "([%dXx%-]+)" }
-- names people type -> calibre field names
local alias = { author = "authors", tag = "tags", subject = "tags", subjects = "tags",
  date = "pubdate", year = "pubdate", doi = "identifiers", isbn = "identifiers", arxiv = "identifiers" }

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Returns what is wrong with a Lua pattern, or nil. Lua reports a
-- malformed pattern only if matching reaches the bad part, so `check`
-- checks the pattern's structure instead: escapes, sets and captures must
-- all be closed.
-- @tparam string pat
-- @treturn string|nil what is wrong
function M.check(pat)
  local depth, i, n = 0, 1, #pat
  while i <= n do
    local c = pat:sub(i, i)
    if c == "%" then
      if i == n then return "the pattern ends with a lone %" end
      i = i + 1
    elseif c == "[" then
      local j = i + 1
      if pat:sub(j, j) == "^" then j = j + 1 end
      if pat:sub(j, j) == "]" then j = j + 1 end
      while j <= n and pat:sub(j, j) ~= "]" do
        if pat:sub(j, j) == "%" then j = j + 1 end
        j = j + 1
      end
      if j > n then return "a [set] is not closed" end
      i = j
    elseif c == "(" then
      depth = depth + 1
    elseif c == ")" then
      depth = depth - 1
      if depth < 0 then return "there is a ) without its (" end
    end
    i = i + 1
  end
  if depth > 0 then return "a ( capture is not closed" end
  return nil
end

--- Compiles a template or a "pattern => fields" spec.
-- @tparam string spec
-- @treturn[1] table `{ pattern=, fields=, spec= }`
-- @treturn[2] nil
-- @treturn[2] string the message
function M.compile(spec)
  spec = trim(spec or "")
  if spec == "" then return nil, "empty pattern" end
  local pat, list = spec:match("^(.-)%s*=>%s*(.+)$")
  if pat then
    local fields = {}
    for name in list:gmatch("[%a_][%w_]*") do fields[#fields + 1] = name end
    if #fields == 0 then return nil, "name the captures after =>, e.g. => author, title" end
    local problem = M.check(pat)
    if problem then return nil, problem end
    return { pattern = pat, fields = fields, spec = spec }
  end
  if not spec:find("%%[%a_][%w_]*%%") then
    return nil, "use fields like %title%, or a Lua pattern followed by => field, field"
  end
  local out, fields, pos = { "^" }, {}, 1
  while true do
    local s, e, name = spec:find("%%([%a_][%w_]*)%%", pos)
    local literal = spec:sub(pos, s and s - 1 or -1)
    -- escape pattern magic, and let any run of spaces match any run of spaces
    out[#out + 1] = (literal:gsub("%p", "%%%0"):gsub("%s+", "%%s+"))
    if not s then break end
    fields[#fields + 1] = name
    out[#out + 1] = shapes[name] or "(.-)"
    pos = e + 1
  end
  out[#out + 1] = "$"
  return { pattern = table.concat(out), fields = fields, spec = spec }
end

--- Matches a string against a compiled pattern. Field names are as
-- written in the pattern; `canonical` maps them to calibre's.
-- @tparam table compiled
-- @tparam string s
-- @treturn table|nil `{ field = value, ... }`, or nil if the string does not match
function M.match(compiled, s)
  local caps = table.pack(pcall(string.match, s, compiled.pattern))
  if not caps[1] then return nil end -- a pattern Lua rejects matches nothing
  table.remove(caps, 1)
  caps.n = caps.n - 1
  if caps.n == 0 or caps[1] == nil then return nil end
  local out = {}
  for i, name in ipairs(compiled.fields) do
    local v = caps[i]
    if type(v) == "string" then
      v = trim(v)
      if v == "" then return nil end
      out[name] = v
    end
  end
  return out
end

--- Returns the calibre field and value for a captured name and value.
-- "year", "1996" gives "pubdate", "1996", and "doi", "10.1/x" gives
-- "identifiers", "doi:10.1/x".
-- @tparam string name
-- @tparam string value
-- @treturn string the field
-- @treturn string the value
function M.canonical(name, value)
  local field = alias[name] or name
  if field == "identifiers" and name ~= "identifiers" then value = name .. ":" .. value end
  return field, value
end

--- Fills a template from a book: format("%author% - %title% (%year%)", book).
-- Missing fields become "unknown", and slashes are replaced so the result
-- is safe as a file name.
-- @tparam string spec
-- @tparam table book
-- @treturn string
function M.format(spec, book)
  local values = {
    title = book.title, author = book.author, authors = book.author,
    year = book.year and tostring(book.year), id = tostring(book.id),
    publisher = book.publisher, series = book.series,
    tags = book.tags and table.concat(book.tags, ", "), subject = book.tags and book.tags[1],
  }
  return (spec:gsub("%%([%a_][%w_]*)%%", function(name)
    local v = values[name]
    if not v or v == "" then v = "unknown" end
    return (v:gsub("[/%z]", "-"))
  end))
end

return M
