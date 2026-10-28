--- Patterns over strings and texts (txt), with string's operations.
--
-- find, match, gmatch and gsub take string's arguments and give its
-- results. The subject is a string or a txt (its text, with the line at
-- each position); the pattern is a Lua pattern, or an LPeg pattern made
-- with LPeg's constructors, which expr reaches (`expr.P`, `expr.C`, ...).
-- An LPeg pattern is searched for, as a Lua pattern is: from init, the
-- first position where it matches. `-expr.B(1) * patt` matches only at the
-- subject's start.
--
--     local expr = require "expr"
--     expr.gsub("Erdős, Paul", expr.C(expr.R"AZ") * expr.C(expr.R"az" ^ 1), "%2")
--     local bold = expr.where(function(line) return line.bold end)
--     for title in expr.gmatch(t, bold * expr.C(expr.line)) do ... end
--
-- @library expr
local lpeg = require "lpeg"
local core = require "expr.core"

local P, S, R, B, Cp, Ct, Cmt, Carg, V = lpeg.P, lpeg.S, lpeg.R, lpeg.B, lpeg.Cp, lpeg.Ct, lpeg.Cmt, lpeg.Carg, lpeg.V

local M = setmetatable({}, { __index = lpeg })

--- s without case, accents or styled letters: the key filters compare by.
M.fold = core.fold
--- Case for more than ASCII: Latin with accents, Greek, Cyrillic.
M.lower = core.lower
M.upper = core.upper

-- the string patterns run over, and the txt when there is one
local function subject(s)
  if type(s) == "string" then return s, nil end
  return s.text, s
end

-- p found from a position on: its start, its captures, its end (past it)
local searches = setmetatable({}, { __mode = "k" })
local function search(p)
  local found = searches[p]
  if not found then
    found = P { Cp() * Ct(p) * Cp() + 1 * V(1) }
    searches[p] = found
  end
  return found
end

local function start(init, len)
  init = init or 1
  if init < 0 then init = math.max(len + init + 1, 1) end
  return init
end

-- the captures, or the whole match when there are none
local function results(text, st, caps, stop)
  if caps[1] == nil and next(caps) == nil then return text:sub(st, stop - 1) end
  return table.unpack(caps)
end

--- As string.find.
function M.find(s, patt, init, plain)
  local text, t = subject(s)
  if type(patt) == "string" then return text:find(patt, init, plain) end
  local st, caps, stop = lpeg.match(search(patt), text, start(init, #text), t)
  if not st then return nil end
  if caps[1] == nil and next(caps) == nil then return st, stop - 1 end
  return st, stop - 1, table.unpack(caps)
end

--- As string.match.
function M.match(s, patt, init)
  local text, t = subject(s)
  if type(patt) == "string" then return text:match(patt, init) end
  local st, caps, stop = lpeg.match(search(patt), text, start(init, #text), t)
  if not st then return nil end
  return results(text, st, caps, stop)
end

--- As string.gmatch.
function M.gmatch(s, patt)
  local text, t = subject(s)
  if type(patt) == "string" then return text:gmatch(patt) end
  local found, pos = search(patt), 1
  return function()
    if pos > #text + 1 then return nil end
    local st, caps, stop = lpeg.match(found, text, pos, t)
    if not st then
      pos = #text + 2
      return nil
    end
    pos = stop > st and stop or stop + 1
    return results(text, st, caps, stop)
  end
end

-- what repl makes of one match, as string.gsub's repl does
local function replace(repl, whole, caps)
  local first = caps[1]
  if first == nil then first = whole end
  local r
  if type(repl) == "string" then
    r = repl:gsub("%%(.)", function(d)
      if d == "%" then return "%" end
      local i = tonumber(d)
      if not i then error("invalid use of '%' in replacement string", 4) end
      if i == 0 then return whole end
      local v = caps[i]
      if v == nil and i == 1 then v = whole end
      if v == nil then error("invalid capture index %" .. i .. " in replacement string", 4) end
      return tostring(v)
    end)
    return r
  elseif type(repl) == "table" then
    r = repl[first]
  elseif type(repl) == "function" then
    if caps[1] == nil then r = repl(whole) else r = repl(table.unpack(caps)) end
  else
    error("bad argument #3 to 'gsub' (string/function/table expected, got " .. type(repl) .. ")", 3)
  end
  if r == nil or r == false then return whole end
  if type(r) ~= "string" and type(r) ~= "number" then error("invalid replacement value (a " .. type(r) .. ")", 3) end
  return tostring(r)
end

--- As string.gsub. Over a txt, the result is a string: the attributes stay
-- with the txt.
function M.gsub(s, patt, repl, n)
  local text, t = subject(s)
  if type(patt) == "string" then return text:gsub(patt, repl, n) end
  local found, out, pos, count = search(patt), {}, 1, 0
  while (not n or count < n) and pos <= #text + 1 do
    local st, caps, stop = lpeg.match(found, text, pos, t)
    if not st then break end
    out[#out + 1] = text:sub(pos, st - 1)
    out[#out + 1] = replace(repl, text:sub(st, stop - 1), caps)
    count = count + 1
    if stop > st then
      pos = stop
    else
      out[#out + 1] = text:sub(st, st)
      pos = st + 1
    end
  end
  out[#out + 1] = text:sub(pos)
  return table.concat(out), count
end

--- Matches, consuming nothing, where the line at the position passes
-- test(line, txt). Over a string, which has no lines, it never matches.
function M.where(test)
  return Cmt(Carg(1), function(_, pos, t)
    local line = t and t:at(pos)
    return line ~= nil and test(line, t) and pos or false
  end)
end

--- A line's text: up to its line or page break.
M.line = (1 - S "\n\f") ^ 1
--- The breaks after a line: one, or two before a paragraph.
M.eol = P "\n" ^ 1

local any_line = M.line * M.eol ^ -1

--- Whole lines up to the first where p matches at its start; consumes
-- the lines, not p. Fails at a page break.
function M.upto(p)
  return (any_line - #p) ^ 0 * #p
end

local word_char = R("az", "AZ", "09") + R "\128\255"

--- Any of the words or phrases in the list, as whole words, the longest
-- first.
function M.list(words)
  local sorted = {}
  for i, w in ipairs(words) do sorted[i] = w end
  table.sort(sorted, function(a, b) return #a > #b end)
  local any = P(false)
  for _, w in ipairs(sorted) do any = any + P(w) end
  return -B(word_char) * any * -word_char
end

--- A function applying its steps in order: each a function of the string,
-- or `{ patt, repl }` for gsub.
function M.chain(...)
  local steps = { ... }
  return function(s)
    for _, step in ipairs(steps) do
      if type(step) == "function" then
        s = step(s)
      else
        s = (M.gsub(s, step[1], step[2]))
      end
    end
    return s
  end
end

return M
