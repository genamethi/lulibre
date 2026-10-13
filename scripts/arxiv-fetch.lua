-- Fetch arXiv's own snapshot of its records, which :enrich reads instead of
-- asking arXiv about each paper. The same as `datasets fetch arxiv`.
--   :run arxiv-fetch              if there is none here, or the one here is over a week old
--   :run arxiv-fetch --force      whatever is here
--   :run arxiv-fetch --with CMD   fetch with this program instead (a kaggle of your own)
local datasets = require "lulibre.datasets"

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

local ok, why = datasets.fetch(datasets.get("arxiv"), { force = force, with = with })
if not ok then error(why, 0) end
if why ~= "fresh" then print("arXiv's snapshot fetched. :enrich reads papers from it and asks arXiv only about those newer than the file") end
