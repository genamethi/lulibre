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
local a = net.services.arxiv.how.record([[<entry><id>http://arxiv.org/abs/1012.6008v1</id><published>2010-12-30T00:00:00Z</published><title>A Note on
 Sieve Methods</title><author><name>Ben Green</name></author><author><name>T. Tao</name></author></entry>]])
say("arxiv", a.title, a.authors, a.year)
local o = net.services.openlibrary.how.record('{"ISBN:1":{"title":"Topics","subtitle":"In Combinatorics","authors":[{"name":"T. Tao"}],"publishers":[{"name":"CUP"}],"publish_date":"2006"}}')
say("openlibrary", o.title, o.authors, o.publisher, o.year)
-- an identifier found in a book's text is a wit, and the book is asked
-- about by it
local propose = require "lulibre.propose"
propose.propose(1, propose.settings())
for _, f in ipairs(wit.get(1)) do if f.field == "arxiv" then say("found", f.alts[1].value, f.alts[1].source) end end
for _, k in ipairs(net.keys(1)) do say("asked by", k.service, k.key) end
-- a propose asked for twice while one runs for the book: both return at
-- once, and the one running goes once more
local txt, runs = require "txt", 0
local of = txt.of
txt.of = function(...) runs = runs + 1 return of(...) end
local done
taskman.spawn(function() done = propose.propose(1, propose.settings()) end)
taskman.yield()
say("while running", (propose.propose(1, propose.settings())), (propose.propose(1, propose.settings())))
while not done do taskman.sleep(20) end
txt.of = of
say("runs", runs)
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
expect "and year" "proposal|year|1996|crossref"
expect "and publisher" "proposal|publisher|Example Press|crossref"
expect "arXiv's entry read" "arxiv|A Note on Sieve Methods|Ben Green & T. Tao|2010"
expect "Open Library's record read" "openlibrary|Topics: In Combinatorics|T. Tao|CUP|2006"
expect "one work asked for by two tasks at once is asked once, and both get it" "twice|rec|rec|1"
expect "a request that fails answers, and the service still serves" "broken|true|nil"
expect "an identifier in a book's text is a wit" "found|arxiv:1012.6008|lex"
expect "and the book is asked about by it" "asked by|arxiv|1012.6008"
expect "a propose asked for while one runs returns at once" "while running|nil|nil"
expect "and the one running goes once more" "runs|2"
case "$out" in *"proposal|authors"*) echo "FAIL  authors the record already has were proposed"; fails=$((fails + 1)) ;; *) echo "ok    authors the record already has are not proposed" ;; esac
[ $fails -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
