-- Read text from page images with tesseract, for files whose own text layer
-- is missing or garbage. The text and its lines (with their heights, so the
-- title-page reader can tell a title from body text) replace what the index
-- held for those pages.
--   :run ocr                 books with no usable text (is:needsocr)
--   :run ocr FILTER          books matching a filter
--   :run ocr all             every book
--   lulibre ocr [FILTER]
-- Options: ocr_pages (pages per file, default 3), ocr_lang (default eng).
local uv = require "luv"

local filter = table.concat({ ... }, " ")
if filter == "" then filter = "is:needsocr" elseif filter == "all" then filter = "" end
local ids = lulibre.ids(filter)
if #ids == 0 then
  print("nothing to OCR")
  return
end

local probe, why = lulibre.system({ "tesseract", "--version" })
if not probe or probe.code ~= 0 then
  error("tesseract is not available: " .. tostring(why or (probe and probe.stderr)), 0)
end

local WIDTH = 1700 -- pixels across the page: about 200 dpi for letter or A4
local PT = 612 / WIDTH -- pixels to points, taking the page to be 8.5 in wide

--- tesseract's TSV -> text and lines with heights
local function parse(tsv)
  local lines, current, last_par = {}, nil, nil
  for row in tsv:gmatch("[^\n]+") do
    local level, _, block, par, line, _, left, top, width, height, _, word =
      row:match("^(%d+)\t(%d+)\t(%d+)\t(%d+)\t(%d+)\t(%d+)\t(%d+)\t(%d+)\t(%d+)\t(%d+)\t([%-%d%.]+)\t?(.*)$")
    if level == "4" then
      local key = block .. "." .. par
      current = { words = {}, size = tonumber(height) * PT, x0 = tonumber(left) * PT, y0 = tonumber(top) * PT,
        x1 = (tonumber(left) + tonumber(width)) * PT, y1 = (tonumber(top) + tonumber(height)) * PT,
        block = key ~= last_par }
      last_par = key
      lines[#lines + 1] = current
    elseif level == "5" and current and word and word:find("%S") then
      current.words[#current.words + 1] = word
    end
  end
  local out, text = {}, {}
  for _, l in ipairs(lines) do
    if #l.words > 0 then
      l.text, l.words = table.concat(l.words, " "), nil
      if l.block and #out > 0 then text[#text + 1] = "" end
      out[#out + 1] = l
      text[#text + 1] = l.text
    end
  end
  return table.concat(text, "\n") .. "\n", out
end

local lang, per_file = lulibre.o.ocr_lang, math.max(1, lulibre.o.ocr_pages)
local total = #ids
local pages_read, pages_failed = {}, {} -- one entry per page; table.insert is safe between tasks

local t0 = uv.hrtime()
lulibre.each(ids, function(id)
  local f = lulibre.files(id)[1]
  if f and f.status ~= "missing" then
    for page = 1, math.min(f.pages or 1, per_file) do
      local pgm = lulibre.render(f.path, page, WIDTH)
      local r = pgm and lulibre.system({ "tesseract", "stdin", "stdout", "-l", lang, "tsv" },
        { stdin = pgm, timeout = 180000 })
      if r and r.code == 0 then
        local text, lines = parse(r.stdout)
        lulibre.page_put(id, page, { text = text, lines = lines, src = "ocr" })
        table.insert(pages_read, true)
      else
        table.insert(pages_failed, true)
      end
    end
  end
end, { jobs = math.max(1, (uv.available_parallelism() or 4) // 2), progress = "OCR" })
local read, failed = #pages_read, #pages_failed
lulibre.progress(nil)
if not lulibre.headless then lulibre.reload() end
print(("OCR read %d pages of %d books in %.0fs%s"):format(read, total, (uv.hrtime() - t0) / 1e9,
  failed > 0 and (", %d pages failed"):format(failed) or ""))
