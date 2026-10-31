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
    for _, kind in ipairs((not s.how.available or s.how.available()) and kinds or {}) do
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
          out[#out + 1] = { service = k.service, key = k.key, ident = k.ident, fields = fields, pages = pages,
                            identifies = service.services[k.service].how.identifies }
        end
      end
    end
  end
  return out
end

--- The records kept for an identifier, whichever service gave them: `{ {service=,
-- fields=, pages=}, ... }`. Asks nobody.
-- @tparam string kind "doi", "isbn", "arxiv"
-- @tparam string value canonical
function M.kept_for(kind, value)
  local out = {}
  for name, s in pairs(service.services) do
    local kinds = type(s.how.ident) == "table" and s.how.ident or { s.how.ident }
    for _, one in ipairs(kinds) do
      local answer = one == kind and not s.how.identifies and service.kept(name, value)
      if answer then
        local ok, fields = pcall(s.how.record, answer, value)
        if ok and fields then
          local pages = fields.pages
          fields.pages = nil
          out[#out + 1] = { service = name, fields = fields, pages = pages }
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
  return select(2, M.enrich_many({ book }, o))
end

--- Asks about many books at once, so that a service takes as few requests as it
-- can, and a dataset on this machine (a service with `covers`) is read once. What
-- a dataset has, the service it covers isn't asked. Every service goes at its own
-- pace; waits for all. Posts "source_arrived" for each new answer.
-- @tparam {integer,...} ids
-- @tparam[opt] table o `{ titles=, offline=, services= }`: offline, only what's on
-- this machine; services, only these, as a set of names
-- @treturn integer how many books had a new answer
-- @treturn integer how many new answers
function M.enrich_many(ids, o)
  o = o or {}
  local wanted, of = {}, {} -- per service, its keys, and per key the books
  for _, book in ipairs(ids) do
    for _, k in ipairs(M.keys(book, nil, o)) do
      if not o.services or o.services[k.service] then
        wanted[k.service] = wanted[k.service] or {}
        table.insert(wanted[k.service], k.key)
        of[k.service] = of[k.service] or {}
        of[k.service][k.key] = of[k.service][k.key] or {}
        table.insert(of[k.service][k.key], book)
      end
    end
  end
  local books, answers = {}, 0
  local function arrived(name)
    return function(key, answer)
      if answer then
        answers = answers + 1
        for _, book in ipairs(of[name][key] or {}) do
          books[book] = true
          evman.post("source_arrived", { book = book, service = name })
        end
      end
    end
  end
  -- what's on this machine first: what it has needs no asking
  local covered = {}
  for name, keys in pairs(wanted) do
    local how = service.services[name].how
    if how.covers then
      service.ask_all(name, keys, arrived(name))
      for _, key in ipairs(keys) do
        if service.kept(name, key) then
          covered[how.covers] = covered[how.covers] or {}
          covered[how.covers][key] = true
        end
      end
    end
  end
  if not o.offline then
    local running = 0
    local me = taskman.self()
    for name, keys in pairs(wanted) do
      if not service.services[name].how.covers then
        local left = {}
        for _, key in ipairs(keys) do
          if not (covered[name] and covered[name][key]) then left[#left + 1] = key end
        end
        running = running + 1
        taskman.spawn(function()
          service.ask_all(name, left, arrived(name))
          running = running - 1
          taskman.wake(me)
        end)
      end
    end
    while running > 0 do taskman.sleep() end
  end
  local n = 0
  for _ in pairs(books) do n = n + 1 end
  return n, answers
end

require "net.services"
require "net.datasets"

return M
