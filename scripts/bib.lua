-- Export BibTeX.
--   :run bib [FILE]                 the selected books, to FILE (asks if omitted)
--   lulibre bib FILTER... > refs.bib
--   lulibre bib -o refs.bib FILTER...
-- Options: -o FILE, --no-file (leave the file field out), --key TEMPLATE
-- (default %auth%%year%%word%; also %id%).
local bib = require "lulibre.bib"

local args, opts, out, words = { ... }, {}, nil, {}
local i = 1
while i <= #args do
  local a = args[i]
  if a == "-o" then out, i = args[i + 1], i + 1
  elseif a == "--no-file" then opts.file = false
  elseif a == "--key" then opts.key, i = args[i + 1], i + 1
  else words[#words + 1] = a end
  i = i + 1
end

local ids
if lulibre.headless then
  ids = lulibre.ids(table.concat(words, " "))
else
  ids = lulibre.selection()
  out = out or words[1]
  if not out then
    out = lulibre.input { prompt = ("write %d entr%s to: "):format(#ids, #ids == 1 and "y" or "ies"), default = "~/refs.bib" }
    if not out or out == "" then return end
  end
end

local text, keys = bib.export(ids, opts)
if not out then
  io.write(text)
  return
end
out = out:gsub("^~", os.getenv("HOME") or "~")
local mode = "w"
local existing = io.open(out)
if existing then
  existing:close()
  if not lulibre.headless then
    local choice = lulibre.pick({ "append to it", "replace it", "cancel" }, { title = out .. " exists" })
    if not choice or choice == "cancel" then return end
    mode = choice == "append to it" and "a" or "w"
  end
end
local f, err = io.open(out, mode)
if not f then error(err, 0) end
if mode == "a" then f:write("\n") end
f:write(text)
f:close()
print(("%d entr%s written to %s"):format(#keys, #keys == 1 and "y" or "ies", out))
