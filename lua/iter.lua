--- Sequences: a list, a table's pairs or an iterator function, taken one
-- item at a time through a chain of operations, as Neovim's vim.iter. An
-- item is one value, or several (a table's key and value); each function
-- given gets them all.
--
--     local iter = require "iter"
--     iter(books):filter(function(b) return b.year end):map(function(b) return b.title end):totable()
--     for size, files in iter(files):group(function(f) return f.size end) do ... end
--     iter(on_disk):diff(on_record, function(f) return f.path end):each(print)
--
-- @library iter
local M = {}

local Iter = {}
Iter.__index = Iter
--- An Iter is a `for` loop's iterator: `for k, v in iter(t) do`.
Iter.__call = function(self) return self.step() end

local pack, unpack = table.pack, table.unpack

local function is_list(t)
  return t[1] ~= nil or next(t) == nil
end

-- an Iter over step(), which returns the item's values or nothing at its end
local function over(step)
  return setmetatable({ step = step }, Iter)
end

--- The next item, or nothing at the end.
function Iter:next()
  return self.step()
end

--- An Iter over src: a list (its values), a table (its keys and values),
-- or an iterator function with its state and control value, as `for` takes.
local function new(src, s, ctrl)
  if getmetatable(src) == Iter then return src end
  if type(src) == "function" then
    return over(function()
      local v = pack(src(s, ctrl))
      if v[1] == nil then return end
      ctrl = v[1]
      return unpack(v, 1, v.n)
    end)
  end
  assert(type(src) == "table", "iter: a table or a function")
  if is_list(src) then
    local i = 0
    return over(function()
      i = i + 1
      if src[i] ~= nil then return src[i] end
    end)
  end
  local k
  return over(function()
    local v
    k, v = next(src, k)
    if k ~= nil then return k, v end
  end)
end

-- the item, packed; nil at the end
local function take(it)
  local v = pack(it.step())
  if v.n == 0 or v[1] == nil then return nil end
  return v
end

--- The items for which f is true.
function Iter:filter(f)
  return over(function()
    while true do
      local v = take(self)
      if not v then return end
      if f(unpack(v, 1, v.n)) then return unpack(v, 1, v.n) end
    end
  end)
end

--- What f makes of each item; an item it makes nil of is dropped.
function Iter:map(f)
  return over(function()
    while true do
      local v = take(self)
      if not v then return end
      local r = pack(f(unpack(v, 1, v.n)))
      if r[1] ~= nil then return unpack(r, 1, r.n) end
    end
  end)
end

--- Calls f with each item.
function Iter:each(f)
  for v in function() return take(self) end do f(unpack(v, 1, v.n)) end
end

--- acc, then f(acc, item...) for each item in turn.
function Iter:fold(acc, f)
  for v in function() return take(self) end do acc = f(acc, unpack(v, 1, v.n)) end
  return acc
end

--- The items in a list; an item of several values as a list of them.
function Iter:totable()
  local out = {}
  for v in function() return take(self) end do
    out[#out + 1] = v.n == 1 and v[1] or { unpack(v, 1, v.n) }
  end
  return out
end

--- The first item for which f is true.
function Iter:find(f)
  for v in function() return take(self) end do
    if f(unpack(v, 1, v.n)) then return unpack(v, 1, v.n) end
  end
end

--- Whether f is true of any item; of every item.
function Iter:any(f)
  return self:find(f) ~= nil
end

function Iter:all(f)
  return self:find(function(...) return not f(...) end) == nil
end

--- The first n items; all but the first n.
function Iter:take(n)
  local i = 0
  return over(function()
    i = i + 1
    if i <= n then return self.step() end
  end)
end

function Iter:skip(n)
  for _ = 1, n do
    if not take(self) then break end
  end
  return self
end

--- Each item with its place in the sequence before it, from 1.
function Iter:enumerate()
  local i = 0
  return over(function()
    local v = take(self)
    if not v then return end
    i = i + 1
    return i, unpack(v, 1, v.n)
  end)
end

--- The items joined into a string with sep between them.
function Iter:join(sep)
  return table.concat(self:map(tostring):totable(), sep)
end

--- The items by key(item...): an Iter of key and the list of its items
-- (an item of several values as a list of them), the keys in the order
-- first met. An item whose key is nil is left out.
function Iter:group(key)
  local order, groups = {}, {}
  for v in function() return take(self) end do
    local k = key(unpack(v, 1, v.n))
    if k ~= nil then
      if not groups[k] then
        groups[k] = {}
        order[#order + 1] = k
      end
      local g = groups[k]
      g[#g + 1] = v.n == 1 and v[1] or { unpack(v, 1, v.n) }
    end
  end
  local i = 0
  return over(function()
    i = i + 1
    local k = order[i]
    if k ~= nil then return k, groups[k] end
  end)
end

--- The items whose key(item...) is the key of no item of other (a list,
-- a table or an Iter, taken whole first). key defaults to the first value.
function Iter:diff(other, key)
  key = key or function(v) return v end
  local there = {}
  new(other):each(function(...)
    local k = key(...)
    if k ~= nil then there[k] = true end
  end)
  return self:filter(function(...) return not there[key(...)] end)
end

return setmetatable(M, { __call = function(_, ...) return new(...) end })
