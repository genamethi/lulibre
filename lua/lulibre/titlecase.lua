-- Title case, after the APA Publication Manual (7th edition):
--
--   * the first word of the title, and of a subtitle (after a colon, a dash
--     or the end of a sentence), is capitalised;
--   * so is every major word, and every word of four letters or more;
--   * minor words of three letters or fewer stay in lower case: articles,
--     short conjunctions and short prepositions (M.minor);
--   * both parts of a hyphenated major word are capitalised (Self-Report),
--     but not the word after a hyphenated prefix (Anti-hero, Mid-year).
--
-- A title set in CAPITALS has lost what case would have said, so some of it
-- is guessed back: Roman numerals stay as they are, as do words with a digit
-- in them and short words with no vowel (PDF, NMR), and M.keep lists words
-- that are always spelled one way. In a title that is not all capitals, a
-- word that already has capitals past its first letter (LaTeX, PDE, McKean)
-- is left alone.
--
--   local tc = require "lulibre.titlecase"
--   tc.apply("ON THE THEORY OF GROUPS: AN INTRODUCTION")
--     --> "On the Theory of Groups: An Introduction"
--   tc.is_caps("SIEVE METHODS")      --> true
--   tc.minor["with"] = true          -- treat "with" as a minor word too
--   tc.keep["cw"] = "CW"             -- always spell it CW
local M = {}

local function set(words)
  local out = {}
  for w in words:gmatch("%S+") do out[w] = true end
  return out
end

-- lower case unless first: articles, conjunctions and prepositions of three
-- letters or fewer
M.minor = set "a an the and as but for if nor or so yet at by in of off on per to up via"

-- a prefix before a hyphen: the word after it stays in lower case
M.prefixes = set [[anti co counter de extra hyper inter intra macro micro mid mini multi non over post pre pro
  pseudo quasi re semi sub super trans ultra un under]]

-- words spelled one way whatever the title does; the key is the word in lower case
M.keep = {
  pde = "PDE", pdes = "PDEs", ode = "ODE", odes = "ODEs", sde = "SDE", sdes = "SDEs",
  usa = "USA", uk = "UK", ussr = "USSR", ieee = "IEEE", acm = "ACM", ams = "AMS", siam = "SIAM",
  dna = "DNA", rna = "RNA", ai = "AI", cpu = "CPU", gpu = "GPU", api = "API", unix = "UNIX",
  latex = "LaTeX", tex = "TeX", ["c*"] = "C*", ["c*-algebras"] = "C*-Algebras", ["c*-algebra"] = "C*-Algebra",
  mr = "Mr", mrs = "Mrs", ms = "Ms", dr = "Dr", st = "St", vs = "vs", jr = "Jr", sr = "Sr",
}

local lower = function(s) return lulibre.lower(s) end
local upper = function(s) return lulibre.upper(s) end

--- Is the text set in capitals? True when it has at least two letters and
-- none of them is in lower case.
function M.is_caps(s)
  if type(s) ~= "string" then return false end
  local letters = 0
  for _ in s:gmatch("[%a\128-\255]") do letters = letters + 1 end
  return letters >= 2 and upper(s) == s and lower(s) ~= s
end

