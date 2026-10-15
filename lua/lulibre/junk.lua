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
  -- a file name with its words after a dash: "titile -equivnorms", "title -crt"
  "^titi?le%s*%-",
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

-- the user's own additions, from the option never_titles; read when it changes
local never_text, never_list
local function never_titles()
  local text = lulibre.o.never_titles or ""
  if text ~= never_text then
    never_text, never_list = text, {}
    for item in text:gmatch("[^,]+") do
      local phrase = item:lower():gsub("^%s+", ""):gsub("%s+$", "")
      if phrase ~= "" then never_list[#never_list + 1] = phrase end
    end
  end
  return never_list
end

-- titles the user vouches for, from the option good_titles
local good_text, good_set
local function good_titles()
  local text = lulibre.o.good_titles or ""
  if text ~= good_text then
    good_text, good_set = text, {}
    for item in text:gmatch("[^,]+") do
      local title = item:lower():gsub("^%s+", ""):gsub("%s+$", "")
      if title ~= "" then good_set[title] = true end
    end
  end
  return good_set
end

--- Is the title one the user has listed as fine (the option good_titles)?
function M.vouched(t)
  return good_titles()[(t or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")] == true
end

--- Is a title unlikely to be one? Junk as M.title has it; or mostly figures;
-- or a single word that is not plainly a word. "Algebra" and "Topology" are
-- titles; "infinite", "E807en" and "tensorprod" are what is left of a file
-- name. The option one_word_titles says how single words are taken: "check"
-- (the default) keeps a capitalised word of letters, "ok" keeps any, "junk"
-- none. A title listed in good_titles is never unlikely.
function M.unlikely_title(t)
  t = (t or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if M.vouched(t) then return false end
  if M.title(t) then return true end
  local digits, letters = select(2, t:gsub("%d", "")), select(2, t:gsub("[%a\128-\255]", ""))
  if digits > 0 and digits * 3 >= letters then return true end
  if not t:find("%s") then
    local how = lulibre.o.one_word_titles
    if how == "ok" then return false end
    if how == "junk" then return true end
    -- a word as a title writes it: a capital, then letters ("Algebra",
    -- "Élasticité"), or all capitals ("ALGEBRA"); at least four letters
    local word = t:match("^[%u\195-\197][%l\128-\255]+$") or t:match("^%u+$")
      or t:match("^[%u\195-\197][%l\128-\255]+[%-'][%a\128-\255]+$") -- Lambda-Rings, Finnegan's
    return not (word and letters >= 4)
  end
  return false
end

function M.title(t)
  if not t then return true end
  t = t:gsub("^%s+", ""):gsub("%s+$", "")
  if M.vouched(t) then return false end
  if #t < 3 or #t > 300 then return true end
  local low = t:lower()
  for _, phrase in ipairs(never_titles()) do
    if low:find(phrase, 1, true) then return true end
  end
  return generic[low] or low:find("^list of") ~= nil or not low:find("%a") or any(low, title_patterns)
end

function M.author(a)
  if not a then return true end
  a = a:gsub("%s+", " "):gsub("^[ ,;]+", ""):gsub("[ ,;]+$", "")
  if a == "" or #a > 200 or not a:find("%a%a") then return true end
  return any(a:lower(), author_patterns)
end

return M
