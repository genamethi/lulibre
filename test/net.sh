#!/bin/sh
# Online lookups without the network: a service's request redefined to
# answer with a canned record (as a user's override would), the answer
# kept and not asked again, the record a parse that proposes, and the
# packaged services' readers on canned answers.
#   net.sh BUILT_BINARY
set -eu

bin=$(realpath "$1")
src=$(cd "$(dirname "$0")" && pwd)
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
sh "$src/mklib.sh" "$t/lib" >/dev/null 2>&1
# enough text on the paper's page for a record to be compared with it
pdf="$t/lib/Unknown/paper (1)/paper - Unknown.pdf"
sed -i -e 's/Length 120/Length 420/' -e '/math.NT/a\
BT /F1 12 Tf 72 620 Td (We give a short account of the classical sieve and some of its uses in additive problems.) Tj ET\
BT /F1 12 Tf 72 600 Td (The bounds are the expected ones, and the methods are those of the older literature in the field.) Tj ET\
BT /F1 12 Tf 72 580 Td (Nothing here is new, but the arguments are set out at more length than one usually finds them.) Tj ET' "$pdf"
export XDG_CONFIG_HOME=$t/config XDG_DATA_HOME=$t/data XDG_STATE_HOME=$t/state

cat > "$t/net.lua" <<'LUA'
local net = require "net"
local wit = require "wit"
local function say(...) local t = {} for i = 1, select("#", ...) do t[i] = tostring(select(i, ...)) end print(table.concat(t, "|")) end
local canned = [=[{"message":{"title":["Notes on Additive Number Theory"],"author":[{"given":"Paul","family":"Erdős"}],"publisher":"Example Press","issued":{"date-parts":[[1996,5]]}}}]=]
local asked = 0
net.services.crossref.how.request = function(keys) asked = asked + 1; return { [keys[1]] = canned } end
-- no other online service is asked, here or anywhere: no record
for name, s in pairs(net.services) do
  if name ~= "crossref" and not s.how.available then s.how.request = function(keys) return { [keys[1]] = false } end end
end
say("keys", net.keys(2)[1].service, net.keys(2)[1].key)
say("enrich", net.enrich(2))
say("kept", net.enrich(2), asked)
taskman.sleep(300)
for _, f in ipairs(wit.get(2)) do say("proposal", f.field, f.alts[1].value, f.alts[1].source) end
for _, f in ipairs(wit.get(2, { deep = true })) do say("deep", f.field, f.alts[1].value, f.alts[1].hidden) end
local a = net.services.arxiv.how.record([[<entry><id>http://arxiv.org/abs/1012.6008v1</id><published>2010-12-30T00:00:00Z</published><title>A Note on
 Sieve Methods</title><author><name>Ben Green</name></author><author><name>T. Tao</name></author></entry>]])
say("arxiv", a.title, a.authors, a.pubdate)
local o = net.services.openlibrary.how.record('{"ISBN:1":{"title":"Topics","subtitle":"In Combinatorics","authors":[{"name":"T. Tao"}],"publishers":[{"name":"CUP"}],"publish_date":"2006"}}')
say("openlibrary", o.title, o.authors, o.publisher, o.pubdate)
-- an identifier found in a book's text is a wit, and the book is asked
-- about by it
local propose = require "lulib._propose"
propose.propose(1, propose.settings())
for _, f in ipairs(wit.get(1)) do if f.field == "identifier:arxiv" then say("found", f.alts[1].value, f.alts[1].source) end end
for _, k in ipairs(net.keys(1)) do say("asked by", k.service, k.key) end
-- a propose asked for twice while one runs for the book: both return at
-- once, and the one running goes once more
local runs = 0
local once = propose.once
propose.once = function(...) runs = runs + 1; taskman.sleep(10) return once(...) end
local done
taskman.spawn(function() done = propose.propose(1, propose.settings()) end)
taskman.yield()
say("while running", (propose.propose(1, propose.settings())), (propose.propose(1, propose.settings())))
while not done do taskman.sleep(20) end
propose.once = once
say("runs", runs)
-- a new answer only ranks: the text is not read again
local txt = require "txt"
local load, loads = txt.load, 0
txt.load = function(...) loads = loads + 1 return load(...) end
propose.propose(1, propose.settings())
say("read again", loads)
-- a record the pages do not bear out is kept but not shown; one they do
-- is shown over the record's title
local arxiv_says
net.services.arxiv.how.request = function(keys)
  return { [keys[1]] = "<entry><id>http://arxiv.org/abs/" .. keys[1] .. "v1</id><title>" .. arxiv_says .. "</title></entry>" }
