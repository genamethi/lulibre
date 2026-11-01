--- Recognises and cleans people's names. Tells a name from an institution
-- or a stray title word, splits lists of authors, and fixes ALL CAPS.
--
-- @library lulib._names
-- @usage
-- local names = require "lulib._names"
-- names.split("A. Author; B. Author and C. Author")  --> { "A. Author", "B. Author", "C. Author" }
-- names.titlecase("JEAN-PIERRE SERRE")                --> "Jean-Pierre Serre"
-- names.clean("Prof. Dr.")                           --> nil
local expr = require "expr"
local M = {}

local function set(words)
  local t = {}
  for w in words:gmatch("%S+") do t[w] = true end
  return t
end

local PARTICLE = set("van von de der den du di del della la le dos da y bin al")
-- institution, place and section words that turn up next to real authors
local NOT_NAME = set([[university universität college institute institut cwi anu mit
  amsterdam press appendix section resource resources systems system language modeling
  modeler department faculty laboratory notices bookmatter sums over school academy
  society center centre company editorial board series handbook chapter volume algebra
  complexes simplicial semi-simplicial address presidential retiring york guide sound
  pattern factors geometry introduction cov cover design homology singular remarks
  abstract contents theorem lemma proof dedicated capital inc ltd labs research
  corporation google microsoft journal received revised communicated]])
-- ranks, roles and kinds of document: words that sit where an author's name
-- would but are never one ("Professor Emeritus", "Lecture Notes")
-- (not words that are also surnames or first names: Dean, Reader, Fellow, Chair)
local ROLE = set([[emeritus emerita lecturer editor editors edited translator translated
  foreword preface thesis dissertation notes lecture lectures report preprint draft version
  reprint reprints archive blog talks seminar colloquium workshop conference proceedings
  memorial anniversary honors honours visiting assistant associate adjunct distinguished
  invited keynote supervisor advisor adviser examiner committee unknown edition editions]])
-- given names common among the authors of books and papers: enough to tell
-- "David Mumford" from "Hopf Algebras" where nothing else on the page does
local GIVEN = set([[aaron adam adrian alan albert alex alexander alexandre alfred alice allen amy anatoly andre
  andrea andreas andrei andrew andrzej angela anna anne anthony antoine anton antonio arthur barbara barry ben
  benjamin bernard bernhard bertrand bill boris brian bruce bruno carl carlos carol caroline catherine charles
  chris christian christine christoph christopher claire claude claudia colin craig dan daniel daniela david
  dennis diana dmitri dmitry donald douglas edward elena elias elizabeth emil emily emmanuel emmy eric erik ernst
  eugene eva evan felix frances francis francois frank fred frederick friedrich gabriel gary george georges
  gerald gerard gerd gilles giovanni gordon graham greg gregory guido gunter gustav hans harold harry heinrich
  helen helmut henri henry herbert hermann howard hugo ian igor ilya irene isaac ivan jack jacob jacques james
  jan jane jason jean jeffrey jennifer jeremy jerome jesse jim joachim joan joe joel johan johann johannes john
  jon jonathan jorge jose josef joseph joshua juan judith julia julian julie julius jurgen karen karl kate
  katherine keith ken kenneth kevin klaus kurt lars laura laurent lawrence lee leo leon leonard leonhard linda
  lisa louis luca lucas ludwig luis marc marcel marco marcus margaret maria marie mario mark martin mary
  matthew matthias maurice max maxim michael michel michele miguel mikhail mike nancy nathan neil nicholas
  nicolas nikolai nina noam norman oleg oliver olivier oscar otto pablo pascal patricia patrick paul pavel
  pedro peter philip philipp philippe pierre rachel ralph raymond rebecca reinhard rene richard robert roberto
  robin roger roland ronald ruth ryan sam samuel sandra sarah scott sean sebastian serge sergei sergey sergio
  simon sophie stefan stephen steve steven stuart susan sylvain terence terry theodore thomas tim timothy tobias
  tom tony ulrich valentin vera victor vincent vladimir walter werner wilhelm william wolfgang yuri yves]])
-- what stands before or after a name and is taken off it: "Professor Karen E. Smith"
local DEGREE = set("ph.d phd dr prof professor mr ms mrs frs sir")
-- function words: a line containing one is prose or a title, not a name list
local TITLE_WORDS = set([[of in the for to on with from into over under via an that which
  using toward towards between about as at by its their]])