-- I to XXXIX, written with I, V and X: the numerals volumes and parts carry.
-- (Longer ones collide with words: MIX, DIV, LIVID.)
local function is_roman(word)
  if not word:match("^[IVX]+$") then return false end
  local value, n = { I = 1, V = 5, X = 10 }, 0
  for i = 1, #word do
    local v, nxt = value[word:sub(i, i)], value[word:sub(i + 1, i + 1)]
    n = n + ((nxt and nxt > v) and -v or v)
  end
  if n < 1 or n > 39 then return false end
  local back = ("X"):rep(n // 10) .. ({ "", "I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX" })[n % 10 + 1]
  return back == word
end

-- the first character of s (one UTF-8 sequence) in upper case, the rest as it is
local function capitalise(s)
  local first = s:match("^[%z\1-\127\194-\244][\128-\191]*") or ""
  return upper(first) .. s:sub(#first + 1)
end

-- One word without the punctuation around it. caps: the whole title is in
-- capitals; first: it opens the title or a subtitle.
local function word(core, caps, first)
  local low = lower(core)
  if M.keep[low] then return M.keep[low] end
  if core:find("%d") then return core end
  if low:match("^%a%.%a[%a.]*$") and #low <= 9 then return upper(low) end -- U.S.A, N.Y
  local o, rest_of = low:match("^(%a)'(%a.*)$") -- O'Neil, D'Alembert
  if o and caps then return upper(o) .. "'" .. capitalise(rest_of) end
  if caps then
    if is_roman(core) then return core end
    -- an initialism: short, letters only, no vowel to say it with
    if #core >= 2 and #core <= 5 and core:match("^%u+$") and not core:find("[AEIOUY]") then return core end
  else
    -- capitals past the first letter were put there on purpose
    local rest = core:gsub("^[%z\1-\127\194-\244][\128-\191]*", "", 1)
    if lower(rest) ~= rest then return core end
  end
  if not low:find("-", 1, true) then
    if M.minor[low] and not first then return low end
    return capitalise(low)
  end
  -- a hyphenated word, part by part
  local parts, i, before = {}, 0, nil
  for part in (low .. "-"):gmatch("(.-)%-") do
    i = i + 1
    if M.keep[part] then
      parts[i] = M.keep[part]
    elseif i == 1 then
      parts[i] = (M.minor[part] and not first) and part or capitalise(part)
    elseif M.prefixes[before] or M.minor[part] then
      parts[i] = part
    else
      parts[i] = capitalise(part)
    end
    before = part
  end
  return table.concat(parts, "-")
end

--- The title in title case.
function M.apply(s)
  if type(s) ~= "string" or s == "" then return s end
  local caps = M.is_caps(s)
  local out, first = {}, true
  for space, token in s:gmatch("(%s*)(%S+)") do
    -- punctuation around the word is carried over untouched
    local lead, core, trail = token:match("^([%p]*)(.-)([%p]*)$")
    if core == "" or token == "–" or token == "—" then
      -- punctuation alone: a dash or colon between spaces opens a subtitle
      out[#out + 1] = space .. token
      if token == "-" or token == "--" or token == "–" or token == "—" or token == ":" then first = true end
    else
      -- brackets and quotes may be part of the word as written (C*, f(x)): only
      -- strip what cannot be
      local open, close = lead:match("^(.-)([*]*)$")
      lead, core = open, close .. core
      local star = trail:match("^[*']+")
      if star then core, trail = core .. star, trail:sub(#star + 1) end
      out[#out + 1] = space .. lead .. word(core, caps, first) .. trail
      first = trail:find("[:.?!]$") ~= nil or trail:find("—", 1, true) ~= nil
    end
  end
  return table.concat(out)
end

--- Roman numerals a catalogue put in title case ("Lectures in Abstract
-- Algebra: Ii. Linear Algebra") back in capitals. Only numerals of two
-- letters or more, and not "Xi" (a name, a Greek letter) nor "Vi" unless
-- a full stop follows it.
function M.numerals(s)
  if type(s) ~= "string" then return s end
  return (s:gsub("%f[%a](%u[ivx]+)%f[%A](%.?)", function(w, dot)
    local up = w:upper()
    if not is_roman(up) or w == "Xi" or (w == "Vi" and dot == "") then return nil end
    return up .. dot
  end))
end

--- The title as it should be proposed: in title case when it was found in
-- capitals and the option title_case allows; otherwise as it is.
function M.proposed(s)
  if lulibre.o.title_case ~= "never" and M.is_caps(s) then return M.apply(s) end
  return s
end

return M
