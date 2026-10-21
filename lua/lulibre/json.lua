--- Encodes and decodes JSON. The codec is small: enough for metadata
-- services and for reading the .jsonl files the old Python scripts wrote.
--
-- @services lulibre.json
-- @usage
-- local json = require "lulibre.json"
-- json.decode('{"a": [1, 2]}').a[2]  --> 2
-- json.encode({ a = { 1, 2 } })        --> '{"a":[1,2]}'
local M = {}

local escapes = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

local function utf8_char(cp)
  return utf8.char(cp)
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
    local c = s:sub(k + 1, k + 1)
    if c == "u" then
      local cp = tonumber(s:sub(k + 2, k + 5), 16)
      j = k + 6
      if cp and cp >= 0xD800 and cp <= 0xDBFF and s:sub(j, j + 1) == "\\u" then
        local lo = tonumber(s:sub(j + 2, j + 5), 16)
        if lo then
          cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
          j = j + 6
        end
      end
      out[#out + 1] = utf8_char(cp or 0xFFFD)
    else
      out[#out + 1] = escapes[c] or c
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
      local k
      k, i = decode_string(s, skip(s, i))
      i = skip(s, i)
      if s:sub(i, i) ~= ":" then error("expected ':' at " .. i) end
      t[k], i = decode_value(s, i + 1)
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
  local num = s:match("^-?%d+%.?%d*[eE]?[+-]?%d*", i)
  if not num or num == "" then error("unexpected character at " .. i) end
  return tonumber(num), i + #num
end

--- Decodes one JSON value. null becomes nil.
-- @tparam string s
-- @return the value
function M.decode(s)
  local v = decode_value(s, 1)
  return v
end

local function encode(v, out)
  local t = type(v)
  if t == "table" then
    if #v > 0 or next(v) == nil then
      out[#out + 1] = "["
      for i = 1, #v do
        if i > 1 then out[#out + 1] = "," end
        encode(v[i], out)
      end
      out[#out + 1] = "]"
    else
      out[#out + 1] = "{"
      local keys = {}
      for k in pairs(v) do keys[#keys + 1] = tostring(k) end
      table.sort(keys)
      for i, k in ipairs(keys) do
        if i > 1 then out[#out + 1] = "," end
        encode(k, out)
        out[#out + 1] = ":"
        encode(v[k], out)
      end
      out[#out + 1] = "}"
    end
  elseif t == "string" then
    out[#out + 1] = '"' .. v:gsub('[%c"\\]', function(c)
      if c == '"' then return '\\"' elseif c == "\\" then return "\\\\" elseif c == "\n" then return "\\n" end
      return string.format("\\u%04x", c:byte())
    end) .. '"'
  elseif t == "number" or t == "boolean" then
    out[#out + 1] = tostring(v)
  else
    out[#out + 1] = "null"
  end
end

--- Encodes a value as JSON.
-- @param v
-- @treturn string
function M.encode(v)
  local out = {}
  encode(v, out)
  return table.concat(out)
end

return M
