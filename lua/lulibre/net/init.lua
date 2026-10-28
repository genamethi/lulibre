--- Online lookups (design 39-43). Each service is a resource with a queue
-- (lulibre.net.service): a caller asks about one work and waits; the
-- service batches, paces and holds back by its own rules. Every answer is
-- kept. Lookups run only on command (:enrich); contact_email is sent only
-- when set. An answer arriving posts "source_arrived" for the book.
--
-- @library lulibre.net
local service = require "lulibre.net.service"
local similar = require "lulibre.similar"
local curl = require "curl"

local M = {}

M.services = service.services

--- The User-Agent requests send; the contact address only when set.
-- @tparam string mail the setting contact_email, taken by the caller
function M.agent(mail)
  return ("lulibre/%s (library metadata lookup%s)"):format(lulibre.version, mail ~= "" and "; mailto:" .. mail or "")
end

--- Fetches a URL: the body, the HTTP status and Retry-After, or nil and
-- why.
function M.get(url, mail)
  local r, err = curl.request(url, { headers = { ["User-Agent"] = M.agent(mail or "") }, timeout = 25000 })
  if not r then return nil, err end
  return r.body, r.status, r.headers["retry-after"]
end

--- Asks a service about a work; see lulibre.net.service.ask.
function M.ask(name, key)
  return service.ask(name, key)
end

--- The services that can be asked about a book, with the key each is
-- asked by: `{ {service=, key=}, ... }`.
function M.keys(book)
  local out, b = {}, lulibre.book(book)
  if not b then return out end
  for name, s in pairs(service.services) do
    local value = b.idents and b.idents[s.how.ident]
    local key = value and similar.canonical(s.how.ident, value)
    if key then out[#out + 1] = { service = name, key = key } end
  end
  table.sort(out, function(a, z) return a.service < z.service end)
  return out
end

--- The online records kept for a book, as fields: `{ {service=, fields=}, ... }`.
function M.records(book)
  local out = {}
  for _, k in ipairs(M.keys(book)) do
    local answer = service.kept(k.service, k.key)
    if answer then
      local ok, fields = pcall(service.services[k.service].how.record, answer)
      if ok and fields and next(fields) then out[#out + 1] = { service = k.service, fields = fields } end
    end
  end
  return out
end

--- Asks every service a book can be asked about; posts "source_arrived"
-- for each new answer. Returns how many services answered anew.
function M.enrich(book)
  local n = 0
  for _, k in ipairs(M.keys(book)) do
    local answer, fresh = M.ask(k.service, k.key)
    if answer and fresh then
      n = n + 1
      evman.post("source_arrived", { book = book, service = k.service })
    end
  end
  return n
end

require "lulibre.net.services"

return M
