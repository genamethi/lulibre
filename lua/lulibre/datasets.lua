--- Fetches and finds the databases kept on this machine, so lulibre can
-- look books up without asking any service. `lulibre datasets`
-- (scripts/datasets.lua) is the way to use them.
--
-- The datasets live in lulibre's data folder, beside the index. A file
-- there may be a link to a file kept elsewhere; fetching then renews the
-- file the link points to.
--
-- @services lulibre.datasets
-- @usage
-- local datasets = require "lulibre.datasets"
-- datasets.list                   -- what can be had: { name=, title=, useful=, size=, from=, renewed=, files= }
-- datasets.path("arxiv.json")     -- where a file of one is, if it is here
-- datasets.status(ds)             -- { here=, bytes=, age=, missing={...} }
-- datasets.fetch(ds, { force= })  -- fetch it; true, or nil and why not
-- datasets.adopt("/some/ol_dump_editions_2026-09-30.txt.gz")   -- use a file fetched by other means
local uv = require "luv"

local M = {}

--- The datasets lulibre can fetch: `{ name=, title=, useful=, size=, from=, renewed=, files= }`.
M.list = {
  {
    name = "arxiv",
    title = "arXiv's records",
    useful = "Useful if you have arXiv preprints: the title, authors, subject, DOI and day of submission of every paper.",
    size = "1.7 GB to fetch, 5.6 GB on disk",
    from = "Kaggle (Cornell-University/arxiv), through pixi; needs a Kaggle account",
    renewed = 7,
    files = { { name = "arxiv-metadata-oai-snapshot.json", kaggle = "Cornell-University/arxiv", known = { "^arxiv%-metadata%-oai%-snapshot%.json$" } } },
  },
  {
    name = "openlibrary",
    title = "Open Library's editions and authors",
    useful = "Useful if you have books with an ISBN: title, authors, publisher, year, series and shelf class.",
    size = "9.7 GB to fetch and on disk",
    from = "openlibrary.org's monthly dumps",
    renewed = 30,
    files = {
      { name = "ol_dump_editions_latest.txt.gz", url = "https://openlibrary.org/data/ol_dump_editions_latest.txt.gz", known = { "^ol_dump_editions_.*%.txt%.gz$" } },
      { name = "ol_dump_authors_latest.txt.gz", url = "https://openlibrary.org/data/ol_dump_authors_latest.txt.gz", known = { "^ol_dump_authors_.*%.txt%.gz$" } },
    },
  },
  {
    name = "zbmath",
    title = "zbMATH's links to arXiv",
    useful = "Useful if you have arXiv preprints in mathematics: the zbMATH number of each, without asking.",
    size = "37 MB",
    from = "Zenodo (doi:10.5281/zenodo.8021789), of June 2023",
    renewed = nil, -- a table that was made once
    files = { { name = "zbmath-oa_links.csv", url = "https://zenodo.org/records/8021789/files/oa_links.csv?download=1", known = { "^oa_links%.csv$", "^zbmath%-oa_links%.csv$" } } },
  },
}

--- Returns the dataset with a name, or nil.
-- @tparam string name
-- @treturn table|nil
function M.get(name)
  for _, ds in ipairs(M.list) do
    if ds.name == name then return ds end
  end
  return nil
end

--- Returns the folder the datasets are kept in.
-- @treturn string
function M.dir()
  return lulibre.settings.paths().data_dir
end

--- Returns the path of a dataset's file, if the file is here. A link is followed.
-- @tparam string name the file's name
-- @treturn string|nil
function M.path(name)
  local path = M.dir() .. "/" .. name
  return uv.fs_stat(path) and path or nil
end

