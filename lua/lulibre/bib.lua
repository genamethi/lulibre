--- BibTeX out and in.
--
-- Out: entries with stable cite keys and a `file` field, which Zotero,
-- JabRef and BibDesk all understand on import. In: a .bib file parsed into
-- entries, for matching against the library.
--
-- @module lulibre.bib
-- @usage
-- local bib = require "lulibre.bib"
-- local text, keys = bib.export({ 12, 15 })
-- bib.key(book)                         --> "connes2006walk"
-- bib.last_first("Gerard van der Geer")  --> "van der Geer, Gerard"
-- bib.parse(io.open("refs.bib"):read("a"))[1].fields.title
local M = {}

local PARTICLE = {}
for w in ("van von de der den du di del della la le dos da"):gmatch("%S+") do PARTICLE[w] = true end
local STOP = {}
for w in ("a an the of in on and for to with by at from via some new notes note introduction"):gmatch("%S+") do STOP[w] = true end

local function unknown(a)
  return a == nil or a == "" or a == "Unknown" or a == "()"
end

--- A book's authors as individual people, even where the library still has
-- several run together in one entry ("A. One; B. Two").
local function people_of(book)
  local names = require "lulibre.names"
  local out = {}
  if unknown(book.author) then return out end
  for _, a in ipairs(book.authors) do
    for _, person in ipairs(names.split(a)) do out[#out + 1] = names.titlecase(person) end
  end
  return out
end

--- "Gerard van der Geer" -> "van der Geer, Gerard". Names that already have
-- a comma, and names that are not people ("The PARI group"), are braced so
-- BibTeX leaves them alone.
-- @tparam string name
-- @treturn string
function M.last_first(name)
  if name:find(",") then return name end
  local t = {}
  for w in name:gmatch("%S+") do t[#t + 1] = w end
  if #t == 1 then return name end
  local low = " " .. name:lower() .. " "
  if #t > 5 or t[1] == "The" or low:find(" team ") or low:find(" group ") or low:find(" project ")
    or low:find(" authors ") or low:find(" society ") or low:find(" universit") or low:find(" institute ")
    or low:find(" press ") or low:find(" collaboration ") or low:find(" committee ") or low:find(" inc%.? ") then
    return "{" .. name .. "}"
  end
  local i = #t
  while i > 2 and PARTICLE[t[i - 1]:lower()] do i = i - 1 end
  return table.concat(t, " ", i) .. ", " .. table.concat(t, " ", 1, i - 1)
end

local function surname(name)
  local lf = M.last_first(name):gsub("[{}]", "")
  return (lf:match("^([^,]+)") or name)
end

local function escape(s)
  return (s:gsub("\\", "\\textbackslash "):gsub("[&%%$#_]", "\\%0"))
end

--- The cite key for a book: first author's surname, year, first telling word
-- of the title, e.g. connes2006walk. opts.key is a template over %auth%,
-- %year%, %word%, %id%.
-- @tparam table book
-- @tparam[opt] table opts `key`
-- @treturn string
function M.key(book, opts)
  local tpl = opts and opts.key or "%auth%%year%%word%"
  local auth, first = "", people_of(book)[1]
  if first then auth = lulibre.fold(surname(first)):gsub("[^%w]", "") end
  local word = ""
  for w in lulibre.fold(book.title or ""):gmatch("%a+") do
    if #w >= 3 and not STOP[w] then
      word = w
      break
    end
  end
  local key = tpl:gsub("%%(%a+)%%", { auth = auth, year = book.year and tostring(book.year) or "", word = word,
    id = tostring(book.id) })
  if key == "" then key = "book" .. book.id end
  return key
end

--- One entry as text. opts.file = false leaves the file field out.
-- @tparam table book
-- @tparam string key
-- @tparam[opt] table opts `file`
-- @treturn string
function M.entry(book, key, opts)
  opts = opts or {}
  local ids = book.idents
  local kind = ids.isbn and "book" or ids.doi and "article" or "misc"
  local f = {}
  local function add(name, value)
    if value and value ~= "" then f[#f + 1] = ("  %-9s = {%s}"):format(name, value) end
  end
  local people = people_of(book)
  for i, a in ipairs(people) do people[i] = escape(M.last_first(a)) end
  add("author", table.concat(people, " and "))
  add("title", "{" .. escape(book.title or "") .. "}") -- double braces keep its capitals
  add("year", book.year and tostring(book.year))
  add("publisher", book.publisher and escape(book.publisher))
  add("series", book.series and escape(book.series))
  add("doi", ids.doi)
  add("isbn", ids.isbn)
  if ids.arxiv then
    add("eprint", ids.arxiv)
    add("archiveprefix", "arXiv")
  end
  add("url", ids.url or (ids.doi and "https://doi.org/" .. ids.doi) or (ids.arxiv and "https://arxiv.org/abs/" .. ids.arxiv))
  if #book.tags > 0 then add("keywords", escape(table.concat(book.tags, ", "))) end
  if opts.file ~= false then
    local file = lulibre.files(book.id)[1]
    if file and file.status ~= "missing" then add("file", file.path) end
  end
  return ("@%s{%s,\n%s\n}\n"):format(kind, key, table.concat(f, ",\n"))
end

--- Entries for a list of ids; keys are made unique with a, b, c. Returns
-- the text and the keys in order.
-- @tparam {integer,...} ids
-- @tparam[opt] table opts as for `key` and `entry`
-- @treturn string
-- @treturn {string,...} the keys
function M.export(ids, opts)
  local used, out, keys = {}, {}, {}
  for _, id in ipairs(ids) do
    local book = lulibre.book(id)
    if book then
      local base = M.key(book, opts)
      local key, n = base, 0
      while used[key] do
        n = n + 1
        key = base .. string.char(96 + (n - 1) % 26 + 1) .. (n > 26 and tostring(n // 26) or "")
      end
      used[key] = true
      keys[#keys + 1] = key
      out[#out + 1] = M.entry(book, key, opts)
    end
  end
  return table.concat(out, "\n"), keys
end

-- ---- reading ----

local function clean(v)
  v = v:gsub("\\([&%%$#_])", "%1"):gsub("[{}]", ""):gsub("%s+", " ")
  return (v:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Parse .bib text: { {type=, key=, fields={name=value}, raw={name=text}}, ... }.
-- Field names are lower-cased; braces and escapes are removed from values
-- (raw keeps them as written).
-- @tparam string text
-- @treturn {table,...}
function M.parse(text)
  local entries, pos = {}, 1
  while true do
    local s, e, kind, key = text:find("@(%a+)%s*{%s*([^,%s}]*)%s*,", pos)
    if not s then break end
    pos = e + 1
    local entry = { type = kind:lower(), key = key, fields = {}, raw = {} }
    while true do
      local ns, ne, name = text:find("^%s*([%a_][%w_%-]*)%s*=%s*", pos)
      if not ns then break end
      pos = ne + 1
      local c, value = text:sub(pos, pos), nil
      if c == "{" then
        local depth, i = 0, pos
        while i <= #text do
          local ch = text:sub(i, i)
          if ch == "{" then depth = depth + 1 elseif ch == "}" then
            depth = depth - 1
            if depth == 0 then break end
          end
          i = i + 1
        end
        value, pos = text:sub(pos + 1, i - 1), i + 1
      elseif c == '"' then
        local i = text:find('"', pos + 1, true) or #text
        value, pos = text:sub(pos + 1, i - 1), i + 1
      else
        local i = text:find("[,}\n]", pos) or #text + 1
        value, pos = text:sub(pos, i - 1), i
      end
      entry.fields[name:lower()] = clean(value)
      entry.raw[name:lower()] = value
      pos = (text:find("^%s*,", pos)) and select(2, text:find("^%s*,", pos)) + 1 or pos
    end
    if entry.type ~= "comment" and entry.type ~= "string" and entry.type ~= "preamble" then
      entries[#entries + 1] = entry
    end
    pos = (select(2, text:find("^%s*}", pos)) or pos - 1) + 1
  end
  return entries
end

--- "Last, First and Last, First" -> { "First Last", ... }. A name written
-- in its own braces ("{The Stacks project authors}") is one name as it stands.
-- @tparam string author_field
-- @treturn {string,...}
function M.people(author_field)
  local out = {}
  for person in ((author_field or "") .. " and "):gmatch("(.-)%s+and%s+") do
    local whole = person:match("^%s*{([^{}]*)}%s*$")
    local last, first = person:match("^%s*(.-)%s*,%s*(.-)%s*$")
    local name = whole or (last and (first .. " " .. last)) or person
    name = clean(name)
    if name ~= "" then out[#out + 1] = name end
  end
  return out
end

--- The files an entry names, as absolute paths. Understands a plain path and
-- the JabRef / Zotero forms "desc:path:type;desc:path:type". Relative paths
-- are taken from `dir`, the folder the .bib file is in.
-- @tparam table entry
-- @tparam string dir
-- @treturn {string,...}
function M.files(entry, dir)
  local out = {}
  for piece in (entry.fields.file or ""):gmatch("[^;]+") do
    local path = piece:match("^[^:/]*:(.+):[^:]*$") or piece
    path = path:gsub("^%s+", ""):gsub("%s+$", ""):gsub("\\:", ":")
    if path ~= "" then
      if path:sub(1, 1) == "~" then path = (os.getenv("HOME") or "~") .. path:sub(2) end
      if path:sub(1, 1) ~= "/" and dir then path = dir .. "/" .. path end
      out[#out + 1] = path
    end
  end
  return out
end

--- What an entry says, in the library's terms: { title=, authors=, pubdate=,
-- publisher=, series=, series_index=, tags=, identifiers = { "doi:…", … } }.
-- Fields the entry does not have are absent.
-- @tparam table entry
-- @treturn table
function M.metadata(entry)
  local f, m = entry.fields, { identifiers = {} }
  m.title = f.title
  local people = M.people(entry.raw and entry.raw.author or f.author)
  if #people == 0 then people = M.people(entry.raw and entry.raw.editor or f.editor) end
  if #people > 0 then m.authors = table.concat(people, " & ") end
  m.pubdate = (f.date and f.date:match("^%d%d%d%d%-%d%d%-%d%d")) or (f.date and f.date:match("^%d%d%d%d"))
    or (f.year and f.year:match("%d%d%d%d"))
  m.publisher = f.publisher
  m.series = f.series
  if f.series then m.series_index = (f.number or f.volume or ""):match("^%s*(%d+%.?%d*)%s*$") end
  if f.keywords then
    local tags = {}
    for word in f.keywords:gmatch("[^,;]+") do
      local t = word:gsub("^%s+", ""):gsub("%s+$", "")
      if t ~= "" then tags[#tags + 1] = t end
    end
    if #tags > 0 then m.tags = table.concat(tags, ", ") end
  end
  if f.doi then m.identifiers[#m.identifiers + 1] = "doi:" .. f.doi:gsub("^https?://[^/]*doi%.org/", "") end
  if f.isbn then m.identifiers[#m.identifiers + 1] = "isbn:" .. f.isbn:gsub("[^%dXx]", "") end
  if f.eprint then m.identifiers[#m.identifiers + 1] = "arxiv:" .. f.eprint end
  if f.url and not f.url:find("[,%s]") then m.identifiers[#m.identifiers + 1] = "url:" .. f.url end
  return m
end

--- Metadata that travels with files: every entry of the .bib files in a
-- folder (or of one .bib file) that names a file, keyed by that file's
-- absolute path. This is how a build can say what its own output is.
-- @tparam string path a folder or a .bib file
-- @treturn table `{ [path] = entry }`
function M.sidecar(path)
  local uv = require "luv"
  local bibs, st = {}, uv.fs_stat(path)
  if st and st.type == "directory" then
    local req = uv.fs_scandir(path)
    while req do
      local name = uv.fs_scandir_next(req)
      if not name then break end
      if name:lower():match("%.bib$") then bibs[#bibs + 1] = path .. "/" .. name end
    end
    table.sort(bibs)
  elseif st then
    bibs[1] = path
  end
  local out, n = {}, 0
  for _, bibfile in ipairs(bibs) do
    local fh = io.open(bibfile)
    if fh then
      local dir = bibfile:match("^(.*)/[^/]*$") or "."
      for _, entry in ipairs(M.parse(fh:read("a"))) do
        for _, file in ipairs(M.files(entry, dir)) do
          local real = uv.fs_realpath(file) or file
          if not out[real] then n = n + 1 end
          out[real] = { entry = entry, meta = M.metadata(entry), bib = bibfile }
        end
      end
      fh:close()
    end
  end
  return out, n
end

return M
