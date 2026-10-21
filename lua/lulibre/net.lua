--- Asks metadata services what they know about a work with an identifier:
-- arXiv, CrossRef, zbMATH Open, Open Library and OpenAlex. None of the
-- services needs an account or a key.
--
-- net stores every answer in the table `lookups`, so each work is asked
-- about once. A later run, or the same question from another book, gets the
-- stored answer. With `offline` set, net asks nothing at all.
--
-- These services are free and run by other people, so net asks politely:
--
-- - one request at a time to each service, and no faster than `PACE`,
--   whatever else is going on;
-- - many works in one request, where the service accepts that (arXiv,
--   CrossRef, Open Library);
-- - a service that says it is asked too much is left alone (`HOLD`), and
--   nothing is retried;
-- - a failure is never answered with more requests.
--
-- Every function here waits, so call them from a task. Each returns a record
--
--    { title=, authors={...}, year=, date="YYYY-MM-DD", publisher=, series=, series_index=,
--      subjects={ {tag=, confidence=, why=}, ... }, ids={ doi=, isbn=, arxiv=, zbl= }, type=, source= }
--
-- with whatever the service knows, or nil and the reason.
--
-- The option contact_email, if set, is sent with each request (in the
-- User-Agent, and as CrossRef's `mailto`). CrossRef and Open Library give
-- more room to callers they can reach. The option is empty unless you set it.
--
-- Each service has its own module (lulibre/net/*.lua), which adds its
-- functions to this table. The shared code is in net/core.lua.
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