local MARKS = { "∗", "†", "‡", "§", "¶", "%*", "#" }

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function is_affiliation(low)
  return low:find("universit") or low:find("department") or low:find("school of")
    or low:find("institut") or low:find("e%-?mail") or low:find("@") or low:find("laborator")
    or low:find("acknowledg")
end
--- Returns true if the text names an institution or an e-mail address, not a person.
M.is_affiliation = function(s) return is_affiliation(s:lower()) ~= nil end

-- the user's own additions, from the option never_authors; read when it changes
local never_text, never_list
local function never()
  local text = setman.get("never_authors") or ""
  if text ~= never_text then
    local list = {} -- built whole, then put in place (a task may be interrupted)
    for item in text:gmatch("[^,]+") do
      local phrase = expr.fold(trim(item)):gsub("%s+", " ")
      if phrase ~= "" then list[#list + 1] = " " .. phrase .. " " end
    end
    never_list, never_text = list, text
  end
  return never_list
end

--- Returns true if a name is never an author: a built-in rank or role, or
-- a word or phrase from the option `never_authors`.
-- @tparam string name
-- @treturn boolean
function M.never(name)
  local flat = " " .. expr.fold(name or ""):gsub("[^%w]+", " "):gsub("^ ", ""):gsub(" $", "") .. " "
  local words, titles = 0, 0
  for w in flat:gmatch("%S+") do
    if ROLE[w] then return true end
    words = words + 1
    if DEGREE[w] then titles = titles + 1 end
  end
  if words > 0 and words - titles < 2 then return true end -- a title with at most one word to it: "Professor", "Dr Smith"
  for _, phrase in ipairs(never()) do
    if flat:find(phrase, 1, true) then return true end
  end
  return false
end

--- Returns one person's name, cleaned, or nil if the text is not a name. A
-- name is two to four capitalised words or initials, with no digits.
-- Particles such as "van" or "de" are allowed.
-- @tparam string p
-- @treturn string|nil
function M.clean(p)
  for _, m in ipairs(MARKS) do p = p:gsub(m, "") end
  local toks = {}
  for t in p:gmatch("%S+") do
    local bare = t:lower():gsub("[.,]+$", "")
    if not DEGREE[bare] then toks[#toks + 1] = t end
  end
  p = table.concat(toks, " ")
  p = p:gsub("(%a)%d+%f[%W]", "%1") -- footnote digits: Kane1 -> Kane
  p = p:gsub("%s+", " "):gsub("^[ .,]+", ""):gsub("[ ,]+$", "")
  if p == "" or p:find("[%[%]%(%)=~/\\|<>@]") or p:find("%d") then return nil end
  toks = {}
  for t in p:gmatch("%S+") do toks[#toks + 1] = t end
  if #toks < 2 or #toks > 4 then return nil end
  if M.never(p) then return nil end
  local solid = false
  for _, t in ipairs(toks) do
    local low = t:lower():gsub("%.$", "")
    if not PARTICLE[low] then
      if NOT_NAME[low] then return nil end
      -- a capital (or the lead byte of an accented, Greek or Cyrillic letter, but
      -- not of punctuation such as a curly quote), then letters, ' . -
      if not t:find("^[%u\195-\214][%a'%.%-\128-\255]*$") then return nil end
      if #t:gsub("[%.'%-]", "") >= 2 then solid = true end
    end
  end
  return solid and p or nil
end

--- Returns true if a line is one person's name, on more evidence than its
-- shape. Two capitalised words are as often a title ("Hopf Algebras") as a
-- name, so one of these must also hold: an initial among the words ("Sidney
-- A. Morris"), a first word that is a common given name, or an e-mail
-- address on the page that spells the surname.
-- @tparam string line
-- @tparam[opt] string text the page
-- @treturn boolean
function M.is_person(line, text)
  local name = M.clean(line)
  if not name or name:find("[,;&]") then return false end
  local toks = {}
  for t in name:gmatch("%S+") do toks[#toks + 1] = t end
  for i = 1, #toks - 1 do
    if toks[i]:match("^%u%.$") then return true end
  end
  if GIVEN[expr.fold(toks[1])] then return true end
  local surname = expr.fold(toks[#toks])
  if #surname >= 4 then
    for address in (text or ""):gmatch("[%w._%-]+@[%w.%-]+") do
      if expr.fold(address:match("^[^@]+")):find(surname, 1, true) then return true end
    end
  end
  return false
end

--- Splits a list of authors such as "A. Author; B. Author and C. Author"
-- into names. Commas separate people only if every piece has more than one
-- word, so "Knuth, Donald" stays whole.
-- @tparam string s
-- @treturn {string,...}
function M.split(s)
  local out = {}
  s = s:gsub("%f[%a][Aa][Nn][Dd]%f[%A]", ";"):gsub("%s*&%s*", ";"):gsub("%s*·%s*", ";")
  for raw in s:gmatch("[^;]+") do -- (loop variables are read-only in Lua 5.5)
    local piece = trim(raw)
    local sub, all_full = {}, true
    for rawq in piece:gmatch("[^,]+") do
      local q = trim(rawq)
      if q ~= "" then
        sub[#sub + 1] = q
        if not q:find("%S%s+%S") then all_full = false end
      end
    end
    if #sub > 1 and all_full then
      for _, q in ipairs(sub) do out[#out + 1] = q end
    elseif piece ~= "" then
      out[#out + 1] = piece
    end
  end
  return out
end

--- Returns true if a line is a list of authors, not prose.
-- @tparam string line
-- @treturn boolean
function M.looks_like_authors(line)
  local low = line:lower()
  if is_affiliation(low) then return false end
  local words = 0
  for w in low:gmatch("[%a\128-\255]+") do
    words = words + 1
    if TITLE_WORDS[w] then return false end
  end
  if words == 0 then return false end
  if line:find("%f[%a]AND%f[%A]") and line:find("%u%.") then return true end -- "N. K. MEHER AND S. S. ROUT"
  local s = line:gsub("[%d.,;()]", " ")
  for _, m in ipairs(MARKS) do s = s:gsub(m, " ") end
  return #line < 100 and s:find("[%u\128-\255][%w%-\128-\255]*%s+[%u\128-\255][%w%-\128-\255]+") ~= nil
end

--- Returns the names on the author lines of a title page, in order and
-- without repeats. On these lines every comma separates people ("A. ONE, B.
-- TWO, JR., AND C. THREE"). `clean` drops the pieces that are not names.
-- @tparam {string,...} lines
-- @treturn {string,...}
function M.validate(lines)
  local out, seen = {}, {}
  for _, line in ipairs(lines) do
    local flat = line:gsub("%f[%a][Aa][Nn][Dd]%f[%A]", ","):gsub("[;&]", ","):gsub("·", ",")
    for part in flat:gmatch("[^,]+") do
      local name = M.clean(part)
      if name and not seen[name:lower()] then
        seen[name:lower()] = true
        out[#out + 1] = name
        if #out == 8 then return out end
      end
    end
  end
  return out
end

-- Lower-case ASCII, Latin-1 and Latin Extended-A capitals (É, Ő, Š, Ł ...);
-- string.lower only knows ASCII.
local function lower_latin(s)
  s = s:lower():gsub("\195([\128-\158])", function(c)
    return c == "\151" and "\195\151" or "\195" .. string.char(c:byte() + 32)
  end)
  return (s:gsub("[\196\197][\128-\191]", function(ch)
    local cp = utf8.codepoint(ch)
    local even_upper = (cp >= 0x100 and cp <= 0x137) or (cp >= 0x14A and cp <= 0x177)
    local odd_upper = (cp >= 0x139 and cp <= 0x148) or (cp >= 0x179 and cp <= 0x17E)
    if (even_upper and cp % 2 == 0) or (odd_upper and cp % 2 == 1) then return utf8.char(cp + 1) end
    return ch
  end))
end

--- Converts a name in capitals to normal case: "JEAN-PIERRE SERRE" becomes
-- "Jean-Pierre Serre". Text that is not all capitals is returned unchanged.
-- @tparam string s
-- @treturn string
function M.titlecase(s)
  if not s or s:find("%l") or not s:find("%u") then return s end
  return (s:gsub("[^%s%-']+", function(w)
    local first, rest = w:match("^([%z\1-\127\194-\244][\128-\191]*)(.*)$")
    return first and first .. lower_latin(rest) or w
  end))
end

local SMALL = set("a an the of in on and for to with by at from via or nor as de la du des")

--- Converts an ALL CAPS title to title case. Short words stay lower case
-- except at the start. Mixed-case text is returned unchanged.
-- @tparam string s
-- @treturn string
function M.title_caps(s)
  local t = M.titlecase(s)
  if t == s then return s end
  local first = true
  return (t:gsub("%S+", function(w)
    local keep = first or not SMALL[w:lower()]
    first = false
    return keep and w or w:lower()
  end))
end

return M