--- Returns how much of a dataset is here.
-- @tparam table ds
-- @treturn table `{ here=, bytes=, age=, missing = { names } }`: `here` is true if
-- every file is here, and `age` is the oldest file's age in days
function M.status(ds)
  local st = { here = true, bytes = 0, age = nil, missing = {} }
  for _, f in ipairs(ds.files) do
    local s = uv.fs_stat(M.dir() .. "/" .. f.name)
    if s then
      st.bytes = st.bytes + s.size
      local age = (os.time() - s.mtime.sec) / 86400
      if not st.age or age > st.age then st.age = age end
    else
      st.here = false
      st.missing[#st.missing + 1] = f.name
    end
  end
  return st
end

local function size(bytes)
  if bytes >= 1e9 then return ("%.1f GB"):format(bytes / 1e9) end
  return ("%d MB"):format(math.max(1, bytes // 1e6))
end

--- Returns a dataset's state in a few words: "here: 5.6 GB, 3 days old".
-- @tparam table ds
-- @treturn string
function M.state(ds)
  local st = M.status(ds)
  if st.bytes == 0 then return "not on this machine" end
  local age = st.age < 1 and "fetched today" or ("%d day%s old"):format(st.age // 1, st.age // 1 == 1 and "" or "s")
  local stale = ds.renewed and st.age > ds.renewed and ("; renewed every %d days at the source"):format(ds.renewed) or ""
  if not st.here then return ("partly on this machine (%s missing)"):format(table.concat(st.missing, ", ")) end
  return ("on this machine: %s, %s%s"):format(size(st.bytes), age, stale)
end

local function on_path(program)
  local r = lulibre.system({ "sh", "-c", "command -v " .. program }, { timeout = 5000 })
  return r and r.code == 0
end

-- Run a program that fetches. Without the interface it is given the
-- terminal, so that its own account of how far it is can be seen; with it,
-- it runs behind, and the status line says what is being fetched.
local function run(cmd, note)
  if lulibre.headless then
    local quoted = {}
    for i, a in ipairs(cmd) do quoted[i] = "'" .. a:gsub("'", "'\\''") .. "'" end
    local ok, _, code = os.execute(table.concat(quoted, " "))
    return ok == true, ("exit %s"):format(tostring(code))
  end
  lulibre.progress(note)
  local r, err = lulibre.system(cmd, { timeout = 12 * 3600 * 1000 })
  lulibre.progress(nil)
  if not r then return false, tostring(err) end
  local said = ((r.stderr or "") .. (r.stdout or "")):gsub("%s+$", "")
  return r.code == 0, said:match("[^\n]*$") or ""
end

-- where a file of a dataset is to be written: what its name here points to, if it is a link
local function target(name)
  local path = M.dir() .. "/" .. name
  return uv.fs_realpath(path) or path
end

local function fetch_url(f, opts)
  if not on_path("curl") then return nil, "curl is needed to fetch " .. f.name end
  local to = target(f.name)
  local part = to .. ".part"
  -- One connection, no retries, and -C - takes up a fetch that was broken
  -- off where it stopped: running this again is how a failure is retried.
  local cmd = { "curl", "-L", "--fail", "-C", "-", "-A", require("lulibre.net").agent(), "-o", part }
  cmd[#cmd + 1] = lulibre.headless and "--progress-bar" or "-sS"
  cmd[#cmd + 1] = opts.url or f.url
  local ok, why = run(cmd, ("fetching %s"):format(f.name))
  if not ok then return nil, ("%s was not fetched (%s); what came is kept in %s, and fetching again goes on from there"):format(f.name, why, part) end
  local moved = lulibre.system({ "mv", "-f", part, to }, { timeout = 600000 })
  if not moved or moved.code ~= 0 then return nil, ("%s was fetched to %s but could not be moved into place"):format(f.name, part) end
  return to
end

local function fetch_kaggle(f, opts)
  local cmd
  if opts.with then
    cmd = { opts.with }
  elseif on_path("pixi") then
    cmd = { "pixi", "exec", "kaggle" } -- nothing is installed: pixi keeps the program in its cache
  elseif on_path("kaggle") then
    cmd = { "kaggle" }
  else
    return nil, "fetching from Kaggle needs pixi (https://pixi.sh), which runs Kaggle's program without installing it, or a kaggle on the PATH"
  end
  local program = table.concat(cmd, " ")
  -- into a folder of its own first: a fetch that stops half way leaves the file that was here as it was
  local tmp = M.dir() .. "/" .. f.name .. ".fetch"
  lulibre.system({ "mkdir", "-p", tmp }, { timeout = 5000 })
  for _, a in ipairs { "datasets", "download", f.kaggle, "-p", tmp, "--unzip" } do cmd[#cmd + 1] = a end
  local ok, why = run(cmd, ("fetching %s from Kaggle"):format(f.name))
  local got = tmp .. "/" .. f.name
  if not ok or not uv.fs_stat(got) then
    uv.fs_unlink(got)
    uv.fs_rmdir(tmp)
    local hint = "\nKaggle wants an account: make a token at kaggle.com (Settings, API) and put it in ~/.kaggle/"
    return nil, ("%s was not fetched (%s): %s%s"):format(f.name, program, why ~= "" and why or "no file came", hint)
  end
  local to = target(f.name)
  local moved = lulibre.system({ "mv", "-f", got, to }, { timeout = 600000 })
  if not moved or moved.code ~= 0 then return nil, ("%s was fetched to %s but could not be moved into place"):format(f.name, got) end
  uv.fs_rmdir(tmp)
  return to
end

--- Fetches a dataset's files into the data folder. A dataset that is here
-- and as new as its source is left alone.
-- @tparam table ds
-- @tparam[opt] table opts `force` fetches even if the files are as new as the source;
-- `with` is the program to fetch from Kaggle with; `say(text)` is told what happens
-- @treturn[1] boolean true
-- @treturn[1] string|nil "fresh" if the dataset was left alone
-- @treturn[2] nil
-- @treturn[2] string why not
function M.fetch(ds, opts)
  opts = opts or {}
  local say = opts.say or print
  local st = M.status(ds)
  if st.here and not opts.force and (not ds.renewed or st.age < ds.renewed) then
    say(("%s: %s; nothing to fetch (--force fetches it regardless)"):format(ds.name, M.state(ds)))
    return true, "fresh"
  end
  lulibre.system({ "mkdir", "-p", M.dir() }, { timeout = 5000 })
  for _, f in ipairs(ds.files) do
    local s = uv.fs_stat(M.dir() .. "/" .. f.name)
    local fresh = s and not opts.force and (not ds.renewed or (os.time() - s.mtime.sec) / 86400 < ds.renewed)
    if not fresh then
      say(("%s: fetching %s from %s"):format(ds.name, f.name, f.kaggle and "Kaggle" or (opts.url or f.url):match("^%a+://([^/]+)")))
      local to, why = (f.kaggle and fetch_kaggle or fetch_url)(f, opts)
      if not to then return nil, why end
      say(("%s: %s is at %s"):format(ds.name, f.name, to))
    end
  end
  return true
end

--- Uses a file fetched by other means. The file is linked into the data
-- folder under the name its dataset uses.
-- @tparam string path
-- @treturn[1] table the dataset
-- @treturn[1] string the name
-- @treturn[2] nil
-- @treturn[2] string why not
function M.adopt(path)
  local real = uv.fs_realpath(path)
  if not real or not uv.fs_stat(real) then return nil, ("there is no file %s"):format(path) end
  local base = real:match("[^/]+$")
  for _, ds in ipairs(M.list) do
    for _, f in ipairs(ds.files) do
      for _, pattern in ipairs(f.known) do
        if base:find(pattern) then
          local link = M.dir() .. "/" .. f.name
          if real == (uv.fs_realpath(link) or "") then return ds, f.name end
          lulibre.system({ "mkdir", "-p", M.dir() }, { timeout = 5000 })
          uv.fs_unlink(link)
          local ok, err = uv.fs_symlink(real, link)
          if not ok then return nil, ("%s could not be linked into %s: %s"):format(base, M.dir(), tostring(err)) end
          return ds, f.name
        end
      end
    end
  end
  return nil, ("%s is not a file of a dataset lulibre knows (it goes by the file's name)"):format(base)
end

return M
