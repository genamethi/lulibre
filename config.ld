-- LDoc (https://github.com/lunarmodules/LDoc): lulibre's Lua API reference,
-- from the doc comments in lua/lulibre/. `make api` writes it to build/api.
project = "lulibre"
title = "lulibre: the Lua API"
description = "The modules a script or init.lua requires, and the part of lulibre that is written in Lua."
full_description = "Each module's page documents its functions. The [manual](../index.html) explains how to use lulibre, and [Lua API](../api/index.html) explains how scripts run."
file = {
  -- Scripting
  "lua/lulibre/prelude.lua",
  "lua/lulibre/edit.lua",
  "lua/lulibre/proposals.lua",
  "lua/lulibre/propose.lua",
  "lua/lulibre/runs.lua",
  "lua/lulibre/custom.lua",
  "lua/lulibre/parts.lua",
  "lua/lulibre/options.lua",
  -- Reading
  "lua/lulibre/extract.lua",
  "lua/lulibre/titlepage.lua",
  "lua/lulibre/layouts.lua",
  "lua/lulibre/grammars.lua",
  "lua/lulibre/names.lua",
  "lua/lulibre/ids.lua",
  "lua/lulibre/junk.lua",
  "lua/lulibre/titlecase.lua",
  "lua/lulibre/notation.lua",
  "lua/lulibre/detex.lua",
  "lua/lulibre/template.lua",
  "lua/lulibre/refs.lua",
  -- Judging
  "lua/lulibre/verify.lua",
  "lua/lulibre/consensus.lua",
  "lua/lulibre/quality.lua",
  "lua/lulibre/learn.lua",
  "lua/lulibre/subjects.lua",
  "lua/lulibre/taxonomy.lua",
  "lua/lulibre/noncatalog.lua",
  "lua/lulibre/suggest.lua",
  -- Library
  "lua/lulibre/calibre.lua",
  "lua/lulibre/offline.lua",
  "lua/lulibre/backup.lua",
  "lua/lulibre/units.lua",
  "lua/lulibre/snapshots.lua",
  "lua/lulibre/sync.lua",
  "lua/lulibre/dupes.lua",
  "lua/lulibre/orphans.lua",
  -- Services
  "lua/lulibre/net.lua",
  "lua/lulibre/net/core.lua",
  "lua/lulibre/net/match.lua",
  "lua/lulibre/net/arxiv.lua",
  "lua/lulibre/net/crossref.lua",
  "lua/lulibre/net/openalex.lua",
  "lua/lulibre/net/openlibrary.lua",
  "lua/lulibre/net/zbmath.lua",
  "lua/lulibre/datasets.lua",
  "lua/lulibre/bib.lua",
  "lua/lulibre/json.lua",
  -- Setup
  "lua/lulibre/config_file.lua",
  "lua/lulibre/features.lua",
  "lua/lulibre/overrides.lua",
  -- Screens
  "lua/lulibre/ui/panels.lua",
  "lua/lulibre/ui/keys.lua",
  "lua/lulibre/ui/form.lua",
  "lua/lulibre/ui/context.lua",
  "lua/lulibre/ui/dialogs.lua",
  "lua/lulibre/ui/beside.lua",
  "lua/lulibre/ui/browse.lua",
  "lua/lulibre/ui/capture.lua",
  "lua/lulibre/ui/config.lua",
  "lua/lulibre/ui/dupes.lua",
  "lua/lulibre/ui/edit.lua",
  "lua/lulibre/ui/good.lua",
  "lua/lulibre/ui/help.lua",
  "lua/lulibre/ui/orphans.lua",
  "lua/lulibre/ui/proposer.lua",
  "lua/lulibre/ui/review.lua",
  "lua/lulibre/ui/snapshots.lua",
  "lua/lulibre/ui/terms.lua",
  "lua/lulibre/ui/weights.lua",
}
dir = "build/api"
format = "markdown"
sort = false
no_space_before_args = true

-- The sections of the module list. Each module's opening comment names its
-- section instead of @module: @scripting lulibre.edit. LDoc names a
-- section's folder after its heading, so the headings here are one word;
-- tools/ldoc/ldoc.ltp shows the full headings, and adds the "Manual" links.
new_type("scripting", "Scripting", true)
new_type("reading", "Reading", true)
new_type("judging", "Judging", true)
new_type("library", "Library", true)
new_type("services", "Services", true)
new_type("setup", "Setup", true)
new_type("screens", "Screens", true)
template = "tools/ldoc"
