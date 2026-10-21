--- Mathematics in titles, written in Unicode: SL₂(ℤ), GLₙ(ℚₚ), 𝔽ₚ[T], X³ − 5.
--
-- It comes from three places:
--
--   * the book's own pages: the PDF reader marks up a line's mathematics as
--     TeX from the fonts and the size and height of each character
--     ("COMPACT SUBGROUPS OF $GL_{n}(\mathbf{Q}_{p})$"; lulibre.lines gives
--     it as math=), and M.title turns that into the title;
--   * TeX in a record's title, as arXiv gives it ("On $\mathbb{Z}_p$-extensions"):
--     M.render;
--   * a title in plain text, where the scripts were lost on the way
--     ("SL2(Z)", "GLn(Qp)", "X3 −5"): the glossary, M.notation. It only
--     changes what reads one way; what could be read two ways is left.
--
-- Search is not affected: lulibre.fold, and calibre's own search, read
-- SL₂(ℤ) as SL2(Z).
--
-- Unicode has no subscript for some letters (b c d f g q w y z) nor a
-- superscript q: those are written _q and ^q, and longer ones _{…}.
-- The option math_notation = "off" leaves titles as they come.
--
-- @module lulibre.notation
-- @usage
-- local m = require "lulibre.notation"
-- m.render("$a^x+b^y=c^z$")              --> "aˣ + bʸ = cᶻ"
-- m.notation("Representations of SL2(Z)") --> "Representations of SL₂(ℤ)"
-- m.title("COMPACT SUBGROUPS OF $GL_{n}(\\mathbf{Q}_{p})$", require("lulibre.names").title_caps)
--   --> "Compact Subgroups of GLₙ(ℚₚ)"
-- table.insert(m.groups, "PU")           -- PU2 as PU₂
local M = {}

local function map(keys, values)
  local out, i = {}, 0
  for v in values:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    i = i + 1
    out[keys[i]] = v
  end
  return out
end

