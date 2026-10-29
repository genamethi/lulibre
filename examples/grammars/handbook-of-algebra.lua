-- Example grammar: chapters of Elsevier's Handbook of Algebra (ISSN
-- 1570-7954). The volume comes from the chapter's DOI, which says it by
-- year ("S1570-7954(96)80014-3" is volume 1, its 14th chapter), from the
-- record's DOI or the file's own title ("PII: S1570-7954(00)80034-0"), or
-- from the foot of the first page ("HANDBOOK OF ALGEBRA, VOL. 3 ... 2003
-- Elsevier"). The title is the largest type near the top of the first
-- page. The volume goes to lulibre's own field #partof, the chapter's
-- number to #part.
--
-- To use it, copy this file to ~/.config/lulibre/lua/ and add
-- require "handbook-of-algebra" to init.lua.
local expr, exprman, bookman = require "expr", require "exprman", require "bookman"
local Cmt, Carg = expr.Cmt, expr.Carg

local volumes = { ["96"] = 1, ["00"] = 2, ["03"] = 3, ["06"] = 4, ["08"] = 5, ["09"] = 6 }
local years = { 1996, 2000, 2003, 2006, 2008, 2009 }

-- the chapter's DOI: the record's, else made from the PII in the file's
-- own title
local function doi_of(t, book)
  local doi = book and bookman.get(book, "identifier:doi") or ""
  if doi ~= "" then return doi:upper() end
  local pii = ((t.meta or {}).title or ""):upper():match("PII:%s*(S1570%-7954%(%d%d%)%d%d%d%d%d%-?[%dX])")
  return pii and "10.1016/" .. pii or ""
end

-- the fields that are not where the text has them: the volume, the
-- chapter, the year, the publisher
local whole = Cmt(Carg(1) * Carg(2), function(_, pos, t, book)
  local yy, item = doi_of(t, book):match("^10%.1016/S1570%-7954%((%d%d)%)(%d%d%d%d%d)")
  local page = t.text:match("^[^\f]*")
  local foot = page:upper():match("HANDBOOK OF ALGEBRA,?%s*VOL%.?%s*(%d)%f[%D]")
  local vol = yy and volumes[yy] or tonumber(foot)
  if not vol then return false end
  return pos, {
    ["#partof"] = { value = ("Handbook of Algebra, Volume %d"):format(vol) },
    ["#part"] = item and { value = tostring(tonumber(item:sub(-3))) } or nil,
    -- the year the foot of the page prints, else the volume's
    pubdate = { value = page:match("%f[%d](%d%d%d%d)%s+Elsevier") or tostring(years[vol]) },
    publisher = { value = "Elsevier" },
  }
end)

-- the title: the largest lines near the top of the first page
local title_here = expr.page(1) * expr.largest * expr.near_top(0.4)
local title = title_here * expr.line * (expr.eol * title_here * expr.line) ^ 0

exprman.add("handbook-of-algebra", whole * expr.Ct((expr.upto(title_here) * exprman.field("title", title)) ^ -1)
  / function(fields, found)
    fields.title = found.title
    return fields
  end, "Handbook of Algebra")
