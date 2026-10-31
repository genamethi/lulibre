--- What each value scores (design 16, 21, 39; ranking section). A score belongs to
-- one value of one field, from three things, weighed by the settings rank_coverage,
-- rank_agreement and rank_track:
--
-- - how sure its reading is: `sure` on the value, as its grammar says, or
--   `grammar_sure`; an online record's by how much of it is on the pages;
-- - whether the sources agree with this value, by mesr. A value does not count
--   agreement with itself, nor with a record value it wrote (circular agreement);
-- - the record of decisions on what it came from, for this field.
--
-- The last two count only where they have something to say: with no source holding
-- the field, and no record of decisions yet, a value scores what its reading is sure of.
--
-- @library lulib._rank
local mesr = require "mesr"
local sources = require "lulib._sources"
local trust = require "trust"

local M = {}

--- How sure a grammar's value is when the grammar doesn't say.
M.grammar_sure = 0.75

--- This value's agreement with the sources, 0 to 1, nil when no source holds the
-- field; and the sources that agree and disagree.
-- @tparam string name what the value came from
-- @tparam string field
-- @tparam string value
-- @tparam {table,...} srcs lulib._sources.of's
-- @tparam table w `{ near=, same= }`
function M.agreement(name, field, value, srcs, w)
  local num, den, agree, disagree = 0, 0, nil, nil
  for _, src in ipairs(srcs) do
    local v = src.fields[field]
    local own = src.name == name or (src.from and src.from[field] == name)
    if v and v ~= "" and not own then
      local ws = sources.weight[src.kind] or 1
      local like, ab, ba = mesr.cmp(field, value, v, w.near, w.same)
      num = num + ws * (ab + ba) / 2
      den = den + ws
      if like == "differs" then
        disagree = disagree or {}
        table.insert(disagree, src.name)
      else
        agree = agree or {}
        table.insert(agree, src.name)
      end
    end
  end
  return den > 0 and num / den or nil, agree, disagree
end

--- A value's score, and the sources that agree and disagree with it.
-- @tparam string name what it came from
-- @tparam string field
-- @tparam string value
-- @tparam number sure how sure its reading is, 0 to 1
-- @tparam {table,...} srcs lulib._sources.of's
-- @tparam table w `{ coverage=, agreement=, track=, records=, near=, same= }`
function M.value(name, field, value, sure, srcs, w)
  local sum, weight = w.coverage * sure, w.coverage
  local agreement, agree, disagree = M.agreement(name, field, value, srcs, w)
  if agreement then
    sum, weight = sum + w.agreement * agreement, weight + w.agreement
  end
  local records = w.records[name]
  if records and records[trust.field(field)] then
    sum, weight = sum + w.track * records[trust.field(field)], weight + w.track
  end
  return weight > 0 and sum / weight or sure, agree, disagree
end

return M
