-- Bring loose files into calibre with real metadata instead of "Unknown".
-- Scans a directory tree, reads each ebook's first pages, and shows what it
-- would add; you correct what needs correcting, then w adds them.
--   :run onboard DIR
--   lulibre run onboard DIR            list what would be added
--   lulibre run onboard DIR --apply    add them all
local bib = require "lulibre.bib"
local dupes = require "lulibre.dupes"
local edit = require "lulibre.edit"
local extract = require "lulibre.extract"
local uv = require "luv"

local dir, apply
for _, a in ipairs({ ... }) do
  if a == "--apply" then apply = true else dir = a end
end
if not dir then error("give the directory to scan", 0) end
dir = dir:gsub("^~", os.getenv("HOME") or "~"):gsub("/+$", "")

local EXT = { pdf = true, djvu = true, djv = true, epub = true, mobi = true, azw3 = true, fb2 = true }
local paths = {}
local function scan(d)
  local req = uv.fs_scandir(d)
  if not req then return end
  while true do
    local name, kind = uv.fs_scandir_next(req)
    if not name then break end
    local p = d .. "/" .. name
    if kind == "directory" then
      if not name:find("^%.") then scan(p) end
    elseif EXT[(name:match("%.(%w+)$") or ""):lower()] then
      paths[#paths + 1] = p
    end
  end
end
scan(dir)
table.sort(paths)
if #paths == 0 then
  print("no ebook files under " .. dir)
  return
end

local function stem(path)
  return (path:gsub("^.*/", ""):gsub("%.%w+$", ""):gsub("[_]+", " "))
end

-- metadata that came with the files: .bib files in these folders whose
-- entries name them (a build can write one beside its output)
local sidecar, seen_dir = {}, {}
for _, path in ipairs(paths) do
  local d = path:match("^(.*)/[^/]*$")
  if not seen_dir[d] then
    seen_dir[d] = true
    for file, known in pairs(bib.sidecar(d)) do sidecar[file] = known end
  end
end

-- read the files, a few at a time, off the main thread
local items = {}
lulibre.each(paths, function(path, i)
  local item = { path = path, title = stem(path), authors = "", tags = "", idents = {}, include = true, note = "" }
  local known = sidecar[uv.fs_realpath(path) or path]
  if known then
    -- the .bib beside the file says what it is; nothing needs guessing
    local m = known.meta
    item.title, item.authors, item.tags = m.title or item.title, m.authors or "", m.tags or ""
    item.idents, item.series, item.series_index = m.identifiers, m.series, m.series_index
    item.pubdate, item.publisher = m.pubdate, m.publisher
    item.known = true -- checked by MD5 below, so calibre's own title check is not needed
    item.note = "from " .. known.bib:gsub("^.*/", "")
  else
    local d, why = lulibre.extract(path, { pages = lulibre.o.pages, layout_pages = 3 })
    if d then
      local pages, text = {}, {}
      for n, pg in ipairs(d.page) do
        if n <= 3 then pages[n] = pg.lines end
        text[n] = pg.text
      end
      local got = {}
      for _, c in ipairs(extract.from_doc { path = path, title = d.meta.title, author = d.meta.author,
          pages = pages, text = table.concat(text, "\f") }) do
        if c.field == "identifiers" then
          item.idents[#item.idents + 1] = c.value
        elseif not got[c.field] then -- candidates come strongest first
          got[c.field] = true
          if c.field == "title" then item.title = c.value
          elseif c.field == "authors" then item.authors = c.value
          elseif c.field == "tags" then item.tags = c.value end
          item.note = item.note .. (item.note ~= "" and ", " or "") .. c.field .. ": " .. c.source
        end
      end
    else
      item.note = "unreadable: " .. tostring(why)
    end
  end
  -- the same bytes already in the library, perhaps under another title?
  local twin = dupes.twin(path)
  if twin then
    item.include = false
    item.note = ("identical to book %d's file (MD5): already in the library"):format(twin)
  else
    local quoted = item.title:gsub('"', '\\"')
    local okc, n = pcall(lulibre.count, ('title:="%s"'):format(quoted))
    if okc and n > 0 then
      -- a record whose own file has gone missing can take this file, if it
      -- is plainly the same work: same title, and no other author
      local okm, orphans = pcall(lulibre.ids, ('title:="%s" is:missing'):format(quoted))
      local orphan = okm and #orphans == 1 and n == 1 and lulibre.book(orphans[1])
      local same_author = orphan and (edit.is_unknown(orphan.author) or item.authors == ""
        or lulibre.fold(orphan.author) == lulibre.fold(item.authors))
      if orphan and same_author then
        item.attach = orphan.id
        item.note = ("gives book %d its missing file back"):format(orphan.id)
      elseif not known then
        item.include = false
        item.note = "a book with this title is already in the library"
      end
    end
  end
  items[i] = item
end, { progress = "reading" })

local function add_all()
  local added, skipped, attached, failed, follow = 0, 0, 0, {}, {}
  local todo = {}
  for _, it in ipairs(items) do
    if it.include then todo[#todo + 1] = it end
  end
  for n, it in ipairs(todo) do
    lulibre.progress(("adding %d/%d"):format(n, #todo))
    local args = edit.calibredb()
    if it.attach then
      args[#args + 1] = "add_format"
      args[#args + 1] = tostring(it.attach)
      args[#args + 1] = it.path
      local r, err = lulibre.system(args, { timeout = 300000 })
      if r and r.code == 0 then attached = attached + 1
      else failed[#failed + 1] = it.path .. ": " .. (err or (r.stdout .. r.stderr):match("[^\n]*$") or "?") end
      goto continue
    end
    args[#args + 1] = "add"
    args[#args + 1] = "--title"
    args[#args + 1] = it.title
    if it.authors ~= "" then
      args[#args + 1] = "--authors"
      args[#args + 1] = it.authors
    end
    if it.tags ~= "" then
      args[#args + 1] = "--tags"
      args[#args + 1] = it.tags
    end
    for _, ident in ipairs(it.idents) do
      args[#args + 1] = "--identifier"
      args[#args + 1] = ident
    end
    if it.series then
      args[#args + 1] = "--series"
      args[#args + 1] = it.series
      if it.series_index then
        args[#args + 1] = "--series-index"
        args[#args + 1] = tostring(it.series_index)
      end
    end
    if it.known then args[#args + 1] = "--duplicates" end
    args[#args + 1] = it.path
    local r, err = lulibre.system(args, { timeout = 300000 })
    local out = r and (r.stdout .. r.stderr) or ""
    local new_id = r and r.code == 0 and tonumber(out:match("Added book ids:%s*(%d+)"))
    if new_id and (it.pubdate or it.publisher) then
      -- calibredb add has no option for these; they follow as an ordinary change
      follow[#follow + 1] = { id = new_id, field = "pubdate", value = it.pubdate or "" }
      follow[#follow + 1] = { id = new_id, field = "publisher", value = it.publisher or "" }
    end
    if r and r.code == 0 and out:find("Added book ids") then added = added + 1
    elseif r and r.code == 0 then skipped = skipped + 1 -- calibre found a duplicate
    else failed[#failed + 1] = it.path .. ": " .. (err or out:match("[^\n]*$") or "?") end
    ::continue::
  end
  lulibre.progress(nil)
  if added + attached > 0 then lulibre.reload() end
  if #follow > 0 then
    local keep = {}
    for _, c in ipairs(follow) do
      if c.value ~= "" then keep[#keep + 1] = c end
    end
    edit.apply(keep, { label = "onboard" })
  end
  local msg = ("added %d, %d already in calibre"):format(added, skipped)
  if attached > 0 then msg = msg .. (", %d files given back to their books"):format(attached) end
  if #failed > 0 then msg = msg .. (", %d failed: %s"):format(#failed, failed[1]) end
  return msg, #failed
end

if lulibre.headless then
  for _, it in ipairs(items) do
    print(("%s %-34s | %-28s | %-22s | %s"):format(it.include and "+" or " ", it.title:sub(1, 34), it.authors:sub(1, 28),
      it.tags:sub(1, 22), it.path:sub(#dir + 2) .. (it.attach and ("   -> book " .. it.attach) or "")))
  end
  if apply then print((add_all())) else print(("%d files; --apply adds the ones marked +"):format(#items)) end
  return
end

local function rows()
  local out = {}
  for i, it in ipairs(items) do
    out[i] = { it.include and "+" or "", it.title, it.authors, it.tags, it.path:sub(#dir + 2), it.note,
      style = not it.include and "dim" or (it.authors == "" and "warn" or nil) }
  end
  return out
end
local function title()
  local n = 0
  for _, it in ipairs(items) do n = n + (it.include and 1 or 0) end
  return ("onboard  %d of %d files from %s"):format(n, #items, dir)
end
local p <close> = lulibre.panel {
  title = title(), help = "Space include   t title   a authors   s subject   w add to calibre   q close",
  columns = { { "", 1 }, { "Title", -3 }, { "Authors", -2 }, { "Subject", 20 }, { "File", -2 }, { "From", -2 } },
  rows = rows(), height = 0.6,
}
local suggest = require "lulibre.suggest"
while true do
  local key, row = p:wait()
  if not key then return end
  local it = items[row]
  if key == "w" then
    p:close()
    local msg, nfailed = add_all()
    lulibre.notify(msg, nfailed > 0 and "error" or nil)
    return
  elseif it and key == "<Space>" then
    it.include = not it.include
    p:cursor(row + 1)
  elseif it and key == "t" then
    it.title = lulibre.input { prompt = "title: ", default = it.title } or it.title
  elseif it and key == "a" then
    it.authors = lulibre.input { prompt = "authors: ", default = it.authors, separator = " & ",
      suggestions = suggest.for_field("authors", {}) } or it.authors
  elseif it and key == "s" then
    it.tags = lulibre.input { prompt = "subject: ", default = it.tags, separator = ", ",
      suggestions = suggest.for_field("tags", {}) } or it.tags
  end
  p:rows(rows())
  p:title(title())
end
