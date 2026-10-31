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
say("isbn label", own_of(pad .. "ISBN 0-387-90040-3\n"))
say("isbn bare", own_of(pad .. "0-387-90040-3\n"))
say("isbn-13 e", own_of(pad .. "e-ISBN-13: 978-0-387-90040-7\n"))
say("doi top", own_of("10.1000/abc\n"))
say("doi far", own_of(pad .. "see 10.1000/abc\n"))
say("doi label", own_of(pad .. "DOI 10.1000/abc\n"))
say("doi scan", own_of(pad .. "d0i: 10.1000/abc\n"))
say("doi cited", own_of(pad .. "as in doi:10.1000/abc\n"))
say("after refs", own_of(pad .. "ISBN 0-387-90040-3\nReferences\n[1] ISBN 978-3-16-148410-0 doi:10.1000/x\n"))
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
-- the pages grammar on a book's verso
local verso = "Graduate Texts in Mathematics 105\nSerge Lang\nSL2(R)\n\nSpringer\n© 1985 Springer-Verlag New York, Inc.\n"
  .. "Library of Congress Cataloging in Publication Data\nLang, Serge\nSL2(R).\n(Graduate texts in mathematics ; 105)\n"
  .. "1. Lie groups. I. Title. II. Series.\nQA387.L35 1985 512'.55 84-22162\nISBN 0-387-96198-4"
local verso_lines, n = {}, 0
for l in (verso .. "\n"):gmatch("(.-)\n") do n = n + 1; verso_lines[n] = { text = l, page = 1, n = n, size = l:find("SL2") and 20 or 10 } end
local read = require("exprman._pages").read(setmetatable({ text = verso, line = function(_, i) return verso_lines[i] end },
  { __len = function() return n end }))
say("verso", read.title, read.authors, read.publisher, read.pubdate, read.series, read.series_index)
-- the check's score
local check = require "lulib._check"
local c = { k = 1, base = 0.25, authors = 0.25, pages = 0.25, same = 0.6 }
say("title score", check.title(0, 4, c), check.title(2, 4, c), check.title(4, 4, c))
say("length", check.length(100, 110, c), check.length(100, 200, c), check.length(nil, 200, c))
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
expect "a labelled ISBN is the file's own" "isbn label|isbn:9780387900407:true"
expect "an unlabelled one is not" "isbn bare|isbn:9780387900407:false"
expect "nor is an e-ISBN's label missed" "isbn-13 e|isbn:9780387900407:true"
expect "a DOI at the top is the file's own" "doi top|doi:10.1000/abc:true"
expect "one further on with no label is not" "doi far|doi:10.1000/abc:false"
expect "one beginning a line with its label is" "doi label|doi:10.1000/abc:true"
expect "as a scan may read the label" "doi scan|doi:10.1000/abc:true"
expect "one with words before it is cited" "doi cited|doi:10.1000/abc:false"
expect "nothing after the references counts" "after refs|isbn:9780387900407:true"
expect "an arXiv number with its margin stamp is the file's own" "arxiv stamp|arxiv:1012.6008:true"
expect "one further on with none is not" "arxiv cited|arxiv:1012.6008:false"
expect "an ISSN never is" "issn|issn:0012-7094:false"
expect "the metadata's identifiers, an arXiv DOI as its number" "metadata|doi:10.1000/meta,arxiv:1012.6008"
expect "a file named by an arXiv number" "named|1012.6008|nil"
expect ":verify: the record's title and authors on the pages, its identifier not there" "verify|1|1|0|doi|absent|true"
expect "a verso read: title, authors, publisher, year, series and number" "verso|SL2(R)|Serge Lang|Springer|1985|Graduate Texts in Mathematics|105"
expect "a title's score: base, then in step with its words" "title score|0.25|0.75|1"
expect "a page count within the tolerance, outside it, none" "length|true|false|nil"
expect "words found whole, across a broken line, small words not counted" "found|2|2"
expect "words as a page prints them: TeX's loose accents, figures and daggers glued on" "found as printed|2|2"
case "$out" in *"proposal|authors"*) echo "FAIL  authors the record already has were proposed"; fails=$((fails + 1)) ;; *) echo "ok    authors the record already has are not proposed" ;; esac
[ $fails -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
