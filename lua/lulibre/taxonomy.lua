-- The one place subject names are decided. The Python scripts kept six maps
-- that disagreed (math.AG was "math/geometry/algebraic" in one and
-- "math/algebraic-geometry" in another, and both ended up in the library);
-- everything that needs a subject now asks here.
local M = {}

--- arXiv primary class -> subject tag
M.arxiv = {
  ["math.NT"] = "math/number-theory",
  ["math.AG"] = "math/algebraic-geometry",
  ["math.AC"] = "math/algebra",
  ["math.RA"] = "math/algebra",
  ["math.RT"] = "math/algebra",
  ["math.QA"] = "math/algebra",
  ["math.KT"] = "math/algebra/k-theory",
  ["math.GR"] = "math/algebra/group-theory",
  ["math.CT"] = "math/category-theory",
  ["math.LO"] = "math/logic",
  ["math.CO"] = "math/combinatorics",
  ["math.AT"] = "math/topology",
  ["math.GT"] = "math/topology",
  ["math.GN"] = "math/topology",
  ["math.DG"] = "math/geometry/differential",
  ["math.MG"] = "math/geometry",
  ["math.SG"] = "math/geometry",
  ["math.DS"] = "math/dynamics",
  ["math.PR"] = "math/probability",
  ["math.ST"] = "math/probability",
  ["math.CA"] = "math/analysis",
  ["math.CV"] = "math/analysis",
  ["math.FA"] = "math/analysis",
  ["math.AP"] = "math/analysis",
  ["math.OA"] = "math/analysis",
  ["math.SP"] = "math/analysis",
  ["math.NA"] = "math/applied",
  ["math.OC"] = "math/applied",
  ["math.IT"] = "cs/information-theory",
  ["math.GM"] = "math/general",
  ["math.HO"] = "math/history",
  ["math.MP"] = "math/physics",
  ["math-ph"] = "math/physics",
  ["hep-th"] = "physics/hep-theory",
  ["hep-ph"] = "physics/hep-pheno",
  ["gr-qc"] = "physics/gravity-qc",
  ["quant-ph"] = "physics/quantum",
  ["cs.LG"] = "cs/ml",
  ["stat.ML"] = "cs/ml",
  ["cs.AI"] = "cs/ai",
  ["cs.CL"] = "cs/nlp",
  ["cs.DC"] = "cs/distributed",
  ["cs.DS"] = "cs/algorithms",
  ["cs.IT"] = "cs/information-theory",
}

-- when the exact class is not listed, its archive decides
local archive = {
  math = "math/general",
  cs = "cs",
  stat = "cs",
  ["cond-mat"] = "physics/condensed-matter",
  ["astro-ph"] = "sciences/physical",
  ["nucl-th"] = "sciences/physical",
  physics = "sciences/physical",
  ["q-bio"] = "sciences/bio",
  econ = "economics",
}

function M.from_arxiv(class)
  if not class then return nil end
  return M.arxiv[class] or archive[class:match("^[^.]+")]
end

--- MSC two-digit area -> subject tag
M.msc = {
  ["00"] = "math/general", ["01"] = "math/history", ["03"] = "math/logic",
  ["05"] = "math/combinatorics", ["06"] = "math/algebra/lattice-theory",
  ["08"] = "math/algebra", ["11"] = "math/number-theory",
  ["12"] = "math/algebra/field-theory", ["13"] = "math/algebra",
  ["14"] = "math/algebraic-geometry", ["15"] = "math/algebra", ["16"] = "math/algebra",
  ["17"] = "math/algebra", ["18"] = "math/category-theory",
  ["19"] = "math/algebra/k-theory", ["20"] = "math/algebra/group-theory",
  ["22"] = "math/algebra/group-theory", ["26"] = "math/analysis", ["28"] = "math/analysis",
  ["30"] = "math/analysis", ["31"] = "math/analysis", ["32"] = "math/analysis",
  ["33"] = "math/analysis", ["34"] = "math/analysis", ["35"] = "math/analysis",
  ["37"] = "math/dynamics", ["39"] = "math/analysis", ["40"] = "math/analysis",
  ["41"] = "math/analysis", ["42"] = "math/analysis", ["43"] = "math/analysis",
  ["44"] = "math/analysis", ["45"] = "math/analysis", ["46"] = "math/analysis",
  ["47"] = "math/analysis", ["49"] = "math/analysis", ["51"] = "math/geometry",
  ["52"] = "math/geometry", ["53"] = "math/geometry/differential",
  ["54"] = "math/topology", ["55"] = "math/topology", ["57"] = "math/topology",
  ["58"] = "math/analysis", ["60"] = "math/probability", ["62"] = "math/probability",
  ["65"] = "math/applied", ["68"] = "cs", ["70"] = "math/physics", ["76"] = "math/physics",
  ["81"] = "math/physics", ["82"] = "math/physics", ["83"] = "math/physics",
  ["90"] = "math/applied", ["91"] = "math/applied", ["94"] = "cs/information-theory",
}

--- Tags that mean the same thing as another tag; used when normalising.
M.alias = {
  ["math/geometry/algebraic"] = "math/algebraic-geometry",
  ["math/group-theory"] = "math/algebra/group-theory",
  ["math/topology/algebraic"] = "math/topology",
}

function M.canonical(tag)
  return M.alias[tag] or tag
end

return M
