-- People's names: telling a name from an institution or a stray title word,
-- splitting lists of authors, fixing ALL CAPS.
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
local DEGREE = set("ph.d phd dr prof mr ms mrs")
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
M.is_affiliation = function(s) return is_affiliation(s:lower()) ~= nil end

--- One person's name, cleaned, or nil if this does not read as a name:
-- two to four capitalised words or initials, particles allowed, no digits.
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

--- Split "A. Author; B. Author and C. Author" into names. Commas separate
-- people only when every piece is itself more than one word, so
-- "Knuth, Donald" stays whole.
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

--- Does this line read as a list of authors rather than prose?
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

--- Validated names from the author lines of a title page, in order, without
-- repeats. Here every comma separates people ("A. ONE, B. TWO, JR., AND C.
-- THREE"); pieces that are not names are dropped by M.clean.
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

--- "JEAN-PIERRE SERRE" -> "Jean-Pierre Serre". Text that is not all capitals
-- is returned unchanged.
function M.titlecase(s)
  if not s or s:find("%l") or not s:find("%u") then return s end
  return (s:gsub("[^%s%-']+", function(w)
    local first, rest = w:match("^([%z\1-\127\194-\244][\128-\191]*)(.*)$")
    return first and first .. lower_latin(rest) or w
  end))
end

local SMALL = set("a an the of in on and for to with by at from via or nor as de la du des")

--- Title-style capitals for an ALL CAPS title: small words stay lower case
-- except at the start. Mixed-case text is returned unchanged.
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