end
arxiv_says = "Quantum Gravity Without Tears"
net.enrich(1)
taskman.sleep(100)
local function title_of(o)
  for _, f in ipairs(wit.get(1, o)) do
    if f.field == "title" then
      local t = {}
      for _, a in ipairs(f.alts) do t[#t + 1] = a.source .. ":" .. tostring(a.hidden) end
      return table.concat(t, ",")
    end
  end
end
say("borne out not", tostring((title_of())):find("arxiv") == nil, tostring((title_of { deep = true })):find("arxiv:1") ~= nil)
txt.load = load
-- identifiers: which are the file's own
local ids = require "lulib._ids"
local function own_of(text)
  local t = {}
  for _, f in ipairs(ids.in_text(text, 100)) do t[#t + 1] = f.kind .. ":" .. f.value .. ":" .. tostring(f.own) end
  return table.concat(t, ",")
end
local pad = string.rep("words on a page ", 20) .. "\n"
do
  local t = {}
  for _, f in ipairs(ids.in_text("DOI 10.1007/978-0-8176-8253-8_1\n", 100, 300, 0.8)) do t[#t + 1] = f.value end
  for _, f in ipairs(ids.in_text("DOI 10.1007/978-0-8176-8253-8_1\n", 100, 20, 0.8)) do t[#t + 1] = f.value end
  say("chapter doi", table.concat(t, ","))
end
say("isbn label", own_of(pad .. "ISBN 0-387-90040-3\n"))
say("isbn bare", own_of(pad .. "0-387-90040-3\n"))
say("isbn-13 e", own_of(pad .. "e-ISBN-13: 978-0-387-90040-7\n"))
say("doi top", own_of("10.1000/abc\n"))
say("doi far", own_of(pad .. "see 10.1000/abc\n"))
say("doi label", own_of(pad .. "DOI 10.1000/abc\n"))
say("doi scan", own_of(pad .. "d0i: 10.1000/abc\n"))
say("doi cited", own_of(pad .. "as in doi:10.1000/abc\n"))
say("after refs", own_of(pad .. "ISBN 0-387-90040-3\nReferences\n[1] ISBN 978-3-16-148410-0 doi:10.1000/x\n"))
-- the words on an early page are no references
local function found_in(text, pages)
  local t = {}
  for _, f in ipairs(ids.in_text(text, 100, pages, 0.8)) do t[#t + 1] = f.kind .. ":" .. tostring(f.own) end
  return #t > 0 and table.concat(t, ",") or "none"
end
local isbn_line = "ISBN 0-387-90040-3\n"
say("refs contents", found_in("Title\n\fContents\nReferences\n245\nIndex\n\f" .. pad .. isbn_line, 300))
say("refs title", found_in("Handbook\nReferences\nA. Author\n\f" .. pad .. isbn_line, 300))
say("refs at the end", found_in(pad .. "\f" .. pad .. "\nReferences\n[1] " .. isbn_line, 2))
say("refs one page", found_in("A\nReferences\nB\n" .. pad .. isbn_line, 1))
say("refs early and at the end", found_in("A\nReferences\nB\n\f" .. pad .. "\fC\nBibliography\n[1] " .. isbn_line, 3))
say("arxiv stamp", own_of(pad .. "arXiv:1012.6008v1 [math.CO] 29 Dec\n"))
say("arxiv cited", own_of(pad .. "see arXiv:1012.6008\n"))
say("issn", own_of("ISSN 0012-7094\n"))
local meta = {}
for _, f in ipairs(ids.in_metadata('<prism:doi>10.1000/META</prism:doi>\ndoi: 10.48550/arXiv.1012.6008\n')) do meta[#meta + 1] = f.kind .. ":" .. f.value end
say("metadata", table.concat(meta, ","))
say("named", ids.in_name("/a/b/1012.6008v2.pdf").value, ids.in_name("/a/notes.pdf"))
-- :verify's report, on the library's books
local verify = require "lulib._verify"
local c0 = require("lulib._check").settings()
local v1 = verify.book(2, c0, 4000)
say("verify", v1.title.found, v1.title.words, v1.authors.found, v1.idents[1].kind, v1.idents[1].where, verify.doubtful(v1, c0))
say("verify cited", verify.doubtful({ title = { score = 1 }, idents = { { where = "cited" } } }, c0), verify.doubtful({ title = { score = 1 }, idents = { { where = "absent" } } }, c0))
-- a score is one value's: a weak reading isn't lifted by the others agreeing
local rank = require "lulib._rank"
local rw = { coverage = 45, agreement = 35, track = 20, near = 0.7, same = 0.95, records = {} }
local srcs = { { name = "record", kind = "record", fields = { title = "A Title" } } }
say("rank", rank.value("x", "series", "Some Series", 0.8, srcs, rw), rank.value("x", "title", "A Title", 0.7, srcs, rw) > 0.8, rank.value("x", "title", "Quite Different Words", 0.7, srcs, rw) < 0.5)
-- the pages grammar on a book's verso
local verso = "Graduate Texts in Mathematics 105\nSerge Lang\nSL2(R)\n\nSpringer\n© 1985 Springer-Verlag New York, Inc.\n"
  .. "Library of Congress Cataloging in Publication Data\nLang, Serge\nSL2(R).\n(Graduate texts in mathematics ; 105)\n"
  .. "1. Lie groups. I. Title. II. Series.\nQA387.L35 1985 512'.55 84-22162\nISBN 0-387-96198-4"
local verso_lines, n = {}, 0
for l in (verso .. "\n"):gmatch("(.-)\n") do n = n + 1; verso_lines[n] = { text = l, page = 1, n = n, size = l:find("SL2") and 20 or 10 } end
local read = require("exprman._pages").read(setmetatable({ text = verso, line = function(_, i) return verso_lines[i] end },
  { __len = function() return n end }))
say("verso", read.title.value, read.authors.value, read.publisher.value, read.pubdate.value, read.series.value, read.series_index.value)
say("verso how", read.series.how, read.pubdate.how, read.series.sure)
local heading = "Vector Calculus\nVelocity Versus Speed\nThe velocity of a body differs from its speed, and versus is what the versus of velocity is.\n"
local h_lines, hn = {}, 0
for l in heading:gmatch("(.-)\n") do hn = hn + 1; h_lines[hn] = { text = l, page = 1, n = hn, size = hn == 1 and 20 or 10 } end
local hr = require("exprman._pages").read(setmetatable({ text = heading, line = function(_, i) return h_lines[i] end }, { __len = function() return hn end }))
say("heading as author", hr.title and hr.title.value, hr.authors and hr.authors.value)
-- rewrites: value to value, under their names, surviving making proposals anew
local rewrites = require "lulib._rewrites"
rewrites.list.shout = { field = "publisher", value = function() return "SHOUT" end }
say("rewrite none", rewrites.run("shout", { 1 }))
rewrites.list.shout.field = "title"
say("rewrite", rewrites.run("shout", { 1 }))
propose.propose(1, propose.settings())
local first
for _, f in ipairs(wit.get(1)) do if f.field == "title" then first = f.alts[1] end end
say("rewrite first", first.value, first.source, first.score)
say("titlecase", rewrites.list.titlecase.value("ON THE THEORY OF NUMBERS", 1, {}), (rewrites.list.titlecase.value("Mixed Case", 1, {})))
say("split", rewrites.list["split-authors"].value("Yuri Manin; Matilde Marcolli"), (rewrites.list["split-authors"].value("One Person")))
local ca = require "lulib._capture"
say("capture", (ca.capture({ 2 }, "title", "^(.-)$ => series"))[1].fields.series)
say("clear", rewrites.clear("p,t", { 2 }), select(2, rewrites.clear("nope", { 2 })) ~= nil)
-- the other services' readers on canned answers
local z = net.services.zbmath.how.record('{"title":{"title":"Some Notes."},"contributors":{"authors":[{"name":"Tao, Terence"}]},"year":2006,"msc":[{"code":"11B30"}]}')
say("zbmath", z.title, z.authors, z.pubdate, z.tags ~= nil)
local oa = net.services.openalex.how.record('{"title":"Open Work","publication_date":"2001-02-03","authorships":[{"author":{"display_name":"A. Writer"}}],"primary_location":{"source":{"display_name":"J. Things"}}}')
say("openalex", oa.title, oa.authors, oa.pubdate, oa.publisher)
local art = net.services.crossref.how.record('{"message":{"type":"journal-article","title":["A Paper"],"subtitle":["And More"],"publisher":"JSTOR","container-title":["Annals of Mathematics"],"page":"10-29"}}')
say("crossref article", art.title, art.publisher, art.series, art.pages)
-- by title only with no identifier to ask by, only when asked, and a search's
-- answer only if it is the same work
local function by_title(k_) for _, k in ipairs(k_) do if k.ident == "title" then return true end end return false end
say("no titles", by_title(net.keys(2, {}, {})), by_title(net.keys(2, {}, { titles = true })))
local tcheck = require "lulib._check"
say("title match", tcheck.title_match("Topics in Additive Combinatorics and Number Theory", "Topics in Additive Combinatorics and Number Theory"),
    tcheck.title_match("An Introduction to the ipaddress module", "An Introduction to Module Theory"),
    tcheck.title_match("Algebraic Geometry", "Algebraic Geometry"),
    tcheck.title_match("Algebraic Geometry", "Algebraic Geometry", "Robin Hartshorne", "R. Hartshorne"),
    tcheck.title_match("Topics in Additive Combinatorics", "Topics in Additive Combinatorics", "Terence Tao", "Someone Else"))
-- a finder dropped in runs alone; the others are not run again
local finders_ran = 0
table.insert(ids.finders, { name = "mine", find = function() finders_ran = finders_ran + 1; return { { kind = "doi", value = "10.9999/mine", own = true } } end })
txt.load = function(...) loads = loads + 1 return load(...) end
local before = loads
local got_mine = false
for _, f in ipairs(ids.book(1)) do got_mine = got_mine or f.value == "10.9999/mine" end
ids.book(1)
txt.load = load
say("finder", got_mine, finders_ran, loads - before)
table.remove(ids.finders)
-- datasets: services that answer from a file, covering the service they stand for,
-- found by grep; arXiv's snapshot, Open Library's dumps, zbMATH's links
local datasets = require "lulib._datasets"
local nd = require "net.datasets"
local dir = datasets.dir()
local function write(name, text) local f = assert(io.open(dir .. "/" .. name, "w")); f:write(text); f:close() end
say("dataset absent", net.services["arxiv-snapshot"].how.available(), datasets.state(datasets.get("arxiv")))
local snap_line = [=[{"id":"2201.00001","title":"A Note on\n  Sieve Methods","authors":"T. Tao","authors_parsed":[["Tao","T.",""]],"categories":"math.NT","versions":[{"version":"v1","created":"Mon, 3 Jan 2022 19:18:42 GMT"}]}]=]
write("arxiv-metadata-oai-snapshot.json", '{"id":"9999.00001","title":"Other","authors":"X"}\n' .. snap_line .. "\n")
local af = nd.arxiv_fields(snap_line)
say("snapshot read", af.title, af.authors, af.pubdate, af.tags ~= nil)
say("dataset here", net.services["arxiv-snapshot"].how.available())
local online_asked = 0
net.services.arxiv.how.request = function(keys) online_asked = online_asked + #keys; return { [keys[1]] = false } end
local ans = require("net.service").ask("arxiv-snapshot", "2201.00001")
say("grep finds", ans == snap_line, require("net.service").ask("arxiv-snapshot", "2201.99999"))
local gz = dir .. "/ol_dump_editions_latest.txt.gz"
local ed = [=[/type/edition	/books/OL1M	3	2010-01-01	{"title":"Dumped Book","isbn_13":["9780387900407"],"authors":[{"key":"/authors/OL1A"}],"publishers":["Springer"],"publish_date":"March 3, 1994","series":["Graduate texts in mathematics ; 52"]}]=]
local au = [=[/type/author	/authors/OL1A	1	2010-01-01	{"name":"Hartshorne, Robin."}]=]
local h = io.popen('gzip -c > "' .. gz .. '"', "w"); h:write(ed, "\n"); h:close()
h = io.popen('gzip -c > "' .. dir .. '/ol_dump_authors_latest.txt.gz"', "w"); h:write(au, "\n"); h:close()
local ol = require("net.service").ask("openlibrary-dump", "9780387900407")
local of = net.services["openlibrary-dump"].how.record(ol)
say("dump read", of.title, of.authors, of.publisher, of.pubdate, of.series, of.series_index)
say("by statement", net.services.openlibrary.how.record('{"ISBN:1":{"title":"A Course","by_statement":"[by] J.-P. Serre."}}').authors)
-- a hypergraph of arXiv, when that's what is here
do
  local hyper = '{\n  "metadata": {},\n  "network-type": "undirected",\n  "edges": [\n    {\n      "attrs": {\n        "title": "Hyper Paper",\n        "categories": [\n          "math.NT"\n        ]\n      },\n      "edge": "1111.2222"\n    },\n    {\n      "attrs": {\n        "title": "Other",\n        "categories": []\n      },\n      "edge": "3333.4444"\n    }\n  ],\n  "incidences": [\n    {\n      "edge": "1111.2222",\n      "node": "A. Writer"\n    },\n    {\n      "edge": "3333.4444",\n      "node": "B. Other"\n    }\n  ]\n}\n'
  local snapshot = dir .. "/arxiv-metadata-oai-snapshot.json"
  os.rename(snapshot, snapshot .. ".away")
  write("arxiv.json", hyper)
  local got = require("net.service").ask("arxiv-snapshot", "1111.2222")
  local hf = got and nd.arxiv_fields(got) or {}
  say("hypergraph", hf.title, hf.authors, hf.tags ~= nil, datasets.status(datasets.get("arxiv")).here)
  os.remove(dir .. "/arxiv.json")
  os.rename(snapshot .. ".away", snapshot)
end
-- what a dataset has, the service it covers isn't asked about
local keys_of, online = net.keys, {}
net.keys = function() return { { service = "arxiv-snapshot", key = "2201.00001", ident = "arxiv" },
                               { service = "arxiv", key = "2201.00001", ident = "arxiv" },
                               { service = "arxiv", key = "2201.00002", ident = "arxiv" } } end
net.services.arxiv.how.request = function(keys) for _, k in ipairs(keys) do online[#online + 1] = k end return { [keys[1]] = false } end
net.enrich_many({ 1 })
net.keys = keys_of
say("covered", table.concat(online, ","))
local titles = nd.by_title(dir .. "/arxiv-metadata-oai-snapshot.json", { [nd.title_key("A Note on Sieve Methods")] = true })
say("by title", titles[nd.title_key("a note on  sieve methods")][1])
-- a fetch of a file by curl, from this machine; a file brought in by other means
local srcf = dir .. "/source.csv"
write("source.csv", "123,https://arxiv.org/pdf/2201.00001.pdf\n")
local zb = datasets.get("zbmath")
local fetched, why = datasets.fetch(zb, { url = "file://" .. srcf, say = function() end })
say("fetched", fetched, why, datasets.status(zb).here)
say("zbmath links", require("net.service").ask("zbmath-links", "2201.00001"), net.services["zbmath-links"].how.record("123")["identifier:zbl"])
say("adopt", datasets.adopt(srcf) == nil, (datasets.adopt(dir .. "/nothing")))
-- the check's score
local check = require "lulib._check"
local c = { k = 1, base = 0.25, authors = 0.25, pages = 0.25, same = 0.6 }
say("title score", check.title(0, 4, c), check.title(2, 4, c), check.title(4, 4, c))
say("length", check.length(100, 110, c), check.length(100, 200, c), check.length(nil, 200, c))
say("same identifier", require("mesr").cmp("identifier:arxiv", "math/0601054", "math/0601054v2"))
say("found", require("mesr").found("The Theory of Numbers", "numbers and THEO-\nRY here", check.minor))
say("found as printed", require("mesr").found("Université Chamseddine", "Universit´e\nChamseddine1,3†", check.minor))
-- one work asked for by two tasks at once: asked once, both answered; a
-- request that fails answers with its error and the service goes on
local svc = require "net.service"
local n = 0
svc.define("twice", { pace = 0, request = function(keys) n = n + 1; taskman.sleep(50); return { [keys[1]] = "rec" } end })
local got = {}
for i = 1, 2 do taskman.spawn(function() got[i] = net.ask("twice", "k") end) end
for _ = 1, 50 do if got[1] and got[2] then break end taskman.sleep(20) end
say("twice", got[1], got[2], n)
svc.define("broken", { pace = 0, request = function() error("down") end })
say("broken", select(2, net.ask("broken", "k")) ~= nil, (net.ask("broken", "j")))
LUA
"$bin" -L "$t/lib" index >/dev/null 2>&1
out=$("$bin" -L "$t/lib" run "$t/net.lua" 2>&1)

fails=0
expect() {
  case "$out" in *"$2"*) echo "ok    $1" ;; *) echo "FAIL  $1: '$2' not in:"; echo "$out" | sed 's/^/      /'; fails=$((fails + 1)) ;; esac
}
expect "a book is asked about by its canonical identifiers" "keys|crossref|10.1000/xyz"
expect "a new answer is counted" "enrich|1"
expect "a kept answer is not asked for again" "kept|0|1"
expect "the online record proposes: title" "proposal|title|Notes on Additive Number Theory|crossref"
expect "pubdate is less than the record has, under what replacing takes: only a deep review shows it" "deep|pubdate|1996|1"
expect "and publisher" "proposal|publisher|Example Press|crossref"
expect "arXiv's entry read" "arxiv|A Note on Sieve Methods|Ben Green & T. Tao|2010"
expect "Open Library's record read" "openlibrary|Topics: In Combinatorics|T. Tao|CUP|2006"
expect "one work asked for by two tasks at once is asked once, and both get it" "twice|rec|rec|1"
expect "a request that fails answers, and the service still serves" "broken|true|nil"
expect "an identifier in a book's text is a wit" "found|1012.6008|lex"
expect "and the book is asked about by it" "asked by|arxiv|1012.6008"
expect "a propose asked for while one runs returns at once" "while running|nil|nil"
expect "and the one running goes once more" "runs|2"
expect "ranking again reads no text" "read again|0"
expect "a record the pages do not bear out is shown only by a deep review" "borne out not|true|true"
expect "a chapter's DOI in a whole book is the book's; a chapter's own stays" "chapter doi|10.1007/978-0-8176-8253-8,10.1007/978-0-8176-8253-8_1"
expect "a labelled ISBN is the file's own" "isbn label|isbn:9780387900407:true"
expect "an unlabelled one is not" "isbn bare|isbn:9780387900407:false"
expect "nor is an e-ISBN's label missed" "isbn-13 e|isbn:9780387900407:true"
expect "a DOI at the top is the file's own" "doi top|doi:10.1000/abc:true"
expect "one further on with no label is not" "doi far|doi:10.1000/abc:false"
expect "one beginning a line with its label is" "doi label|doi:10.1000/abc:true"
expect "as a scan may read the label" "doi scan|doi:10.1000/abc:true"
expect "one with words before it is cited" "doi cited|doi:10.1000/abc:false"
expect "nothing after the references counts" "after refs|isbn:9780387900407:true"
expect "References on a contents page cuts nothing" "refs contents|isbn:true"
expect "nor in a title" "refs title|isbn:true"
expect "at a document's end it does" "refs at the end|none"
expect "in a document of one page, by how far into its text" "refs one page|isbn:true"
expect "an early one doesn't hide the real one" "refs early and at the end|none"
expect "an arXiv number with its margin stamp is the file's own" "arxiv stamp|arxiv:1012.6008:true"
expect "one further on with none is not" "arxiv cited|arxiv:1012.6008:false"
expect "an ISSN never is" "issn|issn:0012-7094:false"
expect "the metadata's identifiers, an arXiv DOI as its number" "metadata|doi:10.1000/meta,arxiv:1012.6008"
expect "a file named by an arXiv number" "named|1012.6008|nil"
expect ":verify: the record's title on the pages, its identifier not there" "verify|1|1|0|doi|absent|"
expect ":verify doubts an identifier only among the references, not one not found" "verify cited|true|false"
expect "a value with nothing to go by scores what its reading is sure of; agreeing lifts it, disagreeing lowers it; another field's says nothing" "rank|0.8|true|true"
expect "each value says which reading gave it, and how sure" "verso how|cataloguing data|cataloguing data|0.9"
expect "a heading set like a name is no author" "heading as author|Vector Calculus|nil"
expect "a verso read: title, authors, publisher, year, series and number" "verso|SL2(R)|Serge Lang|Springer|1985|Graduate Texts in Mathematics|105"
expect "a rewrite leaves a book whose field has no value" "rewrite none|0"
expect "a rewrite proposes" "rewrite|1"
expect "and comes first, after proposals are made anew" "rewrite first|SHOUT|shout|1"
expect "titlecase: capitals only, unless all" "titlecase|On the Theory of Numbers|nil"
expect "split-authors: several people in one, not one" "split|Yuri Manin & Matilde Marcolli|nil"
expect "capture runs a pattern" "capture|Notes"
expect "clear blanks what has a value" "clear|1|true"
expect "zbMATH's record read" "zbmath|Some Notes|Terence Tao|2006|true"
expect "OpenAlex's record read" "openalex|Open Work|A. Writer|2001-02-03|J. Things"
expect "an article's publisher is its journal, not who registered it; a subtitle is joined" "crossref article|A Paper: And More|Annals of Mathematics|nil|20"
expect "a book with an identifier is not asked about by title, asked or not" "no titles|false|false"
expect "a title search: same words; not sharing some; short needs an author; other authors, another work" "title match|true|false|false|true|false"
expect "a finder dropped in runs once and alone, reading no text" "finder|true|1|0"
expect "a dataset not here isn't asked" "dataset absent|false|not on this machine"
expect "arXiv's snapshot read" "snapshot read|A Note on Sieve Methods|T. Tao|2022-01-03|true"
expect "and found by grep; a key it lacks is no record" "grep finds|true|false"
expect "Open Library's dump, through gzip, its author by key" "dump read|Dumped Book|Robin Hartshorne|Springer|1994-03-03|Graduate Texts in Mathematics|52"
expect "a hypergraph of arXiv is read too" "hypergraph|Hyper Paper|A. Writer|true|true"
expect "what a dataset has isn't asked of the service it covers" "covered|2201.00002"
expect "a paper found by its title" "by title|2201.00001"
expect "an edition with no authors says who in words" "by statement|J.-P. Serre"
expect "a dataset fetched" "fetched|true|nil|true"
expect "zbMATH's table gives a number" "zbmath links|123|123"
expect "a file of no dataset isn't taken" "adopt|true|nil"
expect "a title's score: base, then in step with its words" "title score|0.25|0.75|1"
expect "a page count within the tolerance, outside it, none" "length|true|false|nil"
expect "an identifier compared with its own value is the same" "same identifier|equal"
expect "words found whole, across a broken line, small words not counted" "found|2|2"
expect "words as a page prints them: TeX's loose accents, figures and daggers glued on" "found as printed|2|2"
case "$out" in *"proposal|authors"*) echo "FAIL  authors the record already has were proposed"; fails=$((fails + 1)) ;; *) echo "ok    authors the record already has are not proposed" ;; esac
[ $fails -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
