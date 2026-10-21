--- Guesses a subject from the words on the first pages. Counts each
-- subject's indicative terms among the text's 1-, 2- and 3-word sequences.
-- Terms of more than one word are more specific and count double.
--
-- @judging lulibre.subjects
-- @usage
-- local subjects = require "lulibre.subjects"
-- subjects.score("elliptic curves and modular forms over the primes")[1]
--   --> { subject = "math/number-theory", score = 5 }
local M = {}

--- Each subject's indicative terms, by subject.
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
  -- computing: the field at large, and under it what a text is plainly about
  ["cs"] = { "algorithm", "computation", "software", "computer science", "data structure" },
  ["cs/ml"] = { "machine learning", "deep learning", "neural network", "neural networks", "gradient descent",
    "backpropagation", "reinforcement learning", "supervised learning", "unsupervised learning", "training data",
    "transformer", "transformers", "attention mechanism", "convolutional", "stochastic gradient", "loss function",
    "representation learning", "generative model", "generative models", "diffusion model", "language model",
    "language models", "large language", "overfitting", "support vector", "bayesian optimization", "classifier",
    "fine-tuning", "pretrained", "embeddings", "autoencoder", "recurrent neural", "learning rate" },
  ["cs/ai"] = { "artificial intelligence", "knowledge representation", "multi-agent", "automated reasoning",
    "heuristic search", "constraint satisfaction", "expert system", "planning problem", "intelligent agent",
    "intelligent agents", "automated planning" },
  ["cs/nlp"] = { "natural language processing", "machine translation", "parsing", "tokenization", "treebank",
    "word embeddings", "named entity", "language modeling", "corpus", "text generation" },
  ["linguistics/computational"] = { "computational linguistics" },
  ["cs/vision"] = { "computer vision", "image classification", "object detection", "image segmentation",
    "image recognition", "visual recognition" },
  ["cs/complexity"] = { "complexity class", "np-complete", "np-hard", "polynomial time", "turing machine",
    "circuit complexity", "pspace", "computational complexity", "lower bound", "proof complexity", "reducibility" },
  ["cs/algorithms"] = { "approximation algorithm", "data structures", "dynamic programming", "randomized algorithm",
    "graph algorithm", "graph algorithms", "running time", "sorting", "shortest path" },
  ["cs/programming-languages"] = { "programming language", "programming languages", "type system", "compiler",
    "functional programming", "lambda calculus", "type checking", "garbage collection", "interpreter",
    "operational semantics", "denotational semantics", "type inference" },
  ["cs/information-theory"] = { "information theory", "channel capacity", "coding theory", "error-correcting",
    "mutual information", "source coding", "shannon entropy", "rate-distortion" },
  ["cs/systems"] = { "operating system", "distributed system", "distributed systems", "concurrency", "database",
    "file system", "network protocol", "virtual machine", "fault tolerance" },
  ["cs/security"] = { "cryptography", "encryption", "public key", "cipher", "authentication", "cryptographic" },
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
  local ix = {} -- built whole, then put in place (a task may be interrupted)
  for subject, terms in pairs(M.lexicon) do
    for _, term in ipairs(terms) do
      ix[term] = ix[term] or {}
      table.insert(ix[term], subject)
    end
  end
  index = ix
end

--- Returns the subjects for a piece of text, ranked best first.
-- @tparam string text
-- @treturn {table,...} `{ {subject=, score=}, ... }`
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
