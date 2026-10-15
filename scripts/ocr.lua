-- Read text from page images with tesseract, for files whose own text layer
-- is missing or garbage. The text and its lines (with their heights, so the
-- title-page reader can tell a title from body text) replace what the index
-- held for a page, where that was no text (little, or garbled) and OCR
-- reads better: the first ocr_pages pages, and any other the index holds
-- that is garbled.
--   :run ocr                 books with no usable text (is:needsocr)
--   :run ocr FILTER          books matching a filter
--   :run ocr all             every book
--   :run ocr --write FILTER  only give the PDFs themselves a text layer (below)
--   lulibre ocr [FILTER]
-- Options: ocr_pages (pages per file, default 3), ocr_lang (default eng).
--
-- With the option ocr_write = "replace" or "keep", each PDF read is also
-- given the text itself, with ocrmypdf (every page, so it takes a while): the
-- new PDF goes into calibre in place of the old one (calibredb add_format),
-- so other programs can search and copy from it. "keep" first copies the old
-- one to ocr_originals, a folder outside the library, so calibre never holds
-- two. Each is in the journal; undo puts a kept original back.
local uv = require "luv"
local features = require "lulibre.features"

local args, write_only = {}, false
for _, a in ipairs({ ... }) do
  if a == "--write" then write_only = true else args[#args + 1] = a end
end
local filter = table.concat(args, " ")
if filter == "" then filter = "is:needsocr" elseif filter == "all" then filter = "" end
local ids = lulibre.ids(filter)
if #ids == 0 then
  print("nothing to OCR")
  return
end

local tesseract
if not write_only then
  local found, why = features.need("tesseract")
  if not found then error("OCR needs tesseract: " .. tostring(why), 0) end
  tesseract = found.tesseract
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
local ids_to_read = write_only and {} or ids
-- A page's text as it stands is kept unless it is no text (little of it, or
-- garbled) or OCR's reading is plainly the better one: OCR of a page that
-- read well is a loss (a title page in large type can come back empty).
local verify = require "lulibre.verify"
local function letters(text)
  return select(2, (text or ""):gsub("%a", ""))
end
local function no_text(text)
  return letters(text) < 40 or verify.garbled(text) > verify.GARBLED
