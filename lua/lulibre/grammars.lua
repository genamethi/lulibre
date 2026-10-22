--- Recognises kinds of documents by how they set their opening lines.
--
-- Keith Conrad's handouts put the title in capitals, with KEITH CONRAD
-- smaller below. A chapter of the Stacks project puts its title in
-- capitals, then its tag ("01H8") or "Contents". A Springer chapter puts
-- its number and title in very large type. The first few lines and how
-- they are set say more than the title page as a whole. A grammar describes
-- those lines one by one, and what follows if they match: the title, the
-- authors, that such works have no catalogue record, or which whole the
-- file is part of.
--
-- A grammar is matched against the first page's lines in order. Each line
-- has its text, its font size, and whether it is bold:
--
--    local G = require "lulibre.grammars"
--    G.add {
--      name = "keith-conrad",           -- shown as where a value came from
--      kind = "handout",                -- what such a file is
--      noncatalog = true,               -- such works have no catalogue record
--      lines = {                        -- the opening lines, in order
--        G.line { upper = true, take = "title", case = "title" },   -- in capitals: the title (put in title case)
--        G.line { pattern = "^KEITH CONRAD$", smaller = true, give = { authors = "Keith Conrad" } },
--      },
--      confidence = 0.95,
--    }
--
-- A line rule (`G.line`) can test:
--
-- - `pattern`: a Lua pattern (`nocase = true` ignores case)
-- - `upper`: all letters are capitals
-- - `bold`
-- - `bigger` / `smaller`: than the font of the page's body text
-- - `largest`: the largest font on the page
-- - `size = { min, max }`: in points
--
-- A line rule can set fields with `take = "field"`, which takes the line or
-- the pattern's first capture (`case = "title"` puts it in title case), or
-- with `give = { field = value }`. `G.skip(n)` skips up to n lines,
-- `G.opt(rule)` makes a rule optional, and `G.either{ rule, rule }` matches
-- one rule or the other.
--
-- A grammar can also give `text = { patterns }`, which must appear
-- somewhere in the pages read (ignoring case); `pages = { min, max }` for the
-- file's length; and `read = function(doc, got)`, which returns more fields
-- from the document.
--
-- With LPeg installed (a rock; lulibre.features names it), a line rule can
-- give `peg`, an LPeg pattern, instead of `pattern`. Its first capture is
-- what `take` takes, and a table capture gives fields. A grammar can also
-- give `peg` as a pattern over its opening lines (`head` lines, 12 by
-- default) joined by newlines. The pattern's table capture (lpeg.Ct with
-- named lpeg.Cg) gives fields:
--
--    local lpeg = G.lpeg()
--    local P, C, Cg, Ct, R, S = lpeg.P, lpeg.C, lpeg.Cg, lpeg.Ct, lpeg.R, lpeg.S
--    local caps = (R"AZ" + S" '-:,")^3
--    G.add { name = "my-notes", peg = Ct(Cg(C(caps), "title") * P"\n" * Cg(C((1 - P"\n")^1), "authors")) }
--
-- Fields are the book's fields (title, authors, tags, ...) and three more,
-- which lulibre stores (:parts): part_of (the whole the file is part of),
-- part (the file's number in the whole) and parts (how many parts there are).
--
-- @reading lulibre.grammars
-- @usage
-- local G = require "lulibre.grammars"
-- G.add { name = "my-notes", lines = { G.line { upper = true, take = "title" } } }
-- G.match(G.doc(12))   --> { {grammar=, fields=}, ... }
local M = {}

--- The grammars, in the order they are tried.
M.list = {}

--- Returns LPeg, if it is installed and loads. lulibre refuses a C module
-- built for another Lua version.
-- @treturn[1] table lpeg
-- @treturn[2] nil
-- @treturn[2] string why not
function M.lpeg()
  local ok, lpeg = pcall(require, "lpeg")
  if ok then return lpeg end
  return nil, "LPeg is not installed for " .. _VERSION .. " (luarocks install lpeg, or the option rocks_tree): " .. tostring(lpeg):match("[^\n]*$")
end

--- Adds a grammar, or replaces the grammar with the same name.
-- @tparam table g
-- @treturn table g
function M.add(g)
  assert(type(g) == "table" and type(g.name) == "string", "a grammar is a table with a name")
  assert(g.lines or g.read or g.text or g.peg, "a grammar needs lines, peg, text or read to say what it looks for")
  for i, x in ipairs(M.list) do
    if x.name == g.name then
      M.list[i] = g
      return g
    end
  end
  M.list[#M.list + 1] = g
  return g
end

--- Removes a grammar.
-- @tparam string name
-- @treturn table|nil the grammar removed
function M.remove(name)
  for i, x in ipairs(M.list) do
    if x.name == name then return table.remove(M.list, i) end
  end
end

-- ---- rules ----

--- Returns a rule for one line. The module description lists what a rule
-- can test and take.
-- @tparam table t
-- @treturn table the rule
function M.line(t)
  t.kind = "line"
  return t
end

--- Returns a rule that skips up to n lines.
-- @tparam[opt] integer n 1 if not given
-- @treturn table the rule
function M.skip(n)
  return { kind = "skip", n = n or 1 }
end

--- Returns a rule that makes another rule optional.
-- @tparam table rule
-- @treturn table the rule
function M.opt(rule)
  return { kind = "opt", rule = rule }
end

--- Returns a rule that matches any one of several rules.
-- @tparam {table,...} rules
-- @treturn table the rule
function M.either(rules)
  return { kind = "either", rules = rules }
end

local function is_upper(text)
  local letters = text:gsub("[^%a]", "")
  return #letters >= 3 and letters == letters:upper()
end

-- does a line answer a line rule? returns the fields it gives, or nil
local function line_ok(rule, line, page)
  local text = line.text or ""
  local cap
  if rule.peg then
    local r = rule.peg:match(text)
    if r == nil then return nil end
    if type(r) == "table" then
      local got = {}
      for k, v in pairs(r) do
        if type(k) == "string" then got[k] = v end
      end
      return got
    end
    if type(r) == "string" then cap = r end
  end
  if rule.pattern then
    local subject = rule.nocase and text:lower() or text
    local s, e, c = subject:find(rule.nocase and rule.pattern:lower() or rule.pattern)
    if not s then return nil end
    cap = c
    if rule.nocase and c then cap = text:sub(s, e):match(rule.pattern:lower()) and c end
  end
  if rule.upper and not is_upper(text) then return nil end
  if rule.bold ~= nil and (line.bold or false) ~= rule.bold then return nil end
  local size = line.size or 0
  if rule.bigger and not (size > page.body * 1.08) then return nil end
  if rule.smaller and not (size < page.body * 0.95) then return nil end
  if rule.largest and size < page.largest - 0.05 then return nil end
  if rule.size and (size < (rule.size[1] or 0) or size > (rule.size[2] or math.huge)) then return nil end
  local got = {}
  if rule.take then
    local v = cap or text
    v = v:gsub("^%s+", ""):gsub("%s+$", "")
    if rule.case == "title" then
      -- in title case; a roman numeral (II, IV) stays as it is
      local romans = {}
      for w in v:gmatch("%f[%w]([IVXLC]+)%f[%W]") do romans[w:lower()] = w end
      v = require("lulibre.titlecase").apply(v:lower()):gsub("%f[%w](%a+)%f[%W]", function(w)
        return romans[w:lower()] or w
      end)
    end
    got[rule.take] = v
  end
  for k, v in pairs(rule.give or {}) do got[k] = v end
  return got
end

-- match rules from rule i against lines from line j; returns the fields, or nil
local function seq(rules, i, lines, j, page, got)
  if i > #rules then return got end
  local r = rules[i]
  if r.kind == "skip" then
    for k = 0, r.n do
      local res = seq(rules, i + 1, lines, j + k, page, got)
      if res then return res end
    end
    return nil
  elseif r.kind == "opt" then
    return seq({ r.rule, table.unpack(rules, i + 1) }, 1, lines, j, page, got) or seq(rules, i + 1, lines, j, page, got)
  elseif r.kind == "either" then
    for _, alt in ipairs(r.rules) do
      local res = seq({ alt, table.unpack(rules, i + 1) }, 1, lines, j, page, got)
      if res then return res end
    end
    return nil
  end
  local line = lines[j]
  if not line then return nil end
  local fields = line_ok(r, line, page)
  if not fields then return nil end
  local merged = {}
  for k, v in pairs(got) do merged[k] = v end
  for k, v in pairs(fields) do
    -- a field taken twice (a title over two lines) is joined
    merged[k] = merged[k] and (merged[k] .. " " .. v) or v
  end
  return seq(rules, i + 1, lines, j + 1, page, merged)
end

-- the page's body type: the size most of its lines are set in; and its largest
local function sizes(lines)
  local count, largest = {}, 0
  for _, l in ipairs(lines) do
    if not l.rotated then
      local s = math.floor((l.size or 0) * 2 + 0.5) / 2
      count[s] = (count[s] or 0) + #(l.text or "")
      if (l.size or 0) > largest then largest = l.size end
    end
  end
  local body, most = 0, -1
  for s, n in pairs(count) do
    if n > most then body, most = s, n end
  end
  return body, largest
end

--- Returns the grammars that match a document, with the fields each gives.
-- @tparam table doc `{ id=, lines=, texts=, pages= }`: the first page's lines, the pages'
-- texts, and the file's length
-- @treturn {table,...} `{ grammar=, fields= }`
function M.match(doc)
  local out = {}
  local lines = {}
  for _, l in ipairs(doc.lines or {}) do
    if not l.rotated and (l.text or ""):find("%S") then lines[#lines + 1] = l end
  end
  local body, largest = sizes(lines)
  local page = { body = body, largest = largest }
  local all
  for _, g in ipairs(M.list) do
    local ok = true
    if g.pages and doc.pages and (doc.pages < (g.pages[1] or 0) or doc.pages > (g.pages[2] or math.huge)) then ok = false end
    if ok and g.text then
      all = all or table.concat(doc.texts or {}, "\n"):lower()
      for _, p in ipairs(g.text) do
        if not all:find(p:lower()) then ok = false end
      end
    end
    local got = ok and {} or nil
    if ok and g.lines then got = seq(g.lines, 1, lines, 1, page, {}) end
    if got and g.peg then
      local head = {}
      for i = 1, math.min(g.head or 12, #lines) do head[i] = lines[i].text end
      local r = g.peg:match(table.concat(head, "\n"))
      if r == nil then got = nil
      elseif type(r) == "table" then
        for k, v in pairs(r) do
          if type(k) == "string" then got[k] = v end
        end
      end
    end
    if got and g.read then
      local more = g.read(doc, got)
      if more == false then got = nil
      elseif type(more) == "table" then
        for k, v in pairs(more) do got[k] = v end
      end
    end
    if got then out[#out + 1] = { grammar = g, fields = got } end
  end
  return out
end

--- Returns a book's document in the form `match` takes.
-- @tparam integer id
-- @treturn table
function M.doc(id)
  local f = lulibre.sql("SELECT id, npages FROM files WHERE book = ? AND status = 1 ORDER BY id LIMIT 1", id)[1]
  if not f then return nil end
  local texts = {}
  for _, p in ipairs(lulibre.sql("SELECT text FROM pages WHERE file = ? ORDER BY page", f.id)) do texts[#texts + 1] = p.text end
  local book = lulibre.book(id)
  return { id = id, lines = lulibre.lines(id, 1), texts = texts, pages = f.npages, idents = book and book.idents or {} }
end

-- ---- built-in grammars ----

M.add {
  name = "keith-conrad",
  kind = "handout",
  noncatalog = true,
  lines = {
    M.line { upper = true, take = "title", case = "title" },
    M.opt(M.line { upper = true, take = "title", case = "title" }),
    M.line { pattern = "^KEITH CONRAD$", give = { authors = "Keith Conrad" } },
  },
  confidence = 0.95,
}

-- The Stacks project: each chapter opens with its name in capitals and then
-- its tag (four characters, 01H8) or its contents. The reading order is in
-- the project's Makefile; a book whose text holds that table ("Chapters in
-- reading order", | # | Chapter | Pages | PDF |) gives each chapter its number.
local stacks_order -- stem -> { n=, pages= }, and the count; read once
local function read_stacks_order()
  if stacks_order ~= nil then return stacks_order end
  stacks_order = false
  local row = lulibre.sql([[SELECT p.text FROM pages p JOIN files f ON f.id = p.file
    WHERE p.text LIKE '%Chapters in reading order%' LIMIT 1]])[1]
  if not row then return false end
  local fid = lulibre.sql([[SELECT p.file FROM pages p WHERE p.text LIKE '%Chapters in reading order%' LIMIT 1]])[1].file
  local text = {}
  for _, r in ipairs(lulibre.sql("SELECT text FROM pages WHERE file = ? ORDER BY page", fid)) do text[#text + 1] = r.text end
  local order, n = {}, 0
  for num, stem, pages in table.concat(text, "\n"):gmatch("|%s*(%d+)%s*|%s*([%w%-_]+)%s*|%s*(%d+)%s*|") do
    order[stem:lower()] = { n = tonumber(num), pages = tonumber(pages) }
    n = math.max(n, tonumber(num))
  end
  if n == 0 then return false end
  stacks_order = { order = order, count = n }
  return stacks_order
end

M.add {
  name = "stacks-project",
  kind = "chapter of the Stacks project",
  noncatalog = true,
  lines = {
    M.line { upper = true, take = "title", case = "title" },
    M.either {
      M.line { pattern = "^%w%w%w%w$" },  -- its tag
      M.line { pattern = "^Contents$" },
      M.line { pattern = "^Copyright %(C%) %d+ %-%- %d+ Johan de Jong" },
    },
  },
  read = function(doc, got)
    -- a tag is four characters of figures and capitals, with a figure among them
    local first = doc.lines and doc.lines[2] and doc.lines[2].text or ""
    if first:match("^%w%w%w%w$") and not first:find("%d") then return false end
    local fields = { authors = "The Stacks Project", part_of = "The Stacks Project" }
    local ord = read_stacks_order()
    if ord then
      fields.parts = ord.count
      -- the chapter by its file's name (calibre's title, when it came from it), else by its title's first word, and its length
      local book = lulibre.book(doc.id)
      local keys = { lulibre.fold(book and book.title or ""):gsub("[^%w]+", ""), (lulibre.fold(got.title or ""):match("^(%w+)")) }
      for _, k in ipairs(keys) do
        local hit = k and ord.order[k]
        if hit and (not hit.pages or not doc.pages or math.abs(hit.pages - doc.pages) <= 1) then
          fields.part = hit.n
          break
        end
      end
    end
    return fields
  end,
  confidence = 0.9,
}

-- Elsevier's Handbook of Algebra (ISSN 1570-7954): its chapters' DOIs say the
-- volume by year ((96) is volume 1) and the chapter's place in it (80014: 14).
-- A chapter without its DOI still has Elsevier's item number (the PII) in
-- the file's own title ("PII: S1570-7954(00)80034-0"), of which the DOI is
-- made, or its first page's foot: "HANDBOOK OF ALGEBRA, VOL. 3 / Edited by
-- M. Hazewinkel / © 2003 Elsevier Science B.V.".
local HANDBOOK_VOLUMES = { ["96"] = 1, ["00"] = 2, ["03"] = 3, ["06"] = 4, ["08"] = 5, ["09"] = 6 }
local HANDBOOK_YEARS = { 1996, 2000, 2003, 2006, 2008, 2009 }
M.add {
  name = "handbook-of-algebra",
  kind = "chapter of the Handbook of Algebra",
  read = function(doc)
    local doi = ((doc.idents or {}).doi or ""):upper()
    if doi == "" and doc.id then
      for _, f in ipairs(lulibre.sql("SELECT emb_title FROM files WHERE book = ?", doc.id)) do
        local pii = (f.emb_title or ""):upper():match("PII:%s*(S1570%-7954%(%d%d%)%d%d%d%d%d%-?[%dX])")
        if pii then doi = "10.1016/" .. pii break end
      end
    end
    local yy, item = doi:match("^10%.1016/S1570%-7954%((%d%d)%)(%d%d%d%d%d)")
    local vol = yy and HANDBOOK_VOLUMES[yy]
    local page = (doc.texts or {})[1] or ""
    local foot = page:upper():match("HANDBOOK OF ALGEBRA,?%s*VOL%.?%s*(%d)%f[%D]")
    if not yy and not foot then return false end
    vol = vol or tonumber(foot)
    local fields = { part_of = vol and ("Handbook of Algebra, Volume %d"):format(vol) or "Handbook of Algebra",
      part = item and tonumber(item:sub(-3)) or nil,
      identifiers = yy and ("doi:" .. doi) or nil,
      -- the year the foot of the page prints, else the volume's
      pubdate = page:match("%f[%d](%d%d%d%d)%s+Elsevier") or (vol and HANDBOOK_YEARS[vol] and tostring(HANDBOOK_YEARS[vol])) or nil,
      publisher = "Elsevier" }
    -- the title is the largest type on the page, the authors under it
    local lines, top = doc.lines or {}, 0
    for _, l in ipairs(lines) do
      if (l.size or 0) > top then top = l.size end
    end
    local title = {}
    for i, l in ipairs(lines) do
      if (l.size or 0) >= top - 0.1 and i <= 4 then title[#title + 1] = l.text end
    end
    if #title > 0 then fields.title = table.concat(title, " ") end
    return fields
  end,
  confidence = 0.85,
}

-- A chapter of a book set as Springer and others set them: its number and
-- its title in very large type, on a file much shorter than a book.
M.add {
  name = "numbered-chapter",
  kind = "chapter",
  pages = { 2, 90 },
  lines = {
    M.line { pattern = "^(%d%d?%s+%u.*)$", largest = true, take = "part" },
  },
  read = function(doc, got)
    local num, title = (got.part or ""):match("^(%d+)%s+(.+)$")
    if not num then return false end
    -- the type must be very large beside the text: a heading, not a numbered paragraph
    local lines, body = doc.lines or {}, nil
    local first = lines[1] and lines[1].size or 0
    local count = {}
    for _, l in ipairs(lines) do
      local s = math.floor((l.size or 0) + 0.5)
      count[s] = (count[s] or 0) + 1
    end
    local most = 0
    for s, n in pairs(count) do
      if n > most then body, most = s, n end
    end
    if not body or first < body * 2 then return false end
    -- a title too long for one line runs on in the same type
    for i = 2, math.min(4, #lines) do
      if math.abs((lines[i].size or 0) - first) > 0.5 then break end
      title = title .. " " .. lines[i].text
    end
    local fields = { part = tonumber(num), title = title }
    -- the whole: the book its ISBN names, when the kept record is much longer than the file
    local isbn = (doc.idents or {}).isbn
    local rec = isbn and require("lulibre.net").kept_record("isbn", isbn)
    if rec and rec.title and rec.pages and doc.pages and rec.pages > doc.pages * 2.5 then fields.part_of = rec.title end
    return fields
  end,
  confidence = 0.8,
}

return M
