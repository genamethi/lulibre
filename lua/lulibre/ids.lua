-- Identifiers found in page text: DOI, ISBN, arXiv id, MSC area.
local M = {}

function M.doi(text)
  local d = text:match("10%.%d%d%d%d+/[^%s,;\"'%)%]>]+")
  return d and (d:gsub("%.+$", "")) or nil
end

local function isbn13_ok(d)
  local sum = 0
  for i = 1, 13 do sum = sum + (d:byte(i) - 48) * (i % 2 == 0 and 3 or 1) end
  return sum % 10 == 0
end

local function isbn10_ok(d)
  local sum = 0
  for i = 1, 10 do
    local c = d:sub(i, i)
    local n = (c == "X" or c == "x") and 10 or tonumber(c)
    if not n or (n == 10 and i < 10) then return false end
    sum = sum + n * (11 - i)
  end
  return sum % 11 == 0
end

--- An ISBN of ten figures as one of thirteen ("0387900403" is
-- "9780387900407"), or nil if it is not one.
function M.isbn13(isbn)
  local d = tostring(isbn):gsub("[^%dXx]", ""):upper()
  if #d == 13 then return isbn13_ok(d) and d or nil end
  if #d ~= 10 or not isbn10_ok(d) then return nil end
  local body, sum = "978" .. d:sub(1, 9), 0
  for i = 1, 12 do sum = sum + (body:byte(i) - 48) * (i % 2 == 0 and 3 or 1) end
  return body .. tostring((10 - sum % 10) % 10)
end

--- An ISBN of thirteen figures as one of ten, where there is one (those
-- that begin 978), or nil.
function M.isbn10(isbn)
  local d = tostring(isbn):gsub("[^%dXx]", ""):upper()
  if #d == 10 then return isbn10_ok(d) and d or nil end
  if #d ~= 13 or d:sub(1, 3) ~= "978" or not isbn13_ok(d) then return nil end
  local body, sum = d:sub(4, 12), 0
  for i = 1, 9 do sum = sum + (body:byte(i) - 48) * (11 - i) end
  local check = (11 - sum % 11) % 11
  return body .. (check == 10 and "X" or tostring(check))
end

--- The first ISBN whose check digit is right. The Python version accepted
-- any 13 digits starting 97, which let page ranges and phone numbers through.
function M.isbn(text)
  for cand in text:gmatch("97[89][%d%- ]+") do
    local d = cand:gsub("%D", "")
    if #d >= 13 and isbn13_ok(d:sub(1, 13)) then return d:sub(1, 13) end
  end
  for _, pat in ipairs({ "ISBN[%- ]*10[: ]+([%dXx][%dXx%- ]+)", "ISBN[: ]*([%dXx][%dXx%- ]+)" }) do
    for cand in text:gmatch(pat) do
      local d = cand:gsub("[^%dXx]", "")
      if #d >= 10 and isbn10_ok(d:sub(1, 10)) then return d:sub(1, 10):upper() end
    end
  end
  return nil
end

--- The margin stamp "arXiv:1012.6008v1 [math.CO] 29 Dec 2010": id and class.
function M.arxiv_stamp(text)
  local id, class = text:match("arXiv:%s*(%S-)%s*%[([%w%.%-]+)%]")
  if not id then return nil end
  return (id:gsub("v%d+$", "")), class
end

--- An arXiv id from page text, else from a file name that is nothing but one.
function M.arxiv(text, filename)
  local id, class = M.arxiv_stamp(text)
  if id then return id, class end
  id = text:match("arXiv:%s*(%d%d%d%d%.%d%d%d%d%d?)") or text:match("arXiv:%s*([%a%-]+/%d%d%d%d%d%d%d)")
  if id then return id end
  if filename then
    local stem = filename:gsub("^.*/", ""):gsub("%.%w+$", "")
    return stem:match("^(%d%d%d%d%.%d%d%d%d%d?)v?%d*$")
  end
  return nil
end

--- Year an arXiv id was assigned: 1012.6008 -> 2010, math/0601054 -> 2006.
function M.arxiv_year(id)
  local yy = id:match("^(%d%d)%d%d%.") or id:match("/(%d%d)%d%d%d%d%d$")
  if not yy then return nil end
  yy = tonumber(yy)
  return yy >= 91 and 1900 + yy or 2000 + yy
end

--- Two-digit MSC area from a "Mathematics Subject Classification" footnote.
function M.msc(text)
  local i = text:find("[Ss]ubject%s+[Cc]lassif") or text:find("MSC%s*%d*%s*[:%(]")
  if not i then return nil end
  return text:sub(i, i + 160):match("(%d%d)%u%d%d")
end

return M