end
local kept = {}
lulibre.each(ids_to_read, function(id)
  local f = lulibre.files(id)[1]
  if f and f.status ~= "missing" then
    local held = {}
    for _, p in ipairs(lulibre.sql("SELECT page, text FROM pages WHERE file = (SELECT id FROM files WHERE book = ? ORDER BY id LIMIT 1)", id)) do
      held[p.page] = p.text
    end
    -- the first ocr_pages, and any further page the index holds that is no text
    local want, last = {}, math.min(f.pages or 1, per_file)
    for page = 1, last do want[#want + 1] = page end
    for page, text in pairs(held) do
      if page > last and no_text(text) then want[#want + 1] = page end
    end
    table.sort(want)
    for _, page in ipairs(want) do
      local old = held[page]
      if old == nil or no_text(old) then
        local pgm = lulibre.render(f.path, page, WIDTH)
        local r = pgm and lulibre.system({ tesseract, "stdin", "stdout", "-l", lang, "tsv" },
          { stdin = pgm, timeout = 180000 })
        if r and r.code == 0 then
          local text, lines = parse(r.stdout)
          if old == nil or letters(text) > letters(old) * 0.5 and verify.garbled(text) < verify.garbled(old) or letters(old) < 40 and letters(text) > letters(old) then
            lulibre.page_put(id, page, { text = text, lines = lines, src = "ocr" })
            table.insert(pages_read, true)
          else
            table.insert(kept, true)
          end
        else
          table.insert(pages_failed, true)
        end
      else
        table.insert(kept, true)
      end
    end
  end
end, { jobs = math.max(1, (uv.available_parallelism() or 4) // 2), progress = "OCR" })
local read, failed = #pages_read, #pages_failed
lulibre.progress(nil)
if not lulibre.headless then lulibre.reload() end
if not write_only then
  print(("OCR read %d pages of %d books in %.0fs%s%s"):format(read, total, (uv.hrtime() - t0) / 1e9,
    #kept > 0 and (", left %d pages whose own text reads better"):format(#kept) or "",
    failed > 0 and (", %d pages failed"):format(failed) or ""))
end

-- ---- the PDFs themselves (ocr_write) ----
local how = lulibre.o.ocr_write
if write_only and how == "off" then
  error('--write gives the PDFs a text layer, which the option ocr_write = "replace" or "keep" allows (it is off)', 0)
end
if how ~= "off" then
  local found, why = features.need("ocrmypdf")
  if not found then
    print("the PDFs were left as they are: " .. tostring(why))
    return
  end
  local edit = require "lulibre.edit"
  local data = lulibre.settings.paths().data_dir
  local keep_dir = how == "keep" and (lulibre.o.ocr_originals ~= "" and lulibre.o.ocr_originals or data .. "/ocr-originals") or nil
  local library = lulibre.o.library:gsub("/+$", "")
  if keep_dir and (keep_dir .. "/"):sub(1, #library + 1) == library .. "/" then
    error(("ocr_originals (%s) is inside the library: calibre would find the originals there"):format(keep_dir), 0)
  end
  local tmp = data .. "/ocr-tmp"
  lulibre.system({ "mkdir", "-p", tmp })
  if keep_dir then lulibre.system({ "mkdir", "-p", keep_dir }) end
  local written, failed_w, batch = 0, {}, nil
  for n, id in ipairs(ids) do
    local f
    for _, file in ipairs(lulibre.files(id)) do
      if file.format == "PDF" and file.status ~= "missing" then f = file end
    end
    if f then
      lulibre.progress(("ocrmypdf %d/%d: book %d"):format(n, #ids, id))
      local out = ("%s/%d.pdf"):format(tmp, id)
      -- --skip-text: pages that have text keep it; only the others are read
      local r, err = lulibre.system({ found.ocrmypdf, "--skip-text", "-l", lang, "--output-type", "pdf", f.path, out },
        { timeout = 3600000 })
      if not r or r.code ~= 0 then
        table.insert(failed_w, ("book %d: %s"):format(id, tostring(err or (r and r.stderr:match("[^\n]*\n?$")) or "?")))
      else
        local kept = ""
        if keep_dir then
          kept = ("%s/%d - %s"):format(keep_dir, id, f.path:match("[^/]+$"))
          local ok, cerr = uv.fs_copyfile(f.path, kept)
          if not ok then
            table.insert(failed_w, ("book %d: the original could not be kept (%s); its PDF is left as it was"):format(id, tostring(cerr)))
            kept = nil
          end
        end
        if kept then
          local cmd = edit.calibredb()
          cmd[#cmd + 1] = "add_format"
          cmd[#cmd + 1] = tostring(id)
          cmd[#cmd + 1] = out
          local w, werr = lulibre.system(cmd, { timeout = 600000 })
          batch = batch or lulibre.store("SELECT coalesce(max(batch), 0) + 1 AS n FROM journal")[1].n
          local good = w and w.code == 0
          lulibre.store([[INSERT INTO journal(batch, book, field, old, new, status, error, ts, label)
            VALUES(?, ?, '(format)', ?, ?, ?, ?, ?, 'ocr')]], batch, id, kept, "PDF given a text layer by ocrmypdf",
            good and "applied" or "failed", not good and tostring(werr or (w and w.stderr)) or nil, os.time())
          if good then written = written + 1 else table.insert(failed_w, ("book %d: calibre did not take the new PDF"):format(id)) end
        end
        uv.fs_unlink(out)
      end
    end
  end
  lulibre.progress(nil)
  if written > 0 then lulibre.reload() end
  print(("%d PDF%s given a text layer%s%s"):format(written, written == 1 and "" or "s",
    keep_dir and (", the originals kept in " .. keep_dir) or "",
    #failed_w > 0 and ("; %d failed: %s"):format(#failed_w, failed_w[1]) or ""))
end
