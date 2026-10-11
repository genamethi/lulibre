-- Guess a subject from the words on the first pages: count each subject's
-- indicative terms among the text's 1-, 2- and 3-word sequences. Multi-word
-- terms are more specific and count double.
local M = {}

M.lexicon = {
  ["math/number-theory"] = { "prime", "primes", "modular form", "modular forms", "elliptic curve",
    "elliptic curves", "zeta function", "l-function", "l-functions", "diophantine", "arithmetic",
    "galois representation", "cyclotomic", "riemann hypothesis", "congruence", "quadratic form",
    "dirichlet", "automorphic", "sieve", "additive number theory", "number theory", "mersenne",
    "divisor", "residue", "class field", "modular curve", "torsion points", "abelian variety" },
  ["math/algebra"] = { "group ring", "module", "representation theory", "homological algebra",
    "ideal", "lie algebra", "tensor product", "semigroup", "brauer group", "hopf algebra",
    "k-theory", "commutative algebra", "noetherian", "quaternion", "galois theory",
    "field extension", "ring theory", "burnside", "coalgebra" },
  ["math/algebraic-geometry"] = { "scheme", "sheaf", "algebraic variety", "divisor", "morphism",
    "etale", "algebraic space", "moduli", "coherent sheaf", "vector bundle",
    "cohomology of schemes", "projective variety", "algebraic stack", "intersection theory" },
  ["math/topology"] = { "homotopy", "homology", "manifold", "simplicial", "fiber bundle",
    "cw complex", "knot", "fundamental group", "cobordism", "cohomology theory",
    "topological space", "homeomorphism" },
  ["math/category-theory"] = { "category", "functor", "natural transformation", "topos",
    "adjoint", "monad", "categorical", "morphisms" },
  ["math/combinatorics"] = { "graph", "partition", "generating function", "combinatorial",
    "permutation", "matroid", "ramsey", "enumeration", "young tableaux", "bijection", "poset" },
  ["math/logic"] = { "model theory", "set theory", "computable", "recursion theory", "decidable",
    "first-order", "forcing", "cardinal", "ordinal", "proof theory", "provable" },
  ["math/analysis"] = { "measure", "lebesgue", "banach space", "hilbert space", "operator",
    "functional analysis", "fourier", "sobolev", "harmonic analysis", "integral",
    "differential equation" },
  ["math/probability"] = { "random variable", "martingale", "stochastic", "probability",
    "brownian motion", "markov", "expectation", "central limit" },
  ["math/dynamics"] = { "dynamical system", "ergodic", "orbit", "entropy", "chaos", "flow" },
  ["math/geometry"] = { "riemannian", "curvature", "geodesic", "differential geometry",
    "symplectic", "metric space" },
  ["math/algebra/group-theory"] = { "subgroup", "sylow", "solvable group", "nilpotent", "coxeter",
    "character table", "finite group", "conjugacy" },
  ["cs"] = { "algorithm", "complexity", "machine learning", "neural network",
    "programming language", "type system", "compiler", "database", "deep learning",
    "functional programming", "lambda calculus", "computation", "software" },
  ["linguistics"] = { "syntax", "semantics", "phonology", "grammar", "minimalist", "morphology",
    "merge operation", "lexical", "phonetic", "linguistic" },
  ["sciences/cognitive"] = { "neuron", "cortex", "hippocampal", "spike train", "synaptic",
    "neural", "brain", "cognition", "dendrite" },
  ["physics"] = { "quantum", "relativity", "particle", "field theory", "hamiltonian",
    "spacetime", "thermodynamics", "gauge" },
  ["philosophy"] = { "metaphysics", "epistemology", "ontology", "consciousness", "philosophical" },
}

-- term -> list of subjects it speaks for; built once
local index
local function build()
  index = {}
  for subject, terms in pairs(M.lexicon) do
    for _, term in ipairs(terms) do
      index[term] = index[term] or {}
      table.insert(index[term], subject)
    end
  end
end

--- Ranked { {subject=, score=}, ... } for a piece of text; best first.
function M.score(text)
  if not index then build() end
  local words = {}
  for w in text:lower():gsub("[^a-z0-9%- ]", " "):gmatch("%S+") do words[#words + 1] = w end
  local scores = {}
  local function count(gram, weight)
    local subjects = index[gram]
    if subjects then
      for _, s in ipairs(subjects) do scores[s] = (scores[s] or 0) + weight end
    end
  end
  for i = 1, #words do
    count(words[i], 1)
    if words[i + 1] then
      local two = words[i] .. " " .. words[i + 1]
      count(two, 2)
      if words[i + 2] then count(two .. " " .. words[i + 2], 2) end
    end
  end
  local out = {}
  for s, v in pairs(scores) do out[#out + 1] = { subject = s, score = v } end
  table.sort(out, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    return a.subject < b.subject
  end)
  return out
end

return M
