-- Titles and authors that are artefacts, not metadata: build file names,
-- download error pages, the name of the program that made the PDF.
-- All patterns are matched against the lower-cased value.
local M = {}

local title_patterns = {
  "^%d%d%d%d_book_", "_print%.indd$", "%.indd$", "^untitled", "^microsoft word",
  "^%d+_%d+_", "^pii:", "^doi:", "^%d%d%d%d%d%d+$",
  "%.dvi%s*$", "%.pdf%s*$", "%.tex%s*$", "%.ps%s*$", "%.djvu%s*$",
  "_book_printpdf", "^978%-[%d%-]+%.pdf", "^978%-[%d%-]+$", "^%w:\\",
  "cdn%d*%.booksdl", "timeout occurred", "bad gateway", "captcha",
  "^safari$", "^document%s*djvu$", "^getting ready$", "^copyright page$",
  "^series editors?$", "^editorial.board$", "^joined document",
  "^arxiv:", "service temporarily unavailable", "^%d%d%d %a+ ?%a* ?%a*$", "page not found",
  "access denied", "just a moment",
}

-- headings that are never a book's title on their own
local generic = {}
for w in ([[preface content contents index introduction bibliography references
  appendix abstract title chapter part note notes editorial copyright
  acknowledgements acknowledgments]]):gmatch("%S+") do generic[w] = true end

local author_patterns = {
  "^unknown$", "^user$", "^admin$", "^administrator$", "^owner$", "^guest$", "^default$",
  "^microsoft", "^word$", "^acrobat", "^pdf", "^latex", "^dvips", "^ghostscript",
  "^tex%f[%W]", "^scan", "^hp%f[%W]", "^canon", "^epson", "^[%W%d_]*$",
}

local function any(s, patterns)
  for _, p in ipairs(patterns) do
    if s:find(p) then return true end
  end
  return false
end

function M.title(t)
  if not t then return true end
  t = t:gsub("^%s+", ""):gsub("%s+$", "")
  if #t < 3 or #t > 300 then return true end
  local low = t:lower()
  return generic[low] or low:find("^list of") ~= nil or not low:find("%a") or any(low, title_patterns)
end

function M.author(a)
  if not a then return true end
  a = a:gsub("%s+", " "):gsub("^[ ,;]+", ""):gsub("[ ,;]+$", "")
  if a == "" or #a > 200 or not a:find("%a%a") then return true end
  return any(a:lower(), author_patterns)
end

return M
