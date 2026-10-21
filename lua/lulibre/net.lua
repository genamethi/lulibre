--- Metadata services: what arXiv, CrossRef, zbMATH Open, Open Library and
-- OpenAlex say about a work that has an identifier. None of them needs an
-- account or a key.
--
-- Everything that is fetched is kept (the table `lookups`), so a work is
-- asked about once: a later run, or the same question from another book, is
-- answered from what was kept, and with M.offline set nothing is asked at
-- all.
--
-- These services are other people's, and free. Each is asked one thing at a
-- time and no faster than M.PACE, whatever else is going on; many works go
-- in one request where the service takes them (arXiv, CrossRef, Open
-- Library); one that says it is asked too much is left alone (M.HOLD) and
-- nothing is retried; and no failure is answered by asking more.
--
-- Every function here waits, so call them from a task. Each gives a record
--
--   { title=, authors={...}, year=, date="YYYY-MM-DD", publisher=, series=, series_index=,
--     subjects={ {tag=, confidence=, why=}, ... }, ids={ doi=, isbn=, arxiv=, zbl= }, type=, source= }
--
-- with whatever the service knows, or nil and why not.
--
-- The option contact_email, when set, is sent with each request (in the
-- User-Agent, and as CrossRef's `mailto`): CrossRef and Open Library give
-- more room to callers they can reach. It is empty unless you set it.
--
-- The services are each in a module of their own (lulibre/net/*.lua), which
-- adds its functions to this one table; what they share is in net/core.lua.
--
-- @module lulibre.net
-- @usage
-- local net = require "lulibre.net"
-- net.arxiv("1012.6008")            net.crossref("10.2307/2118559")
-- net.zbmath { doi = "10.2307/2118559" }     net.zbmath { arxiv = "1012.6008" }
-- net.openlibrary("9780387900407")  net.openalex("10.2307/2118559")
-- net.arxiv_prefetch { "1012.6008", "hep-th/9711200" }    -- many in one request;
-- net.crossref_prefetch(dois)  net.openlibrary_prefetch(isbns)   -- likewise
-- net.offline = true                -- answer from what is kept, or not at all
local M = require "lulibre.net.core"
require "lulibre.net.match"
require "lulibre.net.arxiv"
require "lulibre.net.crossref"
require "lulibre.net.zbmath"
require "lulibre.net.openlibrary"
require "lulibre.net.openalex"

return M
