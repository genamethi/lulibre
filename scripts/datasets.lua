-- Databases for looking books up without asking anybody: see what there is,
-- fetch what is wanted. Run it again whenever: what is here and fresh is
-- left alone.
--   lulibre datasets                 say what there is, and ask which to fetch
--   lulibre datasets list            only say
--   lulibre datasets fetch NAME...   fetch these (or `all`); --force though they are fresh
--   lulibre datasets add FILE...     use files fetched by other means (they are linked, not copied)
-- In the interface, :datasets picks one to fetch.
local datasets = require "lulibre.datasets"

local args, force, with = {}, false, nil
do
  local raw, i = { ... }, 1
  while i <= #raw do
    if raw[i] == "--force" then force = true
    elseif raw[i] == "--with" then
      i = i + 1
      with = raw[i]
    else args[#args + 1] = raw[i] end
    i = i + 1
  end
end

local function describe()
  local out = { ("Databases for looking books up without asking anybody. They are kept in %s."):format(datasets.dir()), "" }
  for i, ds in ipairs(datasets.list) do
    out[#out + 1] = ("  %d  %-12s %s  [%s]"):format(i, ds.name, ds.title, datasets.state(ds))
    out[#out + 1] = ("       %s"):format(ds.useful)
    out[#out + 1] = ("       %s; from %s."):format(ds.size, ds.from)
    out[#out + 1] = ""
  end
  return out
end

local function fetch(names)
  local failed = 0
  for _, name in ipairs(names) do
    local ds = datasets.get(name)
    if not ds then
      print(("there is no dataset '%s' (there are: arxiv, openlibrary, zbmath)"):format(name))
      failed = failed + 1
    else
      local ok, why = datasets.fetch(ds, { force = force, with = with })
      if not ok then
        print(why)
        failed = failed + 1
      end
    end
  end
  if failed > 0 then error(("%d of %d not fetched"):format(failed, #names), 0) end
end

-- "1 3", "arxiv,zbmath", "all" -> names
local function chosen(answer)
  local names, seen = {}, {}
  for word in answer:lower():gmatch("[%w]+") do
    local ds = datasets.list[tonumber(word) or 0] or datasets.get(word)
    if word == "all" or word == "a" then
      for _, d in ipairs(datasets.list) do
        if not seen[d.name] then names[#names + 1], seen[d.name] = d.name, true end
      end
    elseif ds and not seen[ds.name] then
      names[#names + 1], seen[ds.name] = ds.name, true
    elseif not ds then
      return nil, word
    end
  end
  return names
end

local verb = args[1]
if verb == "list" then
  print(table.concat(describe(), "\n"))
elseif verb == "fetch" then
  local names, bad = chosen(table.concat(args, " ", 2))
  if not names then error(("there is no dataset '%s' (there are: arxiv, openlibrary, zbmath)"):format(bad), 0) end
  if #names == 0 then error("datasets fetch NAME... (arxiv, openlibrary, zbmath, or all)", 0) end
  fetch(names)
elseif verb == "add" then
  if #args < 2 then error("datasets add FILE...", 0) end
  for i = 2, #args do
    local ds, name = datasets.adopt(args[i])
    print(ds and ("%s: %s is now used as %s"):format(ds.name, args[i], name) or name)
  end
elseif verb then
  error(("datasets: unknown word '%s' (list, fetch NAME..., add FILE...)"):format(verb), 0)
elseif lulibre.headless then
  print(table.concat(describe(), "\n"))
  io.write("Fetch which? Numbers or names, `all`, or nothing to leave things as they are: ")
  io.flush()
  local answer = io.read("l")
  if not answer or answer:match("^%s*$") then
    print("nothing fetched. `lulibre datasets` asks again whenever you like")
    return
  end
  local names, bad = chosen(answer)
  if not names then error(("'%s' is not one of them"):format(bad), 0) end
  fetch(names)
else
  -- in the interface: pick one; it is fetched behind
  local items = {}
  for i, ds in ipairs(datasets.list) do items[i] = ("%-12s %s  [%s]  %s"):format(ds.name, ds.title, datasets.state(ds), ds.useful) end
  local _, index = lulibre.pick(items, { title = "fetch a database for looking books up offline" })
  if index then
    local ds = datasets.list[index]
    local ok, why = datasets.fetch(ds, { force = force, with = with, say = function(text) lulibre.log(text) end })
    print(ok and ("%s: %s"):format(ds.name, datasets.state(ds)) or why)
  end
end
