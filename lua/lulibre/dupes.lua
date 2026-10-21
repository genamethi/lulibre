--- Finds books whose files hold exactly the same bytes.
-- Two files can be the same only if they have the same size, so dupes reads
-- and hashes (MD5) only the files that share a size with another file. The
-- index stores the hashes.
--
-- @module lulibre.dupes
-- @usage
-- local dupes = require "lulibre.dupes"
-- for _, g in ipairs(dupes.scan()) do
--   print(g.md5, #g.books, "keep", g.keep)
-- end
-- dupes.propose(dupes.gather(groups), "duplicate")   -- what the others know, for review
local edit = require "lulibre.edit"
local junk = require "lulibre.junk"

local M = {}

--- Returns how much a record says about its book. Each group keeps the
-- copy with the richest record.
-- @tparam table book
-- @treturn number
function M.score(book)
  local s = 0
  if not edit.is_unknown(book.author) then s = s + 3 end
  local t = book.title or ""
  if not junk.unlikely_title(t) then s = s + 2 end
  if t ~= t:upper() then s = s + 1 end
  if #book.tags > 0 then s = s + 1 end
  if next(book.idents) then s = s + 1 end
  if book.year then s = s + 1 end
  if book.publisher then s = s + 1 end
  if book.series then s = s + 1 end
  return s
end

-- Every file the library has on disk, as { book=, path=, size= }. A file the
-- indexer has not seen yet has no recorded size; it is asked of the disk.
local function library_files()
  local ok, uv = pcall(require, "luv")
  local out = {}
  for _, f in ipairs(lulibre.sql("SELECT book, path, size FROM files WHERE book > 0 AND status <> 3")) do
    if not f.size and ok then
      local st = uv.fs_stat(f.path)
      f.size = st and st.size
    end
    if f.size and f.size > 0 then out[#out + 1] = f end
  end
  return out
end

--- Hashes the files that need hashing and returns the groups of identical
-- files, the most wasted space first. Each book in a group also has `.file`
-- (its path) and `.score`. Waits, and shows progress.
-- @tparam[opt] table opts `all` hashes every file, not only the files that share a size
-- @treturn {table,...} the groups: `{ { md5=, size=, books = { book, ... }, keep = id }, ... }`
function M.scan(opts)
  opts = opts or {}
  local files = library_files()
  if not opts.all then
    local n, shared = {}, {}
    for _, f in ipairs(files) do n[f.size] = (n[f.size] or 0) + 1 end
    for _, f in ipairs(files) do
      if n[f.size] > 1 then shared[#shared + 1] = f end
    end
    files = shared
  end
  lulibre.each(files, function(f) f.md5 = lulibre.md5(f.path) end, { progress = "hashing" })
  local unreadable = 0
  for _, f in ipairs(files) do
    if not f.md5 then unreadable = unreadable + 1 end
  end

  local by_hash, order = {}, {}
  for _, f in ipairs(files) do
    if f.md5 then
      if not by_hash[f.md5] then
        by_hash[f.md5] = { md5 = f.md5, size = f.size, books = {}, seen = {} }
        order[#order + 1] = by_hash[f.md5]
      end
      local g = by_hash[f.md5]
      if not g.seen[f.book] then -- one book holding the same bytes twice is not a duplicate book
        g.seen[f.book] = true
        local book = lulibre.book(f.book)
        if book then
          book.file, book.score = f.path, M.score(book)
          g.books[#g.books + 1] = book
        end
      end
    end
  end
  local groups = {}
  for _, g in ipairs(order) do
    g.seen = nil
    if #g.books > 1 then
      table.sort(g.books, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        return a.id < b.id
      end)
      g.keep = g.books[1].id
      groups[#groups + 1] = g
    end
  end
  table.sort(groups, function(a, b)
    local wa, wb = a.size * (#a.books - 1), b.size * (#b.books - 1)
    if wa ~= wb then return wa > wb end
    return a.keep < b.keep
  end)
  return groups, { hashed = #files, unreadable = unreadable }
end

--- Returns the books that would be removed if each group kept only its
-- chosen copy.
-- @tparam {table,...} groups as `scan` gives them
-- @treturn {table,...} the books
function M.surplus(groups)
  local ids = {}
  for _, g in ipairs(groups) do
    if not g.skip then
      for _, b in ipairs(g.books) do
        if b.id ~= g.keep then ids[#ids + 1] = b.id end
      end
    end
  end
  return ids
end

--- Returns what the copies to be removed know and the kept copy doesn't, as
-- changes to the kept book. The changes fill empty fields and add tags and
-- identifiers.
-- @tparam {table,...} groups
-- @treturn {table,...} changes `{ id=, field=, value=, op= }`
function M.gather(groups)
  local changes = {}
  for _, g in ipairs(groups) do
    local keep
    for _, b in ipairs(g.books) do
      if b.id == g.keep then keep = b end
    end
    if keep and not g.skip then
      local filled = {}
      for _, b in ipairs(g.books) do
        if b.id ~= g.keep then
          for _, field in ipairs(edit.fields) do
            local theirs, mine = edit.current(b, field), edit.current(keep, field)
            if theirs ~= "" and field ~= "series_index" then
              if field == "tags" or field == "identifiers" then
                if edit.resolve(keep, field, "add", theirs) ~= mine then
                  changes[#changes + 1] = { id = keep.id, field = field, value = theirs, op = "add", from = b.id }
                end
              elseif mine == "" and not filled[field] then
                filled[field] = true
                changes[#changes + 1] = { id = keep.id, field = field, value = theirs, op = "set", from = b.id }
              end
            end
          end
        end
      end
    end
  end
  return changes
end

--- Proposes another book's values for one book: every field where `from`
-- has a value and `to` has none or a different one. Tags and identifiers
-- are proposed as additions. Nothing is written; the proposals wait in
-- review.
-- @tparam table from a book
-- @tparam table to a book
-- @treturn integer how many proposals were made
function M.pull(from, to)
  local proposals = require "lulibre.proposals"
  local n = 0
  for _, field in ipairs(edit.fields) do
    local theirs, mine = edit.current(from, field), edit.current(to, field)
    if theirs ~= "" and theirs ~= mine and (field ~= "series_index" or from.series) then
      local op = (field == "tags" or field == "identifiers") and "add" or "set"
      local ok, added = pcall(proposals.add, to.id, field, theirs,
        { op = op, source = ("book %d"):format(from.id), confidence = mine == "" and 0.9 or 0.5, again = true, as_is = true,
          asked = true })
      if ok and added then n = n + 1 end
    end
  end
  return n
end

--- Turns gathered changes into proposals, so that removing a record loses
-- nothing the record knew.
-- @tparam {table,...} changes
-- @tparam string what where the changes came from ("duplicate", "record with no file")
-- @treturn integer how many proposals were new
function M.propose(changes, what)
  if #changes == 0 then return 0 end
  if not lulibre.policy("carry_metadata", ("keep what the %s records being removed know (%d values) as proposals?"):format(
      what, #changes)) then
    return 0
  end
  local proposals = require "lulibre.proposals"
  local n = 0
  for _, c in ipairs(changes) do
    local ok, added = pcall(proposals.add, c.id, c.field, c.value,
      { op = c.op, source = ("%s %d"):format(what, c.from), confidence = 0.9 })
    if ok and added then n = n + 1 end
  end
  return n
end

--- Returns the library books whose file has this hash. Only hashed files
-- are found; `scan` hashes them.
-- @tparam string md5
-- @treturn {integer,...} ids
function M.books_with(md5)
  local ids = {}
  for _, r in ipairs(lulibre.sql([[SELECT DISTINCT f.book FROM files f JOIN hashes h
      ON h.path = f.path AND h.size = f.size WHERE f.book > 0 AND h.md5 = ? ORDER BY f.book]], md5)) do
    ids[#ids + 1] = r.book
  end
  return ids
end

--- Returns the library books that already hold the bytes of the file at
-- `path`, usually none or one. Reads only library files of exactly the
-- same size.
-- @tparam string path
-- @treturn {integer,...} ids
function M.holders(path)
  local ok, uv = pcall(require, "luv")
  local st = ok and uv.fs_stat(path)
  if not st then return {} end
  local same = lulibre.sql([[SELECT book, path, size FROM files WHERE book > 0 AND (size = ? OR size IS NULL) AND status <> 3
    ORDER BY book]], st.size)
  if #same == 0 then return {} end
  local mine, out, seen = nil, {}, {}
  for _, f in ipairs(same) do
    local size = f.size
    if not size then
      local fst = uv.fs_stat(f.path)
      size = fst and fst.size
    end
    if size == st.size and not seen[f.book] then mine = mine or lulibre.md5(path) end
    if size == st.size and mine and not seen[f.book] and lulibre.md5(f.path) == mine then
      seen[f.book] = true
      out[#out + 1] = f.book
    end
  end
  return out
end

--- Returns the first of `holders(path)`, or nil.
-- @tparam string path
-- @treturn integer|nil
function M.twin(path)
  return M.holders(path)[1]
end

--- Returns a size in bytes in readable form: "1.2 GB", "340.0 MB", "12 kB".
-- @tparam number bytes
-- @treturn string
function M.human(bytes)
  if bytes >= 2 ^ 30 then return ("%.1f GB"):format(bytes / 2 ^ 30) end
  if bytes >= 2 ^ 20 then return ("%.1f MB"):format(bytes / 2 ^ 20) end
  return ("%.0f kB"):format(bytes / 1024)
end

return M