local function chars(s)
  local out = {}
  for c in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do out[#out + 1] = c end
  return out
end

--- Superscripts in Unicode, by the character they raise.
M.sup = map(chars "0123456789+-=()abcdefghijklmnoprstuvwxyzABDEGHIJKLMNOPRTUVW",
  "⁰¹²³⁴⁵⁶⁷⁸⁹⁺⁻⁼⁽⁾ᵃᵇᶜᵈᵉᶠᵍʰⁱʲᵏˡᵐⁿᵒᵖʳˢᵗᵘᵛʷˣʸᶻᴬᴮᴰᴱᴳᴴᴵᴶᴷᴸᴹᴺᴼᴾᴿᵀᵁⱽᵂ")
M.sup["−"], M.sup["α"], M.sup["β"], M.sup["γ"], M.sup["δ"], M.sup["θ"], M.sup["φ"], M.sup["χ"], M.sup["′"] =
  "⁻", "ᵅ", "ᵝ", "ᵞ", "ᵟ", "ᶿ", "ᵠ", "ᵡ", "′"
--- Subscripts in Unicode, by the character they lower.
M.sub = map(chars "0123456789+-=()aehijklmnoprstuvx", "₀₁₂₃₄₅₆₇₈₉₊₋₌₍₎ₐₑₕᵢⱼₖₗₘₙₒₚᵣₛₜᵤᵥₓ")
M.sub["−"], M.sub["β"], M.sub["γ"], M.sub["ρ"], M.sub["φ"], M.sub["χ"] = "₋", "ᵦ", "ᵧ", "ᵨ", "ᵩ", "ᵪ"

-- the mathematical alphabets: the first capital's code point, then the
-- letters Unicode had already (ℤ) where that alphabet has a hole
local ALPHABETS = {
  mathbb = { 0x1D538, 0x1D552, C = "ℂ", H = "ℍ", N = "ℕ", P = "ℙ", Q = "ℚ", R = "ℝ", Z = "ℤ" },
  mathfrak = { 0x1D504, 0x1D51E, C = "ℭ", H = "ℌ", I = "ℑ", R = "ℜ", Z = "ℨ" },
  mathcal = { 0x1D49C, 0x1D4B6, B = "ℬ", E = "ℰ", F = "ℱ", H = "ℋ", I = "ℐ", L = "ℒ", M = "ℳ", R = "ℛ",
    e = "ℯ", g = "ℊ", o = "ℴ" },
}
ALPHABETS.mathscr = ALPHABETS.mathcal
ALPHABETS.Bbb = ALPHABETS.mathbb

local function letter_in(alphabet, c)
  if alphabet[c] then return alphabet[c] end
  if c:match("^%u$") then return utf8.char(alphabet[1] + c:byte() - 65) end
  if c:match("^%l$") then return utf8.char(alphabet[2] + c:byte() - 97) end
  if alphabet == ALPHABETS.mathbb and c:match("^%d$") then return utf8.char(0x1D7D8 + c:byte() - 48) end
  return c
end

--- the number systems, which are set in bold as often as in blackboard
M.bold = { Z = "ℤ", Q = "ℚ", R = "ℝ", C = "ℂ", N = "ℕ" }

--- TeX's commands for letters and symbols, by name, as Unicode.
M.symbols = {
  alpha = "α", beta = "β", gamma = "γ", delta = "δ", epsilon = "ϵ", varepsilon = "ε", zeta = "ζ", eta = "η",
  theta = "θ", vartheta = "ϑ", iota = "ι", kappa = "κ", lambda = "λ", mu = "μ", nu = "ν", xi = "ξ", pi = "π",
  varpi = "ϖ", rho = "ρ", varrho = "ϱ", sigma = "σ", varsigma = "ς", tau = "τ", upsilon = "υ", phi = "ϕ",
  varphi = "φ", chi = "χ", psi = "ψ", omega = "ω", Gamma = "Γ", Delta = "Δ", Theta = "Θ", Lambda = "Λ",
  Xi = "Ξ", Pi = "Π", Sigma = "Σ", Upsilon = "Υ", Phi = "Φ", Psi = "Ψ", Omega = "Ω",
  ell = "ℓ", hbar = "ℏ", aleph = "ℵ", infty = "∞", partial = "∂", nabla = "∇", emptyset = "∅", varnothing = "∅",
  times = "×", otimes = "⊗", oplus = "⊕", wedge = "∧", vee = "∨", cdot = "·", cdots = "⋯", ldots = "…",
  dots = "…", ast = "∗", star = "⋆", circ = "∘", bullet = "•", pm = "±", mp = "∓", setminus = "∖",
  backslash = "\\", mid = "|", colon = ":", prime = "′",
  to = "→", rightarrow = "→", mapsto = "↦", leftarrow = "←", hookrightarrow = "↪", twoheadrightarrow = "↠",
  le = "≤", leq = "≤", ge = "≥", geq = "≥", ne = "≠", neq = "≠", approx = "≈", sim = "∼", simeq = "≃",
  cong = "≅", equiv = "≡", ["in"] = "∈", notin = "∉", subset = "⊂", subseteq = "⊆", supset = "⊃",
  supseteq = "⊇", cup = "∪", cap = "∩", forall = "∀", exists = "∃", neg = "¬", lnot = "¬",
  sum = "∑", prod = "∏", int = "∫", oint = "∮", langle = "⟨", rangle = "⟩", lfloor = "⌊", rfloor = "⌋",
  lceil = "⌈", rceil = "⌉", lvert = "|", rvert = "|", vert = "|",
  -- spacing, and sizes that need none here
  [","] = " ", [";"] = " ", [":"] = " ", ["!"] = "", quad = " ", qquad = " ", left = "", right = "",
  big = "", Big = "", bigl = "", bigr = "", displaystyle = "", limits = "",
  ["{"] = "{", ["}"] = "}", ["_"] = "_", ["$"] = "$", ["%"] = "%", ["&"] = "&", ["#"] = "#",
}
-- commands whose argument is set as it is
local AS_IS = { mathrm = true, operatorname = true, text = true, textrm = true, mathit = true, textit = true,
  mathsf = true, mathtt = true, textbf = true, mbox = true, hbox = true, rm = true }
-- accents: the combining mark that goes after the letter
local ACCENTS = { bar = "\204\132", overline = "\204\133", hat = "\204\130", widehat = "\204\130",
  tilde = "\204\131", widetilde = "\204\131", dot = "\204\135", ddot = "\204\136", vec = "\226\131\151" }

-- a script in Unicode, or written _x / _{xy} where Unicode has no form for it
local function script(table_, mark, s)
  local out = {}
  for _, c in ipairs(chars(s)) do
    if not table_[c] then return #chars(s) == 1 and mark .. s or mark .. "{" .. s .. "}" end
    out[#out + 1] = table_[c]
  end
  return table.concat(out)
end

-- the argument of a command or a script: {…} or one character (or one command)
local function argument(s, i)
  i = s:match("^%s*()", i)
  local c = s:sub(i, i)
  if c == "{" then
    local depth, j = 0, i
    while j <= #s do
      local d = s:sub(j, j)
      if d == "\\" then j = j + 1
      elseif d == "{" then depth = depth + 1
      elseif d == "}" then
        depth = depth - 1
        if depth == 0 then return s:sub(i + 1, j - 1), j + 1 end
      end
      j = j + 1
    end
    return nil
  elseif c == "\\" then
    local name = s:match("^\\(%a+)", i) or s:sub(i + 1, i + 1)
    return "\\" .. name, i + 1 + #name
  elseif c ~= "" then
    local ch = s:match("^[%z\1-\127\194-\244][\128-\191]*", i)
    return ch, i + #ch
  end
  return nil
end

local RELATIONS = {}
for _, r in ipairs { "=", "+", "−", "×", "⊗", "⊕", "≤", "≥", "≠", "≈", "∼", "≃", "≅", "≡", "→", "↦", "←", "∈",
  "∉", "⊂", "⊆", "⊃", "⊇", "∪", "∩", "±", "∓", "<", ">", "↪", "↠" } do RELATIONS[r] = true end

-- a sign between two operands is spaced, one that opens (−5, (−1)) is not
local function spaced(s)
  local cs, out = chars((s:gsub("%s+", " "))), {}
  local prev -- the last character that is not a space
  for i, c in ipairs(cs) do
    if c == " " then
      -- spaces are TeX's to set, and the signs below put theirs back; but
      -- one between two words stays (the page's own: "⊗ and ∧")
      local nxt = cs[i + 1]
      if prev and nxt and not RELATIONS[prev] and not RELATIONS[nxt] and prev:match("^[%w\128-\255]")
        and nxt:match("^[%w\128-\255]") then
        out[#out + 1] = " "
      end
    elseif (RELATIONS[c] or c == "-") and prev and not RELATIONS[prev] and prev ~= "(" and prev ~= "[" and prev ~= "-"
      and cs[i + 1] and cs[i + 1] ~= ")" then
      if c == "-" then c = "−" end
      -- (a hyphen between letters is a word's: p-adic)
      if c == "−" and cs[i - 1] ~= " " and cs[i + 1] ~= " " and prev:match("^%a$") and (cs[i + 1] or ""):match("^%a$")
        and cs[i] == "-" then
        out[#out + 1] = "-"
      else
        out[#out + 1] = " " .. c .. " "
      end
      prev = c
    else
      if c == "," then c = ", " end
      out[#out + 1] = c
      prev = c
    end
  end
  return (table.concat(out):gsub(" +", " "):gsub("^ ", ""):gsub(" $", ""):gsub("%( ", "("):gsub(" %)", ")"))
end

--- One formula (what stands between dollars) in Unicode, or nil when it
-- holds something that has none (a fraction, a matrix, a command lulibre
-- does not know).
-- @tparam string tex
-- @treturn string|nil
function M.unicode(tex)
  local out, i, ok = {}, 1, true
  local function put(s) out[#out + 1] = s end
  while ok and i <= #tex do
    local c = tex:sub(i, i)
    if c == "\\" then
      local name = tex:match("^\\(%a+)", i) or tex:sub(i + 1, i + 1)
      i = i + 1 + #name
      if ALPHABETS[name] or name == "mathbf" or name == "boldsymbol" or name == "bf" then
        local arg
        arg, i = argument(tex, i)
        if not arg then return nil end
        for _, ch in ipairs(chars(arg)) do
          if name == "mathbf" or name == "boldsymbol" or name == "bf" then
            -- bold 𝔽 only where it has a script after it (𝔽ₚ): a bold F alone may be any field
            local scripted = tex:sub(i, i) == "_" or tex:sub(i, i) == "^"
            put(M.bold[ch] or (ch == "F" and scripted and "𝔽") or ch)
          else
            put(letter_in(ALPHABETS[name], ch))
          end
        end
      elseif AS_IS[name] then
        local arg
        arg, i = argument(tex, i)
        if not arg then return nil end
        local inner = M.unicode(arg)
        if not inner then return nil end
        put(inner)
      elseif ACCENTS[name] then
        local arg
        arg, i = argument(tex, i)
        local inner = arg and M.unicode(arg)
        if not inner or #chars(inner) ~= 1 then return nil end
        put(inner .. ACCENTS[name])
      elseif name == "sqrt" then
        local arg
        arg, i = argument(tex, i)
        local inner = arg and M.unicode(arg)
        if not inner then return nil end
        put(#chars(inner) == 1 and "√" .. inner or "√(" .. inner .. ")")
      elseif M.symbols[name] then
        put(M.symbols[name])
      else
        return nil
      end
    elseif c == "_" or c == "^" then
      local arg
      arg, i = argument(tex, i + 1)
      local inner = arg and M.unicode(arg)
      if not inner then return nil end
      -- (TeX's spacing means nothing in a script)
      inner = inner:gsub(" ", "")
      put(c == "_" and script(M.sub, "_", inner) or script(M.sup, "^", inner))
    elseif (c == "F" or c == "Q" or c == "Z") and tex:find("^_{?[pqℓ%d]}?", i + 1) and not tex:sub(i - 1, i - 1):match("%a")
      and (c == "F" or tex:find("^_{?p}?", i + 1)) then
      -- 𝔽ₚ, ℚₚ, ℤₚ in whatever type the page set them
      put(c == "F" and "𝔽" or M.bold[c])
      i = i + 1
    elseif c == "{" or c == "}" then
      i = i + 1
    elseif c == "'" then
      put("′")
      i = i + 1
    else
      local ch = tex:match("^[%z\1-\127\194-\244][\128-\191]*", i)
      put(ch)
      i = i + #ch
    end
  end
  return spaced(table.concat(out))
end

--- Text with its formulas ($…$) in Unicode; a formula that has no Unicode
-- form keeps its dollars. opts.notes: drop the footnote marks the page
-- set after a word (Semirings∗, Title¹) or alone.
-- @tparam string s
-- @tparam[opt] table opts `notes`
-- @treturn string
function M.render(s, opts)
  if type(s) ~= "string" or not s:find("$", 1, true) then return s end
  local notes = opts and opts.notes
  s = s:gsub("\\%$", "\1")
  s = s:gsub("%$(.-)%$", function(tex)
    if notes then
      local word, mark = tex:match("^(%a%a%a+)%^{([%d%*∗†‡§¶,]+)}$")
      if word then return word end
      if tex:match("^%^{[%d%*∗†‡§¶,]+}$") then return "" end
    end
    local u = M.unicode(tex)
    return u or "$" .. tex .. "$"
  end)
  return (s:gsub("\1", "$"):gsub("  +", " "):gsub("^ ", ""):gsub(" $", ""))
end

--- Does s hold mathematics in Unicode, or a formula? (Title case leaves such
-- a word alone.)
-- @tparam string s
-- @treturn boolean
function M.has_math(s)
  if type(s) ~= "string" or not s:find("[$\194-\244]") then return false end
  if s:find("$", 1, true) then return true end
  for _, cp in utf8.codes(s, true) do
    if (cp >= 0x2070 and cp <= 0x209C) or (cp >= 0x1D2C and cp <= 0x1DBF) or (cp >= 0x2100 and cp <= 0x214F)
      or (cp >= 0x1D400 and cp <= 0x1D7FF) or cp == 0xB2 or cp == 0xB3 or cp == 0xB9 or cp == 0x2C7C then
      return true
    end
  end
  return false
end

-- ---- the glossary: plain text where the scripts were lost ----

--- A subscript or a superscript in Unicode, or _q, ^{…} where it has none.
-- @tparam string s
-- @treturn string
function M.subscript(s) return script(M.sub, "_", s) end
--- A superscript in Unicode, or ^q, ^{…} where it has none.
-- @tparam string s
-- @treturn string
function M.superscript(s) return script(M.sup, "^", s) end
local subs, sups = M.subscript, M.superscript
local function bb(c) return M.bold[c] or c end

--- the groups whose index is written below: SL₂, GLₙ, PSL₂, SO₃
M.groups = { "SL", "GL", "PSL", "PGL", "SO", "SU", "Sp", "PSp", "GSp", "PSO", "PSU", "sl", "gl" }

-- a ring after a group, in brackets: (Z), (Qp), (Fq), (R)
local function ring(r)
  local base, index = r:match("^([ZQRCNF])([pqnℓl]?)$")
  if not base then
    -- a title put in lower case: sl2(z)
    base, index = r:match("^([zqrc])()$")
    if not base then return nil end
    base, index = base:upper(), ""
  end
  if base == "F" and index == "" then return nil end -- a field F: any field
  local letter = base == "F" and "𝔽" or bb(base)
  return letter .. (index ~= "" and subs(index == "l" and "ℓ" or index) or "")
end

--- Each rule takes the text and gives it back with what it knows in Unicode.
-- They only see text outside formulas; add to the list, or replace one, in
-- init.lua.
M.glossary = {
  -- SL2 GLn PSL2 SL_2 SL_{2}, with the ring after it: SL2(Z) GLn(Qp)
  function(s)
    for _, g in ipairs(M.groups) do
      s = s:gsub("%f[%w]" .. g .. "(_?{?)([%dnmk]%d*)(}?)(%(?)(%a*)(%)?)", function(under, n, brace, open, r, close)
        if (under == "_{") ~= (brace == "}") then return nil end
        if open == "" and r ~= "" then return nil end -- more of a word: not a group's name
        if open == "(" and close == ")" then r = ring(r) or r end
        return g .. subs(n) .. open .. r .. close
      end)
    end
    return s
  end,
  -- the p-adic numbers and the finite fields: Qp Zp Fp Fq F_p, before a bracket or alone
  function(s)
    return (s:gsub("%f[%w]([QZF])_?([pqℓ])%f[^%w]", function(base, p)
      return (base == "F" and "𝔽" or bb(base)) .. subs(p)
    end))
  end,
  -- quotients and polynomial rings: Z/nZ, Z/paZ, Z[i], Q[t], Q(√2)
  function(s)
    s = s:gsub("%f[%w]([ZQ])/(%w+)([ZQ])%f[^%w]", function(a, n, b) return bb(a) .. "/" .. n .. bb(b) end)
    return (s:gsub("%f[%w]([ZQ])([%[(])", function(a, bracket) return bb(a) .. bracket end))
  end,
  -- spaces: Rn Cn
  function(s)
    return (s:gsub("%f[%w]([RC])([nmd])%f[^%w]", function(a, n) return bb(a) .. sups(n) end))
  end,
  -- a number system named alone: over Q, in Z, of Z; R and C only "over" (R
  -- is a language, C too); and one coordinated with one already written (R and ℚₚ)
  function(s)
    s = s:gsub("(%f[%a][Oo][Vv][Ee][Rr] )([ZQRC])%f[^%w]", function(w, a) return w .. bb(a) end)
    s = s:gsub("(%f[%a][IiOo][NnFf] )([ZQ])%f[^%w%[(/]", function(w, a) return w .. bb(a) end)
    -- (ℤ ℚ ℝ ℂ are three bytes each, 𝔽 four: no use in a character class)
    local function written(c) return c == "ℤ" or c == "ℚ" or c == "ℝ" or c == "ℂ" or c == "𝔽" end
    s = s:gsub("%f[%w]([ZQRC])( [Aa][Nn][Dd] )([\226\240][\128-\191]+)", function(a, w, b)
      local first = b:match("^[\226][\128-\191][\128-\191]") or b:match("^[\240][\128-\191][\128-\191][\128-\191]")
      if first and written(first) then return bb(a) .. w .. b end
    end)
    return (s:gsub("([\226\240][\128-\191]+[^%s]*)( [Aa][Nn][Dd] )([ZQ])%f[^%w%[(/]", function(a, w, b)
      local first = a:match("^[\226][\128-\191][\128-\191]") or a:match("^[\240][\128-\191][\128-\191][\128-\191]")
      if first and written(first) then return a .. w .. bb(b) end
    end))
  end,
  -- a polynomial: X3 −5, T2 + 1
  function(s)
    s = s:gsub("%f[%w]([XYTxyt])(%d+)( ?)([%-+]) ?(%d)", function(x, n, _, sign, d)
      return x .. sups(n) .. " " .. (sign == "-" and "−" or sign) .. " " .. d
    end)
    return (s:gsub("%f[%w]([XYTxyt])(%d+) ?− ?(%d)", function(x, n, d) return x .. sups(n) .. " − " .. d end))
  end,
  -- K-theory's groups: K0 (or Ko, as it is often read), K1, K2
  function(s)
    if not s:lower():find("k%-theory") then return s end
    return (s:gsub("%f[%w]K([o%d])%f[^%w]", function(n) return "K" .. subs(n == "o" and "0" or n) end))
  end,
  -- ℓ-adic, read as `-adic or l-adic
  function(s)
    return (s:gsub("`%-([Aa]dic)", "ℓ-%1"):gsub("%f[%w]l%-([Aa]dic)", "ℓ-%1"))
  end,
  -- scripts written out: L^2, a^x, SL_2, X_{0}(N)
  function(s)
    s = s:gsub("%f[%w](%u?%u?%a)_{?([%w+%-]+)}?", function(base, n)
      if #base > 1 and not base:match("^%u+$") then return nil end
      return base .. subs(n)
    end)
    return (s:gsub("%f[%w](%a)%^{?([%w+%-]+)}?", function(base, n) return base .. sups(n) end))
  end,
}

--- Plain text with the glossary's notation in Unicode. Formulas ($…$) are
-- left to M.render.
-- @tparam string s
-- @treturn string
function M.notation(s)
  if type(s) ~= "string" or s == "" or lulibre.o.math_notation == "off" then return s end
  local parts = {}
  -- (each rule sees the text between formulas)
  for text, formula in (s .. "$$"):gsub("\\%$", "\1"):gmatch("(.-)(%$.-%$)") do
    local plain = text
    for _, rule in ipairs(M.glossary) do plain = rule(plain) or plain end
    parts[#parts + 1] = plain .. (formula ~= "$$" and formula or "")
  end
  return (table.concat(parts):gsub("\1", "\\$"))
end

--- A title marked up as the PDF reader marks it, or with TeX from a record:
-- case (a function, such as titlecase.proposed) is given the words, with
-- the formulas held aside; the glossary is given what is outside them; and
-- the formulas are written in Unicode. With math_notation = "off", the
-- title is as case has it and its formulas in TeX.
-- @tparam string s
-- @tparam[opt] function case `case(words)` -> words
-- @treturn string
function M.title(s, case)
  if type(s) ~= "string" then return s end
  local held = {}
  local text = s:gsub("\\%$", "\1"):gsub("%$(.-)%$", function(tex)
    held[#held + 1] = tex
    return utf8.char(0xE000 + #held)
  end)
  text = text:gsub("\1", "$"):gsub("\\\\", "\\")
  if case then
    -- (a word hyphened to a formula is in lower case whatever the style: p-adic)
    text = case(text):gsub("([\238][\128-\191][\128-\191]%-)(%a+)", function(f, w) return f .. lulibre.lower(w) end)
  end
  local off = lulibre.o.math_notation == "off"
  if not off then
    for _, rule in ipairs(M.glossary) do text = rule(text) or text end
  end
  text = text:gsub("[\238][\128-\191][\128-\191]", function(ch)
    local tex = held[utf8.codepoint(ch) - 0xE000]
    if not tex then return ch end
    local w = M.render("$" .. tex .. "$", { notes = true })
    if off and w ~= "" then return "$" .. tex .. "$" end
    return w
  end)
  return (text:gsub("  +", " "):gsub("^ ", ""):gsub(" $", ""))
end

return M
