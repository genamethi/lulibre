-- Read again the pages whose text came out garbled. Some PDFs set their
-- text in fonts that say nothing of which letters their glyphs are: what
-- comes out is U+FFFD, private-use characters, or letters shifted along the
-- alphabet ("zkdw dvvxpswlrqv" for "what assumptions"). This tries, page by
-- page and keeping only what reads better:
--   1. poppler's pdftotext (a reader of its own, which often maps such
--      fonts where MuPDF does not), with its line boxes, so the title page
--      can still be told by the size of its type;
--   2. letters shifted back, when one shift turns the page into words;
-- and names the books that still need OCR (:run ocr). Every file's text is
-- measured again as it is now (is:needsocr goes by it), so a file whose
-- text is still garbled is one :ocr takes.
--   :run reread              books whose text is garbled
--   :run reread FILTER       books matching a filter
--   lulibre reread [FILTER]
-- The option text_fallback = "off" leaves poppler out. poppler is looked for
-- when this runs (lulibre.features); without it, only the shift is tried.
local features = require "lulibre.features"
local verify = require "lulibre.verify"

local filter = table.concat({ ... }, " ")

-- how readable a page is: the share of unreadable characters (lower is
-- better), and the share of its words that are words of three letters or more
local function reading(text)
  local words, good = 0, 0
  for w in (text or ""):gmatch("%S+") do
    words = words + 1
    if w:find("%a%a%a") then good = good + 1 end
  end
  return verify.garbled(text or ""), words > 0 and good / words or 0, words
end

-- readable in its own right: almost no unreadable characters, and words
-- (a page of mathematics has fewer of them than prose)
local function readable(text)
  local g, w, n = reading(text)
  return n >= 5 and g < verify.GARBLED and w >= 0.25
end
-- a page that is not text: more than a few unreadable characters
local function unreadable(text)
  return #(text or "") > 40 and verify.garbled(text) > verify.GARBLED
end

-- a page is read again only when it is not readable, and the new reading
-- replaces it only when that one is, and reads better
local function better(new, old)
  if not readable(new) then return false end
  local ng, nw = reading(new)
  local og, ow = reading(old)
  return ng < og or nw > ow + 0.1
end

-- the commonest English words of two letters or more: running prose is a
-- fifth of them or so, and the same prose with its letters moved has none
local COMMON = {}
for w in ([[the of and to in is that for it as with be on not this are by from we which or an
  at can if have has one will been these its their our then let there where when all any each such]]):gmatch("%S+") do
  COMMON[w] = true
end
local function common_share(text)
  local n, hit = 0, 0
  for w in text:lower():gmatch("%a%a+") do
    n = n + 1
    if COMMON[w] then hit = hit + 1 end
  end
  return n > 0 and hit / n or 0, n
end
local function shift(text, k)
  return (text:gsub("%a", function(c)
    local base = c:match("%l") and 97 or 65
    return string.char((c:byte() - base + k) % 26 + base)
  end))
end
-- a font that numbers its glyphs a few places off: every character code
-- moved by k ("zkdw" for "what", "+" for "(")
local function shift_codes(text, k)
  return (text:gsub("[\33-\126]", function(c)
    local b = c:byte() - k
    if b < 33 then b = b + 94 end
    return string.char(b)
  end))
end

-- The shift that turns a file's pages into English, if one does: worked out
-- from its longer pages (eighty words or more), which must all but agree,
-- each having almost no common words as it is and plenty once moved back.
-- Returns a function that undoes it, or nil.
local function file_shift(texts)
  local votes, long = {}, 0
  for _, text in ipairs(texts) do
    local now, n = common_share(text)
    if n >= 80 and verify.garbled(text) <= verify.GARBLED then
      long = long + 1
      if now <= 0.03 then
        -- the best of each way of moving back; the character codes win a near
        -- tie, since moving them mends the punctuation too
        local best = { codes = { now }, letters = { now } }
        for k = 1, 25 do
          for name, f in pairs { codes = shift_codes, letters = shift } do
            local share = common_share(f(text, k))
            if share > best[name][1] then best[name] = { share, k } end
          end
        end
        local name = best.codes[1] >= best.letters[1] - 0.02 and "codes" or "letters"
        local top = best[name]
        if top[2] and top[1] >= 0.15 then
          local key = name .. top[2]
          votes[key] = (votes[key] or 0) + 1
        end
      end
    end
  end
  for key, n in pairs(votes) do
    if n >= 1 and n >= long * 0.6 then
      local name, k = key:match("^(%a+)(%d+)$")
      local f = name == "codes" and shift_codes or shift
      return function(s) return f(s, tonumber(k)) end
    end
  end
  return nil
end

