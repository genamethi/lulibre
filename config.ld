-- LDoc (https://github.com/lunarmodules/LDoc): lulibre's Lua API reference,
-- from the doc comments in lua/lulibre/. `make api` writes it to build/api.
project = "lulibre"
title = "lulibre: the Lua API"
description = "The modules a script or init.lua requires: lulibre's own, written in Lua."
file = {
  "lua/lulibre/verify.lua",
  "lua/lulibre/backup.lua",
  "lua/lulibre/offline.lua",
  "lua/lulibre/proposals.lua",
  "lua/lulibre/edit.lua",
  "lua/lulibre/extract.lua",
  "lua/lulibre/suggest.lua",
  "lua/lulibre/custom.lua",
  "lua/lulibre/options.lua",
  "lua/lulibre/config_file.lua",
  "lua/lulibre/propose.lua",
  "lua/lulibre/runs.lua",
  "lua/lulibre/quality.lua",
  "lua/lulibre/noncatalog.lua",
  "lua/lulibre/consensus.lua",
  "lua/lulibre/dupes.lua",
  "lua/lulibre/orphans.lua",
  "lua/lulibre/sync.lua",
  "lua/lulibre/snapshots.lua",
  "lua/lulibre/calibre.lua",
  "lua/lulibre/units.lua",
  "lua/lulibre/ids.lua",
  "lua/lulibre/names.lua",
  "lua/lulibre/junk.lua",
  "lua/lulibre/titlecase.lua",
  "lua/lulibre/notation.lua",
  "lua/lulibre/subjects.lua",
  "lua/lulibre/taxonomy.lua",
  "lua/lulibre/template.lua",
}
dir = "build/api"
format = "markdown"
sort = false
no_space_before_args = true
