-- LDoc (https://github.com/lunarmodules/LDoc): lulibre's Lua API reference,
-- from the doc comments in lua/. `make api` writes it to build/api.
project = "lulibre"
title = "lulibre: the Lua API"
description = "The modules a script or init.lua requires, and the part of lulibre that is written in Lua."
full_description =
	"Each module's page documents its functions. The [manual](../index.html) explains how to use lulibre, and [Lua API](../api/index.html) explains how scripts run."
file = {
	-- what a script requires
	"lua/expr.lua",
	"lua/lex.lua",
	"lua/exprman.lua",
	"lua/iter.lua",
	"lua/sql.lua",
	"lua/wit.lua",
	"lua/trust.lua",
	"lua/net/init.lua",
	"lua/net/service.lua",
	"lua/net/services.lua",
	"lua/net/datasets.lua",
	-- lulibre's own: the packaged grammar and commands, and the internal
	-- modules (lulib._name)
	"lua/exprman/_pages.lua",
	"lua/cmd.lua",
	"lua/lulib/_propose.lua",
	"lua/lulib/_rank.lua",
	"lua/lulib/_sources.lua",
	"lua/lulib/_kept.lua",
	"lua/lulib/_ids.lua",
	"lua/lulib/_check.lua",
	"lua/lulib/_review.lua",
	"lua/lulib/_verify.lua",
	"lua/lulib/_recheck.lua",
	"lua/lulib/_rewrites.lua",
	"lua/lulib/_capture.lua",
	"lua/lulib/_sync.lua",
	"lua/lulib/_beside.lua",
	"lua/lulib/_browse.lua",
	"lua/lulib/_dialogs.lua",
	"lua/lulib/_dupes.lua",
	"lua/lulib/_orphans.lua",
	"lua/lulib/_remove.lua",
	"lua/lulib/_columns.lua",
	"lua/lulib/_offline.lua",
	"lua/lulib/_history.lua",
	"lua/lulib/_snapshots.lua",
	"lua/lulib/_datasets.lua",
	"lua/lulib/_bib.lua",
	"lua/lulib/_names.lua",
	"lua/lulib/_junk.lua",
	"lua/lulib/_titlecase.lua",
	"lua/lulib/_notation.lua",
	"lua/lulib/_detex.lua",
	"lua/lulib/_layouts.lua",
	"lua/lulib/_titlepage.lua",
	"lua/lulib/_taxonomy.lua",
	"lua/lulib/_template.lua",
	"lua/lulib/_config.lua",
	"lua/lulib/_options.lua",
	"lua/lulib/_uiman.lua",
	"lua/lulib/_eval.lua",
	"lua/lulib/_prelude.lua",
}
dir = "build/api"
format = "markdown"
sort = false
no_space_before_args = true

-- Each module's opening comment names it with @library (a part of
-- one, @submodule). The modules written in C (bookman, store, txt, mesr,
-- curl, setman, ...) are in docs/api.md.
new_type("library", "Library", true)
template = "tools/ldoc"
