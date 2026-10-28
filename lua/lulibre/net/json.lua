--- A JSON decoder, for the services' answers: objects become tables,
-- arrays sequences, null nil.
--
-- @submodule lulibre.net
local M = {}

local escapes = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

local function utf8_of(code)
  return utf8.char(code)
end

local decode_value

local function skip(s, i)
  return s:find("[^ \t\r\n]", i) or #s + 1
end

local function decode_string(s, i)
  local out, j = {}, i + 1
  while true do
    local k = s:find('["\\]', j)
    if not k then error("unterminated string at " .. i) end
    out[#out + 1] = s:sub(j, k - 1)
    if s:sub(k, k) == '"' then return table.concat(out), k + 1 end
    local e = s:sub(k + 1, k + 1)
    if e == "u" then
      local code = tonumber(s:sub(k + 2, k + 5), 16)
      if not code then error("bad \\u escape at " .. k) end
      j = k + 6
      if code >= 0xD800 and code <= 0xDBFF and s:sub(j, j + 1) == "\\u" then
        local low = tonumber(s:sub(j + 2, j + 5), 16)
        if low and low >= 0xDC00 and low <= 0xDFFF then
          code = 0x10000 + (code - 0xD800) * 0x400 + (low - 0xDC00)
          j = j + 6
        end
      end
      out[#out + 1] = utf8_of(code)
    else
      out[#out + 1] = escapes[e] or e
      j = k + 2
    end
  end
end

function decode_value(s, i)
  i = skip(s, i)
  local c = s:sub(i, i)
  if c == "{" then
    local t = {}
    i = skip(s, i + 1)
    if s:sub(i, i) == "}" then return t, i + 1 end
    while true do
      local key
      key, i = decode_string(s, skip(s, i))
      i = skip(s, i)
      if s:sub(i, i) ~= ":" then error("expected ':' at " .. i) end
      t[key], i = decode_value(s, i + 1)
      i = skip(s, i)
      local d = s:sub(i, i)
      if d == "}" then return t, i + 1 end
      if d ~= "," then error("expected ',' or '}' at " .. i) end
      i = i + 1
    end
  elseif c == "[" then
    local t, n = {}, 0
    i = skip(s, i + 1)
    if s:sub(i, i) == "]" then return t, i + 1 end
    while true do
      n = n + 1
      t[n], i = decode_value(s, i)
      i = skip(s, i)
      local d = s:sub(i, i)
      if d == "]" then return t, i + 1 end
      if d ~= "," then error("expected ',' or ']' at " .. i) end
      i = i + 1
    end
  elseif c == '"' then
    return decode_string(s, i)
  elseif s:sub(i, i + 3) == "true" then
    return true, i + 4
  elseif s:sub(i, i + 4) == "false" then
    return false, i + 5
  elseif s:sub(i, i + 3) == "null" then
    return nil, i + 4
  end
  local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
  if not num or num == "" then error("unexpected '" .. c .. "' at " .. i) end
  return tonumber(num), i + #num
end

--- Decodes a JSON text; nil and the reason when it is not JSON.
function M.decode(s)
  local ok, v = pcall(decode_value, s, 1)
  if not ok then return nil, v end
  return v
end

return M
