--- Where a change to calibre's records goes (design 28, 48). lulibre
-- writes them with calibredb, through the content server or straight to
-- the library folder, as the library's holder allows. Defining calibre
-- here puts a function of yours in calibredb's place: it is called, as a
-- task, for each book of an operation, through this table at the time of
-- the call, and the journal records what it answers as it would
-- calibredb's.
--
--     local stores = require "lulibre.stores"
--     function stores.calibre(book, fields)
--       -- fields: { title = "...", authors = "A & B", tags = "a, b", ... }
--       return true             -- or nil and why it failed
--     end
--
-- The function takes its own route to calibre: the library's holder is its
-- to mind. `stores.calibre = nil` gives the writes back to calibredb.
-- Embedding a record in the book's files stays calibredb's.
--
-- @library lulibre.stores
local core = require "lulibre.stores.core"

local M, own = {}, {}

--- Writes one book's changes; the library's, not a user's to call.
function own._run(handle, book, fields)
  local _ <close> = handle -- unanswered, it fails the write as it closes
  local ok, done, why = pcall(M.calibre, book, fields)
  if not ok then
    core.answer(handle, tostring(done))
  elseif not done then
    core.answer(handle, why or "the store said no")
  else
    core.answer(handle)
  end
end

return setmetatable(M, {
  __index = own,
  __newindex = function(_, key, value)
    rawset(own, key, value)
    if key == "calibre" then core.filled(value ~= nil) end
  end,
})
