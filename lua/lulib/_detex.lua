--- Converts the TeX in paper records to plain text. arXiv and zbMATH keep
-- titles and names as their authors typed them ("Erd\H{o}s", "Bal\'azs",
-- "$p$-adic").
--
-- `plain` also returns whether any TeX is left.
--
-- @library lulib._detex
-- @usage
-- local detex = require "lulib._detex"
-- detex.plain("A proof of the Erd\\H{o}s primitive set conjecture")
--   --> "A proof of the Erdős primitive set conjecture", true
-- detex.plain("On $\\mathbb{Z}_p$-extensions")
--   --> "On $\\mathbb{Z}_p$-extensions", false      -- mathematics is left as it is
local M = {}

--- TeX's accent commands, by the letter that names them.
M.accents = {
  ["'"] = { a = "á", e = "é", i = "í", o = "ó", u = "ú", y = "ý", c = "ć", n = "ń", s = "ś", z = "ź", l = "ĺ", r = "ŕ",
    A = "Á", E = "É", I = "Í", O = "Ó", U = "Ú", Y = "Ý", C = "Ć", N = "Ń", S = "Ś", Z = "Ź" },
  ["`"] = { a = "à", e = "è", i = "ì", o = "ò", u = "ù", A = "À", E = "È", I = "Ì", O = "Ò", U = "Ù" },
  ["^"] = { a = "â", e = "ê", i = "î", o = "ô", u = "û", c = "ĉ", g = "ĝ", s = "ŝ", w = "ŵ", y = "ŷ",
    A = "Â", E = "Ê", I = "Î", O = "Ô", U = "Û" },
  ['"'] = { a = "ä", e = "ë", i = "ï", o = "ö", u = "ü", y = "ÿ", A = "Ä", E = "Ë", I = "Ï", O = "Ö", U = "Ü" },
  ["~"] = { a = "ã", n = "ñ", o = "õ", A = "Ã", N = "Ñ", O = "Õ" },
  ["="] = { a = "ā", e = "ē", i = "ī", o = "ō", u = "ū", A = "Ā", E = "Ē", I = "Ī", O = "Ō", U = "Ū" },
  ["."] = { z = "ż", c = "ċ", e = "ė", g = "ġ", Z = "Ż", I = "İ" },
  H = { o = "ő", u = "ű", O = "Ő", U = "Ű" },
  v = { c = "č", s = "š", z = "ž", r = "ř", e = "ě", n = "ň", d = "ď", t = "ť",
    C = "Č", S = "Š", Z = "Ž", R = "Ř", E = "Ě", N = "Ň", D = "Ď", T = "Ť" },
  c = { c = "ç", s = "ş", t = "ţ", C = "Ç", S = "Ş", T = "Ţ" },
  u = { a = "ă", g = "ğ", u = "ŭ", A = "Ă", G = "Ğ" },
  k = { a = "ą", e = "ę", A = "Ą", E = "Ę" },
  r = { a = "å", u = "ů", A = "Å", U = "Ů" },
}

--- TeX's commands for special letters (\\o, \\ss, \\l ...).
M.letters = { o = "ø", O = "Ø", ss = "ß", l = "ł", L = "Ł", ae = "æ", AE = "Æ", oe = "œ", OE = "Œ", aa = "å", AA = "Å",
  i = "ı", j = "ȷ" }

--- Returns the text without its TeX, and whether any TeX is left.
-- @tparam string s
-- @treturn string
-- @treturn boolean true if no TeX is left
function M.plain(s)
  if type(s) ~= "string" or not s:find("[\\${}~`]") then return s, true end
  local function accent(mark, letter)
    local row = M.accents[mark]
    -- a dotless i under an accent is an i
    if letter == "\\i" then letter = "i" end
    return row and (row[letter] or letter) or nil
  end
  -- \'\i and \"\i : the dotless i, and the space that ends its name
  s = s:gsub("{?\\([`'%^\"~=%.])%s*{?\\([ij])%s*}?}?", function(mark, letter) return accent(mark, letter) end)
  -- \'e  \'{e}  {\'e}   and   \H{o}  \v c  {\v{c}}
  s = s:gsub("{?\\([`'%^\"~=%.])%s*{?(\\?%a)}?}?", function(mark, letter) return accent(mark, letter) end)
  s = s:gsub("{?\\([Hvcukr])%s*{(\\?%a)}}?", function(mark, letter) return accent(mark, letter) end)
  s = s:gsub("{?\\([Hvcukr])%s+(%a)}?", function(mark, letter) return accent(mark, letter) end)
  -- \o  {\o}  \o{}  \ss
  s = s:gsub("{?\\(%a+)%s*{?}?", function(name)
    return M.letters[name]
  end)
  s = s:gsub("\\([&%%_#])", "%1"):gsub("\\%-", ""):gsub("``", "“"):gsub("''", "”"):gsub("%-%-%-", "—"):gsub("%-%-", "–")
  s = s:gsub("([^\\])~", "%1 ")
  -- mathematics that is only letters and figures needs no dollars: $p$-adic, $2$
  s = s:gsub("%$([%w%s%-+=,.()]*)%$", "%1")
  -- braces that group nothing now
  if not s:find("[\\$]") then s = s:gsub("[{}]", "") end
  return s, not s:find("[\\${}]")
end

return M
