-- Metadata services: what arXiv, CrossRef, zbMATH Open, Open Library and
-- OpenAlex say about a work that has an identifier. None of them needs an
-- account or a key.
--
-- Everything that is fetched is kept (the table `lookups`), so a work is
-- asked about once: a later run, or the same question from another book, is
-- answered from what was kept, and with M.offline set nothing is asked at
-- all. Each service is asked no faster than it wishes (M.PACE), whatever
-- else is going on.
--
-- Every function here waits, so call them from a task. Each gives a record
--
--   { title=, authors={...}, year=, date="YYYY-MM-DD", publisher=, series=, series_index=,
--     subjects={ {tag=, confidence=, why=}, ... }, ids={ doi=, isbn=, arxiv=, zbl= }, type=, source= }
--
-- with whatever the service knows, or nil and why not.
--
--   net.arxiv("1012.6008")            net.crossref("10.2307/2118559")
--   net.zbmath { doi = "10.2307/2118559" }     net.zbmath { arxiv = "1012.6008" }
--   net.openlibrary("9780387900407")  net.openalex("10.2307/2118559")
--   net.arxiv_prefetch { "1012.6008", "hep-th/9711200" }    -- many in one request
--   net.offline = true                -- answer from what is kept, or not at all
--
-- The option contact_email, when set, is sent with each request (in the
-- User-Agent, and as CrossRef's and OpenAlex's `mailto`): they give steadier
-- service to callers they can reach. It is empty unless you set it.
local json = require "lulibre.json"
local taxonomy = require "lulibre.taxonomy"

local M = {}

-- seconds between two requests to one service
M.PACE = { arxiv = 3.2, crossref = 0.25, zbmath = 0.5, openlibrary = 1.0, openalex = 0.25 }

