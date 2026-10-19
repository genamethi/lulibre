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
  -- arXiv's "Computation and Language": computational linguistics, which is
  -- linguistics, not natural language processing (cs/nlp is what a book's
  -- pages say of it, subjects.lua)
  ["cs.CL"] = "linguistics/computational",
  ["cs.DC"] = "cs/distributed",
  ["cs.DS"] = "cs/algorithms",
  ["cs.IT"] = "cs/information-theory",
  ["cs.NE"] = "cs/ml", ["cs.CV"] = "cs/vision", ["cs.MA"] = "cs/ai", ["cs.RO"] = "cs/robotics",
  ["cs.CC"] = "cs/complexity", ["cs.LO"] = "cs/logic", ["cs.FL"] = "cs/formal-languages",
  ["cs.PL"] = "cs/programming-languages", ["cs.SE"] = "cs/software-engineering", ["cs.CR"] = "cs/security",
  ["cs.DB"] = "cs/systems", ["cs.OS"] = "cs/systems", ["cs.NI"] = "cs/systems", ["cs.AR"] = "cs/systems",
  ["cs.IR"] = "cs/information-retrieval", ["cs.HC"] = "cs/hci", ["cs.SI"] = "cs/networks", ["cs.GT"] = "cs/game-theory",
  ["cs.CG"] = "cs/geometry", ["cs.SC"] = "cs/symbolic", ["cs.DM"] = "math/combinatorics", ["cs.NA"] = "math/applied",
  ["cs.SD"] = "cs/audio", ["eess.AS"] = "cs/audio", ["eess.SP"] = "cs/signal-processing", ["eess.IV"] = "cs/vision",
  ["stat.TH"] = "math/statistics", ["stat.ME"] = "math/statistics", ["stat.AP"] = "math/statistics",
  ["stat.CO"] = "math/statistics", ["math.ST"] = "math/statistics",
}

-- when the exact class is not listed, its archive decides
local archive = {
  math = "math/general",
  cs = "cs",
  stat = "math/statistics",
  eess = "cs",
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

-- Library of Congress classes, as the cataloguing block of a book gives
-- them ("QA387.L35 1985"): a letter class and a number, here as ranges within
-- a class, most particular first.
local LCC = {
  QA = { { 8, 10.9, "math/logic" }, { 75, 76.99, "cs" }, { 150, 162, "math/algebra" }, { 164, 167, "math/combinatorics" },
    { 169, 169, "math/category-theory" }, { 171, 183, "math/algebra/group-theory" }, { 184, 240, "math/algebra" },
    { 241, 247.9, "math/number-theory" }, { 248, 272, "math/algebra" }, { 273, 280, "math/probability" },
    { 297, 299.4, "math/applied" }, { 299.6, 433, "math/analysis" }, { 440, 563, "math/geometry" },
    { 564, 609, "math/algebraic-geometry" }, { 611, 614.99, "math/topology" }, { 615, 699, "math/geometry/differential" },
    { 801, 939, "math/physics" }, { 1, 999, "math" } },
  QC = { { 1, 999, "physics" } }, QB = { { 1, 999, "sciences/physical" } }, QD = { { 1, 999, "sciences/physical" } },
  QP = { { 351, 495, "sciences/cognitive" }, { 1, 999, "sciences/bio" } }, QH = { { 1, 999, "sciences/bio" } },
  Q = { { 300, 390, "cs" }, { 1, 999, "sciences/general" } },
  BF = { { 1, 990, "sciences/cognitive" } }, BC = { { 1, 199, "math/logic" } },
  B = { { 1, 5802, "philosophy" } }, BD = { { 1, 701, "philosophy" } },
  P = { { 1, 1091, "linguistics" } }, PE = { { 1, 3729, "linguistics" } },
  TK = { { 5100, 7895, "cs" } }, T = { { 55.4, 60.8, "math/applied" } },
  HB = { { 1, 3840, "economics" } },
}

--- The subject a Library of Congress class number stands for
-- ("QA247 .S47", "QA387.L35"), or nil.
function M.from_lcc(class)
  local letters, number = (class or ""):upper():match("^%s*(%u%u?)%s*(%d+%.?%d*)")
  local ranges = letters and LCC[letters]
  number = tonumber(number)
  if not ranges or not number then return nil end
  for _, r in ipairs(ranges) do
    if number >= r[1] and number <= r[2] then return r[3] end
  end
  return nil
end

-- Dewey numbers, by their leading figures, longest first
local DEWEY = { { "511.3", "math/logic" }, { "511.5", "math/combinatorics" }, { "511.6", "math/combinatorics" },
  { "512.7", "math/number-theory" }, { "512.2", "math/algebra/group-theory" }, { "512", "math/algebra" },
  { "514", "math/topology" }, { "515", "math/analysis" }, { "516.35", "math/algebraic-geometry" },
  { "516.36", "math/geometry/differential" }, { "516", "math/geometry" }, { "519.2", "math/probability" },
  { "519", "math/applied" }, { "51", "math" }, { "004", "cs" }, { "005", "cs" }, { "006", "cs" }, { "53", "physics" },
  { "41", "linguistics" }, { "1", "philosophy" } }

--- The subject a Dewey number stands for ("512'.55", "516.3/5"), or nil.
function M.from_dewey(number)
  local n = (number or ""):gsub("['/ ]", "")
  if not n:match("^%d%d%d") then return nil end
  for _, d in ipairs(DEWEY) do
    if n:sub(1, #d[1]) == d[1] then return d[2] end
  end
  return nil
end

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
