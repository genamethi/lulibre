--- The OCR reader (design 37, 48). lulibre reads page images with
-- tesseract on its own workers. Defining read here puts a function of
-- yours in tesseract's place: it is called, as a task, for each page OCR
-- is to read, through this table at the time of the call.
--
--     local ocr = require "lulibre.ocr"
--     function ocr.read(path, page, lang)
--       local r = lulibre.system({ "my-ocr", path, tostring(page) })
--       return r and r.code == 0 and r.stdout or nil
--     end
--
-- read returns the page's text (lines; a blank line before a paragraph),
-- or a list of lines `{ text=, size=, x0=, y0=, x1=, y1=, block= }`, or
-- nil when it could not read the page. `ocr.read = nil` gives the pages
-- back to tesseract.
--
-- @library lulibre.ocr
local core = require "lulibre.ocr.core"

local M, own = {}, {}

--- Reads the pages of a request from the indexer; the indexer's, not a
-- user's to call.
function own._run(handle, path, pages, lang)
  local _ <close> = handle -- unanswered, it fails the request as it closes
  local results, why = {}, nil
  for i, page in ipairs(pages) do
    local ok, text = pcall(M.read, path, page, lang)
    if ok then
      results[i] = text or false
    else
      results[i] = false
      why = why or tostring(text)
    end
  end
  core.answer(handle, results, why)
end

return setmetatable(M, {
  __index = own,
  __newindex = function(_, key, value)
    rawset(own, key, value)
    if key == "read" then core.filled(value ~= nil) end
  end,
})