M.offline = false
M.stats = { asked = 0, kept = 0 } -- requests made, and answers found already kept

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function unescape(s)
  return (s:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&#39;", "'"):gsub("&amp;", "&"))
end

local function encode(s)
  return (s:gsub("[^%w%-%._~]", function(c) return ("%%%02X"):format(c:byte()) end))
end

--- What requests say they come from.
function M.agent()
  local mail = lulibre.o.contact_email or ""
  return ("lulibre/%s (library metadata lookup%s)"):format(lulibre.version, mail ~= "" and "; mailto:" .. mail or "")
end

--- GET a URL. Returns the body and the HTTP status, or nil and a message
-- when nothing came back at all.
function M.get(url)
  local r, err = lulibre.system({ "curl", "-sS", "-L", "--max-time", "25", "-A", M.agent(), "-w", "\n%{http_code}", url },
    { timeout = 30000 })
  if not r then return nil, err end
  if r.code ~= 0 then return nil, trim(r.stderr) ~= "" and trim(r.stderr) or ("curl exited " .. r.code) end
  local body, status = r.stdout:match("^(.*)\n(%d%d%d)$")
  return body or r.stdout, tonumber(status) or 0
end

local last, busy = {}, {}

-- wait this service's turn: one request at a time, PACE apart
local function turn(service)
  while busy[service] do lulibre.sleep(50) end
  busy[service] = true
  local ok, uv = pcall(require, "luv")
  local now = ok and uv.hrtime() / 1e9 or os.time()
  local wait = (last[service] or 0) + (M.PACE[service] or 0.5) - now
  if wait > 0 then lulibre.sleep(math.ceil(wait * 1000)) end
end

local function done(service)
  local ok, uv = pcall(require, "luv")
  last[service] = ok and uv.hrtime() / 1e9 or os.time()
  busy[service] = nil
end

--- What is kept for a key of a service: the body, or false when the service
-- was asked and had nothing; nil when it has not been asked.
function M.kept(service, key)
  local row = lulibre.sql("SELECT status, body FROM lookups WHERE service = ? AND key = ?", service, key)[1]
  if not row then return nil end
  if row.status == 200 then return row.body end
  return false
end

--- Keep an answer.
function M.keep(service, key, status, body)
  lulibre.store("INSERT OR REPLACE INTO lookups(service, key, at, status, body) VALUES(?, ?, ?, ?, ?)", service, key,
    os.time(), status, status == 200 and body or nil)
end

--- The body a service gives for a key: from what is kept if it has been
-- asked before, else from `url` (and kept). nil and why when there is none.
function M.fetch(service, key, url)
  local kept = M.kept(service, key)
  if kept then
    M.stats.kept = M.stats.kept + 1
    return kept
  elseif kept == false then
    M.stats.kept = M.stats.kept + 1
    return nil, ("%s has no record of %s"):format(service, key)
  end
  if M.offline then return nil, ("%s has not been asked about %s (offline)"):format(service, key) end
  turn(service)
  local ok, body, status = pcall(M.get, url)
  if ok and status == 429 then -- asked too fast: stand back once, then try again
    lulibre.sleep(15000)
    ok, body, status = pcall(M.get, url)
  end
  done(service)
  M.stats.asked = M.stats.asked + 1
  if not ok then return nil, tostring(body) end
  if not body then return nil, status end
  if status == 200 then
    M.keep(service, key, 200, body)
    return body
  elseif status == 404 or status == 400 then
    M.keep(service, key, 404)
    return nil, ("%s has no record of %s"):format(service, key)
  end
  return nil, ("%s answered %d"):format(service, status) -- not kept: it may answer another day
end

-- ---- arXiv ----

local function arxiv_record(entry)
  local title = entry:match("<title[^>]*>(.-)</title>")
  if not title or trim(title) == "Error" then return nil end
  local authors = {}
  for name in entry:gmatch("<name>(.-)</name>") do authors[#authors + 1] = unescape(trim(name)) end
  local class = entry:match('primary_category[^>]-term="([^"]+)"')
  local date = entry:match("<published>(%d%d%d%d%-%d%d%-%d%d)")
  local rec = {
    title = unescape(trim(title):gsub("%s+", " ")), authors = authors, class = class,
    year = tonumber(date and date:sub(1, 4)), date = date, subjects = {}, ids = {}, type = "preprint",
    summary = unescape(trim(entry:match("<summary[^>]*>(.-)</summary>") or ""):gsub("%s+", " ")),
  }
  local doi = entry:match("<arxiv:doi[^>]*>(.-)</arxiv:doi>")
  if doi then rec.ids.doi = trim(doi) end
  local subject = taxonomy.from_arxiv(class)
  if subject then rec.subjects[1] = { tag = subject, confidence = 0.95, why = "arXiv class " .. class } end
  return rec
end

-- "http://arxiv.org/abs/hep-th/9711200v3" -> "hep-th/9711200"
local function arxiv_id(entry)
  local id = entry:match("<id>%s*https?://arxiv%.org/abs/(.-)%s*</id>")
  return id and id:gsub("v%d+$", "")
end

--- arXiv's record for an id ("1012.6008", "hep-th/9711200"; a version is ignored).
function M.arxiv(id)
  id = id:gsub("v%d+$", "")
  local body, err = M.fetch("arxiv", id, "https://export.arxiv.org/api/query?max_results=1&id_list=" .. encode(id))
  if not body then return nil, err end
  local rec = arxiv_record(body:match("<entry>(.-)</entry>") or body)
  if not rec then
    M.keep("arxiv", id, 404)
    return nil, "arXiv has no record of " .. id
  end
  rec.ids.arxiv, rec.source = id, "arXiv " .. id
  return rec
end

--- Ask arXiv about many ids in as few requests as it takes (forty to a
-- request), keeping each answer; M.arxiv then answers from what was kept.
-- Returns how many were newly fetched.
function M.arxiv_prefetch(ids)
  local want = {}
  for _, raw in ipairs(ids) do
    local id = raw:gsub("v%d+$", "")
    if M.kept("arxiv", id) == nil then want[#want + 1] = id end
  end
  if M.offline or #want == 0 then return 0 end
  local got = 0
  for from = 1, #want, 40 do
    local chunk = { table.unpack(want, from, math.min(from + 39, #want)) }
    turn("arxiv")
    local ok, body, status = pcall(M.get, ("https://export.arxiv.org/api/query?max_results=%d&id_list=%s"):format(#chunk,
      encode(table.concat(chunk, ","))))
    done("arxiv")
    M.stats.asked = M.stats.asked + 1
    if ok and body and status == 200 then
      local seen = {}
      for entry in body:gmatch("<entry>(.-)</entry>") do
        local id = arxiv_id(entry)
        if id and arxiv_record(entry) then
          M.keep("arxiv", id, 200, "<entry>" .. entry .. "</entry>")
          seen[id] = true
          got = got + 1
        end
      end
      for _, id in ipairs(chunk) do
        if not seen[id] then M.keep("arxiv", id, 404) end
      end
    end
  end
  return got
end

-- ---- CrossRef ----

local BOOKISH = { book = true, monograph = true, ["edited-book"] = true, ["reference-book"] = true, ["book-chapter"] = true }

local function crossref_record(m)
  local authors = {}
  for _, a in ipairs(m.author or {}) do
    local name = trim((a.given or "") .. " " .. (a.family or a.name or ""))
    if name ~= "" then authors[#authors + 1] = name end
  end
  local issued = m.issued and m.issued["date-parts"] and m.issued["date-parts"][1]
  local year = issued and issued[1]
  local rec = {
    title = m.title and m.title[1] and unescape(m.title[1]:gsub("%s+", " ")) or nil,
    authors = authors, year = year, type = m.type, subjects = {},
    ids = { doi = m.DOI, isbn = m.ISBN and m.ISBN[1] and m.ISBN[1]:gsub("[^%dXx]", "") or nil },
    container = m["container-title"] and m["container-title"][1],
    -- the member that registered a DOI is the publisher of a book, but often an
    -- archive for an article (JSTOR for the Annals): only a book's is offered
    publisher = BOOKISH[m.type or ""] and m.publisher or nil,
    doi = m.DOI, isbn = m.ISBN and m.ISBN[1],
  }
  if issued and issued[2] and issued[3] then rec.date = ("%04d-%02d-%02d"):format(issued[1], issued[2], issued[3]) end
  return rec
end

local function mailto(sep)
  local mail = lulibre.o.contact_email or ""
  return mail ~= "" and sep .. "mailto=" .. encode(mail) or ""
end

--- CrossRef's record for a DOI.
function M.crossref(doi)
  local body, err = M.fetch("crossref", doi:lower(), "https://api.crossref.org/works/" .. encode(doi) .. mailto("?"))
  if not body then return nil, err end
  local ok, data = pcall(json.decode, body)
  if not ok or type(data) ~= "table" or not data.message then return nil, "unreadable reply from CrossRef" end
  local rec = crossref_record(data.message)
  rec.source = "CrossRef " .. doi
  return rec
end

--- Are two titles the same work? Deliberately strict: a wrong match would
-- put someone else's authors on a book.
function M.same_title(a, b)
  local stop = { the = 1, a = 1, an = 1, of = 1, ["in"] = 1, on = 1, ["for"] = 1, ["and"] = 1, to = 1, with = 1,
    by = 1, from = 1, at = 1, is = 1, are = 1 }
  local function words(s)
    local set, n = {}, 0
    for w in lulibre.fold(s):gmatch("[%w]+") do
      if not stop[w] and not set[w] then
        set[w] = true
        n = n + 1
      end
    end
    return set, n
  end
  local wa, na = words(a)
  local wb, nb = words(b)
  if na == 0 or nb == 0 then return false end
  local both = 0
  for w in pairs(wa) do
    if wb[w] then both = both + 1 end
  end
  if na <= 3 or nb <= 3 then return both / math.max(na, nb) > 0.6 end
  return both >= 3 and both / (na + nb - both) > 0.4
end

--- Search CrossRef by title; the record only if its title really matches.
function M.crossref_search(title)
  local body, err = M.fetch("crossref-title", lulibre.fold(title),
    "https://api.crossref.org/works?rows=3&query.bibliographic=" .. encode(title) .. mailto("&"))
  if not body then return nil, err end
  local ok, data = pcall(json.decode, body)
  if not ok or type(data) ~= "table" or not data.message then return nil, "unreadable reply from CrossRef" end
  for _, item in ipairs(data.message.items or {}) do
    local rec = crossref_record(item)
    if rec.title and M.same_title(title, rec.title) then
      rec.source = "CrossRef title search"
      return rec
    end
  end
  return nil, "no confident match"
end

-- ---- zbMATH Open ----

-- "Wiles, Andrew" the right way round
local function forename_first(name)
  local family, given = name:match("^([^,]+),%s*(.+)$")
  return family and (trim(given) .. " " .. trim(family)) or name
end

--- zbMATH Open's record for a work, by { doi = } or { arxiv = }: what gives
-- a mathematics paper or book its subject, since each is classified by hand
-- (the MSC codes), besides its title, authors, year and Zbl number.
function M.zbmath(by)
  local key, param
  if by.doi then key, param = "doi:" .. by.doi:lower(), "DOI=" .. encode(by.doi)
  elseif by.arxiv then key, param = "arxiv:" .. by.arxiv, "arXiv%20ID=" .. encode(by.arxiv)
  else return nil, "zbmath wants a doi or an arxiv id" end
  local body, err = M.fetch("zbmath", key,
    "https://api.zbmath.org/v1/document/_structured_search?page=0&results_per_page=1&" .. param)
  if not body then return nil, err end
  local ok, data = pcall(json.decode, body)
  local doc = ok and type(data) == "table" and type(data.result) == "table" and data.result[1]
  if not doc then
    M.keep("zbmath", key, 404)
    return nil, "zbMATH has no record of " .. key
  end
  local rec = { authors = {}, subjects = {}, ids = {}, year = tonumber(doc.year), source = "zbMATH " .. tostring(doc.identifier or "") }
  if type(doc.title) == "table" and type(doc.title.title) == "string" then
    rec.title = doc.title.title:gsub("%s+", " "):gsub("%s*%.$", "")
  end
  for _, a in ipairs(type(doc.contributors) == "table" and doc.contributors.authors or {}) do
    if type(a.name) == "string" then rec.authors[#rec.authors + 1] = forename_first(a.name) end
  end
  if type(doc.identifier) == "string" then rec.ids.zbl = doc.identifier end
  if type(doc.document_type) == "table" then rec.type = doc.document_type.description end
  -- the first code is the work's main class; its first two figures are the area
  local seen = {}
  for i, m in ipairs(type(doc.msc) == "table" and doc.msc or {}) do
    local area = type(m.code) == "string" and m.code:match("^(%d%d)")
    local tag = area and taxonomy.msc[area]
    if tag and not seen[tag] and tag ~= "math/general" then
      seen[tag] = true
      rec.subjects[#rec.subjects + 1] = { tag = tag, confidence = i == 1 and 0.9 or 0.75, why = "MSC " .. m.code }
    end
  end
  return rec
end

-- ---- Open Library ----

local MONTHS = { january = 1, february = 2, march = 3, april = 4, may = 5, june = 6, july = 7, august = 8, september = 9,
  october = 10, november = 11, december = 12 }

--- Open Library's record for an ISBN: a book's title, authors, publisher and
-- year, the series when the title carries it in brackets, and its subject
-- from the class number libraries shelve it under.
function M.openlibrary(isbn)
  isbn = isbn:gsub("[^%dXx]", ""):upper()
  local body, err = M.fetch("openlibrary", isbn,
    "https://openlibrary.org/api/books?format=json&jscmd=data&bibkeys=ISBN:" .. isbn)
  if not body then return nil, err end
  local ok, data = pcall(json.decode, body)
  local b = ok and type(data) == "table" and data["ISBN:" .. isbn]
  if not b then
    M.keep("openlibrary", isbn, 404)
    return nil, "Open Library has no record of ISBN " .. isbn
  end
  local rec = { authors = {}, subjects = {}, ids = { isbn = isbn }, type = "book", source = "Open Library " .. isbn }
  local title = type(b.title) == "string" and trim(b.title) or nil
  if title then
    -- "Algebraic Geometry (Graduate Texts in Mathematics)": the bracket is the series
    local head, series = title:match("^(.-)%s*%(([^()]+)%)$")
    if head and #head >= 3 and series:find("%a") then
      title = head
      local name, number = series:match("^(.-)%s*[;,]?%s*[vVnNoO.#]*%s*(%d+)$")
      rec.series, rec.series_index = name and #name > 3 and name or series, name and #name > 3 and number or nil
    end
    if type(b.subtitle) == "string" and b.subtitle ~= "" then title = title .. ": " .. trim(b.subtitle) end
    rec.title = title
  end
  for _, a in ipairs(type(b.authors) == "table" and b.authors or {}) do
    if type(a.name) == "string" then rec.authors[#rec.authors + 1] = a.name end
  end
  local pub = type(b.publishers) == "table" and b.publishers[1]
  if type(pub) == "table" and type(pub.name) == "string" then rec.publisher = pub.name end
  if type(b.publish_date) == "string" then
    rec.year = tonumber(b.publish_date:match("%f[%d](%d%d%d%d)%f[%D]"))
    local month, day = b.publish_date:match("^(%a+)%s+(%d+),")
    if rec.year and month and MONTHS[month:lower()] then
      rec.date = ("%04d-%02d-%02d"):format(rec.year, MONTHS[month:lower()], tonumber(day))
    end
  end
  local class = type(b.classifications) == "table" and b.classifications or {}
  for _, lcc in ipairs(type(class.lc_classifications) == "table" and class.lc_classifications or {}) do
    local tag = taxonomy.from_lcc(lcc)
    if tag then
      rec.subjects[1] = { tag = tag, confidence = 0.85, why = "class " .. lcc:match("^%S+") }
      break
    end
  end
  if not rec.subjects[1] then
    for _, dewey in ipairs(type(class.dewey_decimal_class) == "table" and class.dewey_decimal_class or {}) do
      local tag = taxonomy.from_dewey(dewey)
      if tag then
        rec.subjects[1] = { tag = tag, confidence = 0.8, why = "Dewey " .. dewey }
        break
      end
    end
  end
  return rec
end

-- ---- OpenAlex ----

--- OpenAlex's record for a DOI: title, authors and date, for works CrossRef
-- does not have.
function M.openalex(doi)
  local body, err = M.fetch("openalex", doi:lower(), "https://api.openalex.org/works/doi:" .. encode(doi) .. mailto("?"))
  if not body then return nil, err end
  local ok, w = pcall(json.decode, body)
  if not ok or type(w) ~= "table" or not w.title then return nil, "unreadable reply from OpenAlex" end
  local rec = { title = type(w.title) == "string" and unescape(w.title:gsub("%s+", " ")) or nil, authors = {}, subjects = {},
    ids = { doi = doi }, year = tonumber(w.publication_year), type = w.type, source = "OpenAlex " .. doi,
    date = type(w.publication_date) == "string" and w.publication_date or nil }
  for _, a in ipairs(type(w.authorships) == "table" and w.authorships or {}) do
    if type(a.author) == "table" and type(a.author.display_name) == "string" then
      rec.authors[#rec.authors + 1] = a.author.display_name
    end
  end
  -- (no subject is taken from it: OpenAlex sorts works into topics by
  -- machine, and files Wiles's proof of Fermat under mathematical physics)
  return rec
end

return M
