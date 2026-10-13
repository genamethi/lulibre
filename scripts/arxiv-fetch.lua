-- Fetch arXiv's own snapshot of its records, which :enrich reads instead of
-- asking arXiv about each paper.
--   :run arxiv-fetch              if there is none here, or the one here is over a week old
--   :run arxiv-fetch --force      whatever is here
--   :run arxiv-fetch --with CMD   fetch with this program instead (a kaggle of your own)
--
-- The file is the dataset Cornell-University/arxiv on Kaggle: every paper,
-- one to a line; about 1.7 GB to fetch and 5.6 GB on disk, renewed about
-- once a week. It is fetched with Kaggle's own program, run through pixi
-- (`pixi exec kaggle`: nothing is installed, pixi keeps the program in its
-- cache), or with a `kaggle` on the PATH when there is no pixi. Kaggle wants
-- an account: its token goes in ~/.kaggle/ (kaggle.com, Settings, API).
--
-- The file lands in lulibre's data folder as
-- arxiv-metadata-oai-snapshot.json. Where that name is a link, the file it
-- points to is what is renewed.
local uv = require "luv"

local DATASET, NAME, WEEK = "Cornell-University/arxiv", "arxiv-metadata-oai-snapshot.json", 7 * 86400

local force, with = false, nil
local args = { ... }
local i = 1
while i <= #args do
  if args[i] == "--force" then force = true
  elseif args[i] == "--with" then
    i = i + 1
    with = args[i]
  else error(("arxiv-fetch: unknown argument '%s' (--force, --with CMD)"):format(args[i]), 0) end
  i = i + 1
end

local dir = lulibre.settings.paths().data_dir
local target = dir .. "/" .. NAME
-- a link is followed: the file it points to is the one to renew
local real = uv.fs_realpath(target) or target
local st = uv.fs_stat(real)
if st and not force then
  local age = os.time() - st.mtime.sec
  if age < WEEK then
    print(("arXiv's snapshot here is %s old (%s, %.1f GB); arXiv renews it about weekly. :run arxiv-fetch --force fetches it regardless"):format(
      age < 86400 and ("%d hours"):format(age // 3600) or ("%d days"):format(age // 86400), real, st.size / 1e9))
    return
  end
end

local function on_path(program)
  local r = lulibre.system({ "sh", "-c", "command -v " .. program }, { timeout = 5000 })
  return r and r.code == 0
end

local cmd
if with then
  cmd = { with }
elseif on_path("pixi") then
  cmd = { "pixi", "exec", "kaggle" }
elseif on_path("kaggle") then
  cmd = { "kaggle" }
else
  error("arxiv-fetch needs pixi (https://pixi.sh), which runs Kaggle's program without installing it, or a kaggle on the PATH", 0)
end

-- into a folder of its own first: a fetch that stops half way leaves the file that was here as it was
local tmp = dir .. "/arxiv-fetch.tmp"
lulibre.system({ "mkdir", "-p", tmp }, { timeout = 5000 })
for _, a in ipairs { "datasets", "download", DATASET, "-p", tmp, "--unzip" } do cmd[#cmd + 1] = a end
lulibre.progress("fetching arXiv's snapshot from Kaggle (about 1.7 GB)")
local began = os.time()
local r, err = lulibre.system(cmd, { timeout = 3 * 3600 * 1000 })
lulibre.progress(nil)

local fetched = tmp .. "/" .. NAME
local got = uv.fs_stat(fetched)
if not r or r.code ~= 0 or not got then
  local said = r and ((r.stderr or "") .. (r.stdout or "")) or tostring(err)
  local last = said:gsub("%s+$", ""):match("[^\n]*$") or ""
  uv.fs_unlink(fetched)
  uv.fs_rmdir(tmp)
  local hint = ""
  if said:find("401") or said:find("403") or said:lower():find("credential") or said:lower():find("authenticat") or said:find("kaggle%.json")
    or said:lower():find("token") then
    hint = "\nKaggle wants an account: make a token at kaggle.com (Settings, API) and put it in ~/.kaggle/"
  end
  error(("arXiv's snapshot was not fetched (%s): %s%s"):format(table.concat(cmd, " ", 1, #cmd - 6), last ~= "" and last or "no file came", hint), 0)
end

-- is it what it should be: a paper to a line
local f = assert(io.open(fetched, "r"))
local head = f:read(256) or ""
f:close()
if not head:find('^%s*{%s*"id"%s*:') then
  error(("what was fetched does not look like arXiv's snapshot; it is left at %s"):format(fetched), 0)
end

local moved = lulibre.system({ "mv", "-f", fetched, real }, { timeout = 600000 })
if not moved or moved.code ~= 0 then
  error(("the snapshot was fetched to %s but could not be moved to %s: %s"):format(fetched, real, moved and moved.stderr or "?"), 0)
end
uv.fs_rmdir(tmp)
print(("arXiv's snapshot fetched in %d s: %s (%.1f GB). %s reads papers from it and asks arXiv only about those newer than the file"):format(
  os.time() - began, real, got.size / 1e9, ":enrich"))
