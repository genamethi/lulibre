--- Online lookups (design 39-43). Each service is a resource with a queue
-- (net.service): a caller asks about one work and waits; the
-- service batches, paces and holds back by its own rules. Every answer is
-- kept. Lookups run only on command (:enrich); contact_email is sent only
-- when set. An answer arriving posts "source_arrived" for the book.
--
-- @library net
local bookman = require "bookman"
local service = require "net.service"
local mesr = require "mesr"
local curl = require "curl"
local ids = require "lulib._ids"

local M = {}

M.services = service.services

--- The User-Agent requests send; the contact address only when set.
-- @tparam string mail the setting contact_email, taken by the caller
function M.agent(mail)
  return ("lulibre/%s (library metadata lookup%s)"):format(lulib.version, mail ~= "" and "; mailto:" .. mail or "")
end

--- Fetches a URL: the body, the HTTP status and Retry-After, or nil and
-- why.
function M.get(url, mail)
  local r, err = curl.req(url, { headers = { ["User-Agent"] = M.agent(mail or "") }, timeout = 25000 })
  if not r then return nil, err end
  return r.body, r.status, r.headers["retry-after"]
end

--- Asks a service about a work; see net.service.ask.
function M.ask(name, key)
  return service.ask(name, key)
end

-- the book's title, if it is one to look for: long enough to tell one work from
-- another, and not a file's name
local function searchable(book)
  local title = bookman.get(book, "title") or ""
  local junk = require "lulib._junk"
  return #title >= 20 and not junk.title(title) and not junk.unlikely_title(title) and title or nil
end

--- The services that can be asked about a book, with the key each is
-- asked by: `{ {service=, key=, ident=}, ... }`. A key is an identifier the
-- record has, or one that is the book's file's own (lulib._ids). A service
-- whose ident is "title" is asked by the book's title, only if `o.titles`, and
-- only for a book with no identifier to ask by.
-- @tparam integer book
-- @tparam[opt] {table,...} found the file's identifiers, when the caller
-- has them
-- @tparam[opt] table o `{ titles = true }`
function M.keys(book, found, o)
  local out, b = {}, bookman.get(book)
  if not b then return out end
  local idents, any = {}, false
  for kind, value in pairs(b.idents or {}) do idents[kind] = { value } end
  for _, f in ipairs(found or ids.book(book)) do
    if f.own then
      idents[f.kind] = idents[f.kind] or {}
      table.insert(idents[f.kind], f.value)
    end
  end
  for name, s in pairs(service.services) do
    local kinds = type(s.how.ident) == "table" and s.how.ident or { s.how.ident }
    local seen = {}
    for _, kind in ipairs(kinds) do
      for _, value in ipairs(idents[kind] or {}) do
        local key = mesr.canonical(kind, value)
        if key and not seen[key] then
          seen[key] = true
          any = true
          out[#out + 1] = { service = name, key = key, ident = kind }
        end
      end
    end
  end
  local title = not any and o and o.titles and searchable(book)
  if title then
    local key = require("expr").fold(title)
    for name, s in pairs(service.services) do
      if s.how.ident == "title" then out[#out + 1] = { service = name, key = key, ident = "title" } end
    end
  end
  table.sort(out, function(a, z) return a.service < z.service or (a.service == z.service and a.key < z.key) end)
  return out
end

--- The online records kept for a book: `{ {service=, key=, ident=, fields=,
-- pages=}, ... }`; pages, the record's page count, when it has one.
-- @tparam integer book
-- @tparam[opt] {table,...} found the file's identifiers, when the caller
-- has them
function M.records(book, found)
  local out = {}
  for _, k in ipairs(M.keys(book, found, { titles = true })) do
    local answer = service.kept(k.service, k.key)
    if answer then
      local ok, fields = pcall(service.services[k.service].how.record, answer, k.key)
      if ok and fields then
        local pages = fields.pages
        fields.pages = nil
        if next(fields) then
          out[#out + 1] = { service = k.service, key = k.key, ident = k.ident, fields = fields, pages = pages }
        end
      end
    end
  end
  return out
end

--- Asks every service a book can be asked about; posts "source_arrived"
-- for each new answer. Returns how many services answered anew.
-- @tparam integer book
-- @tparam[opt] table o `{ titles = true }`: by its title too, if it has no identifier
function M.enrich(book, o)
  local n = 0
  for _, k in ipairs(M.keys(book, nil, o)) do
    local answer, fresh = M.ask(k.service, k.key)
    if answer and fresh then
      n = n + 1
      evman.post("source_arrived", { book = book, service = k.service })
    end
  end
  return n
end

require "net.services"

return M
