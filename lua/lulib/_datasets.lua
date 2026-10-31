--- Fetches and finds the databases kept on this machine, so that lulibre can look
-- books up without asking any service (:datasets). They live beside the index's
-- online answers. A file there may be a link to one kept elsewhere; fetching then
-- renews the file the link points to.
--
-- @library lulib._datasets
local luv = require "luv"

local M = {}

--- The datasets lulibre can fetch: `{ name=, title=, useful=, size=, from=, renewed=, files= }`.
M.list = {
  {
    name = "arxiv", title = "arXiv's records",
    useful = "Useful if you have arXiv preprints: the title, authors, subject, DOI and day of submission of every paper.",
    size = "1.7 GB to fetch, 5.6 GB on disk",
    from = "Kaggle (Cornell-University/arxiv), through pixi; needs a Kaggle account",
    renewed = 7,
    files = { { name = "arxiv-metadata-oai-snapshot.json", kaggle = "Cornell-University/arxiv", known = { "^arxiv%-metadata.*%.json$" } } },
  },
  {
    name = "openlibrary", title = "Open Library's editions and authors",
    useful = "Useful if you have books with an ISBN: title, authors, publisher, year, series and shelf class.",
    size = "9.7 GB to fetch and on disk",
    from = "openlibrary.org's monthly dumps",
    renewed = 30,
    files = {
      { name = "ol_dump_editions_latest.txt.gz", url = "https://openlibrary.org/data/ol_dump_editions_latest.txt.gz", known = { "^ol_dump_editions.*%.gz$" } },
      { name = "ol_dump_authors_latest.txt.gz", url = "https://openlibrary.org/data/ol_dump_authors_latest.txt.gz", known = { "^ol_dump_authors.*%.gz$" } },
    },
  },
  {
    name = "zbmath", title = "zbMATH's links to arXiv",
    useful = "Useful if you have arXiv preprints in mathematics: the zbMATH number of each, without asking.",
    size = "37 MB",
    from = "Zenodo (doi:10.5281/zenodo.8021789), of June 2023",
    renewed = nil, -- a table that was made once
    files = { { name = "zbmath-oa_links.csv", url = "https://zenodo.org/records/8021789/files/oa_links.csv?download=1", known = { "oa_links.*%.csv$" } } },
  },
}

--- The dataset with a name, or nil.
function M.get(name)
  for _, ds in ipairs(M.list) do
    if ds.name == name then return ds end
  end
  return nil
end

--- The folder they are kept in.
function M.dir()
  return (setman.get("path.netdb"):gsub("/[^/]*$", ""))
end

--- The path of a dataset's file, if it is here. A link is followed.
function M.path(name)
  local path = M.dir() .. "/" .. name
  return luv.fs_stat(path) and path or nil
end

--- How much of a dataset is here: `{ here=, bytes=, age=, missing = { names } }`;
-- here, every file is; age, the oldest file's, in days.
function M.status(ds)
  local st = { here = true, bytes = 0, age = nil, missing = {} }
  for _, f in ipairs(ds.files) do
    local s = luv.fs_stat(M.dir() .. "/" .. f.name)
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