-- pdftotext -bbox-layout: each page's text, and its lines with their heights
local function unescape(s)
  return (s:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&amp;", "&"))
end
local function poppler_pages(pdftotext, path, first, last)
  local r = lulibre.system({ pdftotext, "-bbox-layout", "-enc", "UTF-8", "-f", tostring(first), "-l", tostring(last), path, "-" },
    { timeout = 120000 })
  if not r or r.code ~= 0 then return nil end
  local pages, n = {}, first - 1
  for body in r.stdout:gmatch("<page[^>]*>(.-)</page>") do
    n = n + 1
    local lines, texts = {}, {}
    for block in body:gmatch("<block[^>]*>(.-)</block>") do
      local first_in_block = true
      for attrs, inner in block:gmatch("<line([^>]*)>(.-)</line>") do
        local function at(name) return tonumber(attrs:match(name .. '="([%-%d.eE+]+)"')) or 0 end
        local x0, y0, x1, y1 = at("xMin"), at("yMin"), at("xMax"), at("yMax")
        local words = {}
        for w in inner:gmatch("<word[^>]*>(.-)</word>") do words[#words + 1] = unescape(w) end
        if #words > 0 then
          local text = table.concat(words, " ")
          texts[#texts + 1] = text
          -- a line box is about one and a quarter times the type's size
          lines[#lines + 1] = { text = text, size = (y1 - y0) / 1.25, x0 = x0, y0 = y0, x1 = x1, y1 = y1, block = first_in_block }
          first_in_block = false
        end
      end
    end
    pages[n] = { text = table.concat(texts, "\n"), lines = lines }
  end
  return pages
end

-- which books: those named, else every book with a file that was read
-- (each page is looked at, and read again only if it is not readable)
local ids = lulibre.ids(filter ~= "" and filter or "in:library")
if #ids == 0 then
  print("no garbled text to read again")
  return
end

local poppler, why_not
if lulibre.o.text_fallback ~= "off" then
  local found
  found, why_not = features.need("poppler")
  poppler = found and found.pdftotext
else
  why_not = "text_fallback is off"
end

local done = { poppler = 0, shifted = 0, books = 0 }
local still = {}
for k, id in ipairs(ids) do
  lulibre.progress(("reading again %d/%d"):format(k, #ids))
  local f = lulibre.sql([[SELECT id, path, format FROM files WHERE book = ? AND status = 1 ORDER BY id LIMIT 1]], id)[1]
  if f then
    local pages = lulibre.sql("SELECT page, text FROM pages WHERE file = ? ORDER BY page", f.id)
    local changed = false
    -- poppler, for the run of opening pages the index holds
    local theirs
    local poor = false
    for _, p in ipairs(pages) do
      if unreadable(p.text) then poor = true end
    end
    if poppler and poor and f.format == "PDF" and #pages > 0 then
      local last = 0
      for _, p in ipairs(pages) do
        if p.page == last + 1 then last = p.page end
      end
      if last > 0 then theirs = poppler_pages(poppler, f.path, 1, last) end
    end
    -- a font that moved its letters: one shift for the whole file
    local texts = {}
    for _, p in ipairs(pages) do texts[#texts + 1] = p.text or "" end
    local undo = file_shift(texts)
    -- (a page already in English is not moved: its common words say so)
    local function readable_as_is(text) return common_share(text) > 0.05 end
    for _, p in ipairs(pages) do
      local text = p.text or ""
      local got = theirs and theirs[p.page]
      if got and unreadable(text) and better(got.text, text) then
        lulibre.page_put(id, p.page, { text = got.text, lines = got.lines, src = "poppler" })
        text = got.text
        done.poppler = done.poppler + 1
        changed = true
      end
      local undo_here = undo and not readable_as_is(text)
      if undo_here then
        local fixed = undo(text)
        local lines = {}
        for _, l in ipairs(lulibre.lines(id, p.page)) do
          l.text = undo(l.text)
          lines[#lines + 1] = l
        end
        lulibre.page_put(id, p.page, { text = fixed, lines = #lines > 0 and lines or nil, src = "unshifted" })
        done.shifted = done.shifted + 1
        changed = true
        text = fixed
      end
    end
    if changed then done.books = done.books + 1 end
    -- every file is measured as it would be now (is:needsocr goes by it)
    lulibre.text_measure(id)
    -- what is still not text
    local all = {}
    for _, p in ipairs(lulibre.sql("SELECT text FROM pages WHERE file = ? ORDER BY page", f.id)) do all[#all + 1] = p.text or "" end
    local joined = table.concat(all, "\n")
    if #joined > 200 and verify.garbled(joined) > verify.GARBLED then still[#still + 1] = id end
  end
end
lulibre.progress(nil)
verify.forget()

local out = { ("%d book%s looked at: %d now read better by poppler (%d pages), %d pages shifted back to letters")
  :format(#ids, #ids == 1 and "" or "s", done.books, done.poppler, done.shifted) }
if not poppler then out[#out + 1] = "poppler was not used: " .. tostring(why_not) end
if #still > 0 then
  table.sort(still)
  out[#out + 1] = ("%d still have no text worth the name: :run ocr id:%s (and the like) reads them from the page images")
    :format(#still, still[1])
  out[#out + 1] = "  " .. table.concat(still, " ", 1, math.min(#still, 40)) .. (#still > 40 and " ..." or "")
end
print(table.concat(out, "\n"))
