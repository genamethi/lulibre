-- Example grammar: chapters of Elsevier's Handbook of Algebra. The volume and
-- the chapter's number come from the DOI, from the PII in the file's
-- embedded title, or from the foot of the first page.
--
-- To use it, copy this file to ~/.config/lulibre/lua/grammars/ and add
-- require "grammars.handbook-of-algebra" to init.lua.
local G = require "lulibre.grammars"

-- Elsevier's Handbook of Algebra (ISSN 1570-7954): its chapters' DOIs say the
-- volume by year ((96) is volume 1) and the chapter's place in it (80014: 14).
-- A chapter without its DOI still has Elsevier's item number (the PII) in
-- the file's own title ("PII: S1570-7954(00)80034-0"), of which the DOI is
-- made, or its first page's foot: "HANDBOOK OF ALGEBRA, VOL. 3 / Edited by
-- M. Hazewinkel / © 2003 Elsevier Science B.V.".
local HANDBOOK_VOLUMES = { ["96"] = 1, ["00"] = 2, ["03"] = 3, ["06"] = 4, ["08"] = 5, ["09"] = 6 }
local HANDBOOK_YEARS = { 1996, 2000, 2003, 2006, 2008, 2009 }
G.add {
  name = "handbook-of-algebra",
  kind = "chapter of the Handbook of Algebra",
  read = function(doc)
    local doi = ((doc.idents or {}).doi or ""):upper()
    if doi == "" and doc.id then
      for _, f in ipairs(lulibre.sql("SELECT emb_title FROM files WHERE book = ?", doc.id)) do
        local pii = (f.emb_title or ""):upper():match("PII:%s*(S1570%-7954%(%d%d%)%d%d%d%d%d%-?[%dX])")
        if pii then doi = "10.1016/" .. pii break end
      end
    end
    local yy, item = doi:match("^10%.1016/S1570%-7954%((%d%d)%)(%d%d%d%d%d)")
    local vol = yy and HANDBOOK_VOLUMES[yy]
    local page = (doc.texts or {})[1] or ""
    local foot = page:upper():match("HANDBOOK OF ALGEBRA,?%s*VOL%.?%s*(%d)%f[%D]")
    if not yy and not foot then return false end
    vol = vol or tonumber(foot)
    local fields = { part_of = vol and ("Handbook of Algebra, Volume %d"):format(vol) or "Handbook of Algebra",
      part = item and tonumber(item:sub(-3)) or nil,
      identifiers = yy and ("doi:" .. doi) or nil,
      -- the year the foot of the page prints, else the volume's
      pubdate = page:match("%f[%d](%d%d%d%d)%s+Elsevier") or (vol and HANDBOOK_YEARS[vol] and tostring(HANDBOOK_YEARS[vol])) or nil,
      publisher = "Elsevier" }
    -- the title is the largest type on the page, the authors under it
    local lines, top = doc.lines or {}, 0
    for _, l in ipairs(lines) do
      if (l.size or 0) > top then top = l.size end
    end
    local title = {}
    for i, l in ipairs(lines) do
      if (l.size or 0) >= top - 0.1 and i <= 4 then title[#title + 1] = l.text end
    end
    if #title > 0 then fields.title = table.concat(title, " ") end
    return fields
  end,
  confidence = 0.85,
}