--- A dataset's state in a few words.
function M.state(ds)
  local st = M.status(ds)
  if st.bytes == 0 then return "not on this machine" end
  if not st.here then return ("partly on this machine (%s missing)"):format(table.concat(st.missing, ", ")) end
  local age = st.age < 1 and "fetched today" or ("%d day%s old"):format(st.age // 1, st.age // 1 == 1 and "" or "s")
  local stale = ds.renewed and st.age > ds.renewed and ("; renewed every %d days at the source"):format(ds.renewed) or ""
  return ("on this machine: %s, %s%s"):format(size(st.bytes), age, stale)
end

local function on_path(program)
  local r = utils.exec({ "sh", "-c", "command -v " .. program }, { timeout = 5000 })
  return r and r.code == 0
end

local function run(cmd, note)
  uiman.progress(note)
  local r, err = utils.exec(cmd, { timeout = 12 * 3600 * 1000 })
  uiman.progress(nil)
  if not r then return false, tostring(err) end
  local said = ((r.stderr or "") .. (r.stdout or "")):gsub("%s+$", "")
  return r.code == 0, said:match("[^\n]*$") or ""
end

-- where a file of a dataset is to be written: what its name here points to, if a link
local function target(name)
  local path = M.dir() .. "/" .. name
  return luv.fs_realpath(path) or path
end

local function fetch_url(f, o)
  if not on_path("curl") then return nil, "curl is needed to fetch " .. f.name end
  local to = target(f.name)
  local part = to .. ".part"
  -- One connection, no retries; -C - takes up a fetch broken off where it stopped:
  -- running this again is how a failure is retried.
  local ok, why = run({ "curl", "-L", "--fail", "-C", "-", "-A", require("net").agent(setman.get("contact_email")), "-o", part, "-sS", o.url or f.url },
                      ("fetching %s"):format(f.name))
  if not ok then return nil, ("%s was not fetched (%s); what came is kept in %s, and fetching again goes on from there"):format(f.name, why, part) end
  local done, err = luv.fs_rename(part, to)
  if not done then return nil, ("%s was fetched to %s but could not be moved into place: %s"):format(f.name, part, tostring(err)) end
  return to
end

local function fetch_kaggle(f, o)
  local cmd
  if o.with then
    cmd = { o.with }
  elseif on_path("pixi") then
    cmd = { "pixi", "exec", "kaggle" } -- nothing is installed: pixi keeps the program in its cache
  elseif on_path("kaggle") then
    cmd = { "kaggle" }
  else
    return nil, "fetching from Kaggle needs pixi (https://pixi.sh), which runs Kaggle's program without installing it, or kaggle itself"
  end
  local program = table.concat(cmd, " ")
  -- into a folder of its own first: a fetch that stops half way leaves the file that was here as it was
  local tmp = M.dir() .. "/" .. f.name .. ".fetch"
  luv.fs_mkdir(tmp, 493)
  for _, a in ipairs { "datasets", "download", f.kaggle, "-p", tmp, "--unzip" } do cmd[#cmd + 1] = a end
  local ok, why = run(cmd, ("fetching %s from Kaggle"):format(f.name))
  local got = tmp .. "/" .. f.name
  if not ok or not luv.fs_stat(got) then
    luv.fs_unlink(got)
    luv.fs_rmdir(tmp)
    return nil, ("%s was not fetched (%s): %s. Kaggle wants an account: make a token at kaggle.com (Settings, API) and put it in ~/.kaggle/"):format(
      f.name, program, why ~= "" and why or "no file came")
  end
  local done, err = luv.fs_rename(got, target(f.name))
  if not done then return nil, ("%s was fetched to %s but could not be moved into place: %s"):format(f.name, got, tostring(err)) end
  luv.fs_rmdir(tmp)
  return target(f.name)
end

--- Fetches a dataset's files. One here and as new as its source is left alone.
-- @tparam table ds
-- @tparam[opt] table o `{ force=, with=, say= }`: with, the program to fetch from Kaggle
-- with; say(text), told what happens
-- @treturn boolean|nil true, or nil and why; true and "fresh" if it was left alone
function M.fetch(ds, o)
  o = o or {}
  local say = o.say or print
  local st = M.status(ds)
  if st.here and not o.force and (not ds.renewed or st.age < ds.renewed) then
    say(("%s: %s; nothing to fetch"):format(ds.name, M.state(ds)))
    return true, "fresh"
  end
  luv.fs_mkdir(M.dir(), 493)
  for _, f in ipairs(ds.files) do
    local s = luv.fs_stat(M.dir() .. "/" .. f.name)
    local fresh = s and not o.force and (not ds.renewed or (os.time() - s.mtime.sec) / 86400 < ds.renewed)
    if not fresh then
      local to, why = (f.kaggle and fetch_kaggle or fetch_url)(f, o)
      if not to then return nil, why end
      say(("%s: %s is at %s"):format(ds.name, f.name, to))
    end
  end
  return true
end

--- Uses a file fetched by other means, linked in under the name its dataset uses.
-- @treturn table|nil the dataset and the name, or nil and why
function M.adopt(path)
  local real = luv.fs_realpath(path)
  if not real or not luv.fs_stat(real) then return nil, ("there is no file %s"):format(path) end
  local base = real:match("[^/]+$")
  for _, ds in ipairs(M.list) do
    for _, f in ipairs(ds.files) do
      for _, pattern in ipairs(f.known) do
        if base:find(pattern) then
          local link = M.dir() .. "/" .. f.name
          if real == (luv.fs_realpath(link) or "") then return ds, f.name end
          luv.fs_unlink(link)
          local ok, err = luv.fs_symlink(real, link)
          if not ok then return nil, ("%s could not be linked into %s: %s"):format(base, M.dir(), tostring(err)) end
          return ds, f.name
        end
      end
    end
  end
  return nil, ("%s is not a file of a dataset lulibre knows (it goes by the file's name)"):format(base)
end

return M
