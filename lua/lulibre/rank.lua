--- Ranks a book's parses (design 16, 21, 39; ranking section).
--
-- A parse is a grammar's, or an online record's. Its score is coverage,
-- agreement and track record, weighed by the settings rank_coverage,
-- rank_agreement and rank_track. Agreement compares a parse's fields with
-- the sources by lulibre.similar; a parse does not count agreement with
-- itself, nor with a record value it wrote (circular agreement).
--
-- @library lulibre.rank
local similar = require "lulibre.similar"
local sources = require "lulibre.sources"
local track = require "lulibre.track"

local M = {}

--- Each field's kind, for lulibre.similar; any other field is an identifier.
M.kinds = { title = "text", authors = "people", publisher = "text", series = "text", year = "date", tags = "tags" }

--- What filling a field is worth: title and authors the majority,
-- publisher, series and year about equal.
M.coverage_weight = { title = 0.3, authors = 0.3, publisher = 0.4 / 3, series = 0.4 / 3, year = 0.4 / 3 }

function M.kind(field)
  return M.kinds[field] or "ident"
end

--- A parse's coverage, 0 to 1.
function M.coverage(parse)
  local c = 0
  for field in pairs(parse.fields) do c = c + (M.coverage_weight[field] or 0) end
  return c
end

--- A parse's agreement with the sources, 0 to 1 (0.5 when no source holds
-- any of its fields), and per field the sources that agree and disagree.
-- @tparam table w `{ near=, same= }`
function M.agreement(parse, srcs, w)
  local num, den, agree, disagree = 0, 0, {}, {}
  for field, f in pairs(parse.fields) do
    local wf = M.coverage_weight[field] or 0.05
    for _, src in ipairs(srcs) do
      local v = src.fields[field]
      local own = src.from and src.from[field] == parse.grammar
      if v and v ~= "" and not own then
        local ws = sources.weight[src.kind] or 1
        local like, ab, ba = similar.compare(M.kind(field), f.value, v, w.near, w.same)
        num = num + wf * ws * (ab + ba) / 2
        den = den + wf * ws
        local into = like == "differs" and disagree or agree
        into[field] = into[field] or {}
        table.insert(into[field], src.name)
      end
    end
  end
  return den > 0 and num / den or 0.5, agree, disagree
end

--- The parses, best first, each with `score=`, `agree=` and `disagree=`
-- (per field, the names of the sources).
-- @tparam table w `{ coverage=, agreement=, track=, records=, near=, same= }`; records:
-- lulibre.track.records()
function M.order(parses, srcs, w)
  local total = w.coverage + w.agreement + w.track
  for _, p in ipairs(parses) do
    local agreement
    agreement, p.agree, p.disagree = M.agreement(p, srcs, w)
    local record, n = 0, 0
    for field in pairs(p.fields) do
      record = record + track.record(w.records, p.grammar, field)
      n = n + 1
    end
    record = n > 0 and record / n or track.prior
    p.score = (w.coverage * M.coverage(p) + w.agreement * agreement + w.track * record) / total
  end
  table.sort(parses, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    return a.grammar < b.grammar
  end)
  return parses
end

return M
