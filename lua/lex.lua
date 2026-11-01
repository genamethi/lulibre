--- Ready-made patterns, made with expr, for what has a known form.
--
-- An identifier's pattern is named after its type, as calibre names it.
-- It captures the identifier in its canonical form (mesr.canonical's), and
-- matches only where the check digit is right; it takes a label before
-- the number ("ISBN 0-387-90040-3", "doi:10...") as part of the match.
--
--     local expr, lex = require "expr", require "lex"
--     expr.match("ISBN 0-387-90040-3", lex.isbn)     --> "9780387900407"
--     for doi in expr.gmatch(t, lex.doi) do ... end
--     expr.match("arXiv:1012.6008v1 [math.CO]", lex.arxiv) --> "1012.6008", "math.CO"
--
-- @library lex
local expr = require "expr"
local mesr = require "mesr"

local P, S, R, B, C, Cmt = expr.P, expr.S, expr.R, expr.B, expr.C, expr.Cmt

local M = {}

local digit = R "09"
local alnum = R("09", "AZ", "az")

-- p made a capture that check turns into the identifier, or fails
local function checked(p, check)
  return Cmt(p, function(_, pos, s)
    local id = check(s)
    if id then return pos, id end
    return false
  end)
end

-- n digits, sep allowed between any two, the last one last
local function digits(n, sep, last)
  local p = digit
  for _ = 2, n - 1 do p = p * sep ^ -1 * digit end
  return p * sep ^ -1 * (last or digit)
end

local function isbn13_ok(d)
  local sum = 0
  for i = 1, 13 do sum = sum + (d:byte(i) - 48) * (i % 2 == 0 and 3 or 1) end
  return sum % 10 == 0 and (d:sub(1, 3) == "978" or d:sub(1, 3) == "979")
end

local function isbn10_ok(d)
  local sum = 0
  for i = 1, 10 do
    local c = d:sub(i, i)
    sum = sum + (c == "X" and 10 or c:byte() - 48) * (11 - i)
  end
  return sum % 11 == 0
end

local function isbn(s)
  local d = s:gsub("[^%dXx]", ""):upper()
  if (#d == 13 and isbn13_ok(d)) or (#d == 10 and isbn10_ok(d)) then return mesr.canonical("isbn", d) end
end

local function number(sep)
  return C(digits(13, sep) + digits(10, sep, digit + S "Xx")) * -(alnum)
end

local isbn_label = (S "eE" * P "-" ^ -1) ^ -1 * (P "ISBN" + "isbn" + "Isbn") * (S "- " ^ -1 * "1" * S "03") ^ -1 * S ":. \t" ^ 0

--- An ISBN, 10 or 13 digits, captured as 13. Its digits may be split by
-- hyphens, or after the label ISBN by spaces too.
M.isbn = -B(alnum + "-") * checked(isbn_label * number(S "- ") + number(P "-"), isbn)
local isbn_labelled = -B(alnum) * checked(isbn_label * number(S "- "), isbn)

local function issn(s)
  local d = s:gsub("[^%dXx]", ""):upper()
  local sum = 0
  for i = 1, 7 do sum = sum + (d:byte(i) - 48) * (9 - i) end
  local check = (11 - sum % 11) % 11
  if d:sub(8, 8) == (check == 10 and "X" or tostring(check)) then return d:sub(1, 4) .. "-" .. d:sub(5, 8) end
end

--- An ISSN, after its label: "ISSN 0012-7094", captured as "0012-7094".
M.issn = checked((P "ISSN" + "issn") * S ": \t" ^ 0 * C(digit * digit * digit * digit * P "-" ^ -1 * digit * digit * digit
                                                    * (digit + S "Xx")) * -alnum, issn)

-- A DOI runs to the first space, comma, semicolon, quote or bracket; a
-- parenthesis is part of it when it is closed within it (Elsevier's
-- "S1570-7954(96)80014-3"), and a closing one it did not open ends it
-- ("(see doi:10.1/x)"). Full stops at its end are the sentence's.
local function doi(s)
  local opened = 0
  for i = 1, #s do
    local c = s:sub(i, i)
    if c == "(" then opened = opened + 1
    elseif c == ")" then
      if opened == 0 then
        s = s:sub(1, i - 1)
        break
      end
      opened = opened - 1
    end
  end
  s = s:gsub("%.+$", "")
  if s:find("/.") then return mesr.canonical("doi", s) end
end

-- as a scan may read it too: "dol:", "d0i"
local doi_label = (P "https://" + "http://") * (P "dx." ^ -1) * "doi.org/"
  + S "dD" * S "oO0" * S "iIlL1" * S ": \t" ^ 0
  + (P "Digital Object Identifier" + "digital object identifier") * S ": \t" ^ 0

--- A DOI, with or without its label (doi:, https://doi.org/), captured in
-- lower case without it.
local doi_number = C(P "10." * digit ^ 4 * "/" * (1 - S " \t\n\f,;\"'<>[]{}") ^ 1)
M.doi = checked(doi_label ^ -1 * doi_number, doi)

local arxiv_new = digit * digit * digit * digit * "." * digit * digit * digit * digit * digit ^ -1
local arxiv_old = (R "az" + "-") ^ 1 * (P "." * R "AZ" * R "AZ") ^ -1 * "/" * digits(7, P(false))

--- An arXiv number after its label (arXiv:1012.6008v1), captured without
-- its version; and, when its margin stamp follows ("[math.CO]"), the
-- class.
M.arxiv = (P "arXiv" + "arxiv" + "ARXIV") * ":" * S " \t" ^ 0 * C(arxiv_new + arxiv_old) / string.lower
  * (P "v" * digit ^ 1) ^ -1 * (S " \t" ^ 0 * "[" * C((alnum + S ".-") ^ 1) * "]") ^ -1

--- The patterns that match an identifier only with its label before it.
M.labelled = { isbn = isbn_labelled, doi = -B(alnum) * checked(doi_label * doi_number, doi), arxiv = M.arxiv }

return M
