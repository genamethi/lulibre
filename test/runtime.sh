#!/bin/sh
# The Lua runtime from the outside: settings (the API over the command
# line, the saved state only with persistence), init.lua as the first task,
# and where modules are found (lulibre's own first, then the user's, then
# mod_tree, which a pixi environment ignores).
#   runtime.sh BUILT_BINARY
set -eu

bin=$(realpath "$1")
src=$(cd "$(dirname "$0")" && pwd)
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
sh "$src/mklib.sh" "$t/lib" >/dev/null 2>&1
export XDG_CONFIG_HOME=$t/config XDG_DATA_HOME=$t/data XDG_STATE_HOME=$t/state
cfg=$t/config/lulibre
mkdir -p "$cfg/lua/lulibre" "$t/mods/share/lua"
lv=$("$bin" -V | sed -n 's/.*Lua \([0-9.]*\)).*/\1/p')
mkdir -p "$t/mods/share/lua/$lv"
echo 'return "from mod_tree"' >"$t/mods/share/lua/$lv/modprobe.lua"
echo 'return "the user'"'"'s copy"' >"$cfg/lua/lulibre/grammar.lua"
echo 'return "the user'"'"'s own"' >"$cfg/lua/mine.lua"

cat >"$cfg/init.lua" <<LUA
setman.set("pages", 9)
setman.set("path.modtree", "$t/mods")
LUA
cat >"$t/probe.lua" <<'LUA'
local function say(...) local t = {} for i = 1, select("#", ...) do t[i] = tostring(select(i, ...)) end print(table.concat(t, "|")) end
say("pages", setman.get("pages"))
say("ocr", setman.get("ocr"))
say("packaged", type(require("lulibre.grammar")))
say("user", require("mine"))
local ok, m = pcall(require, "modprobe")
say("mod_tree", ok and m or "not found")
say("cli only", (pcall(setman.set, "path.config", "/x")))
say("bad value", select(2, pcall(setman.set, "ocr", "sometimes")))
local index = setman.get("path.indexdb")
say("witdb", setman.get("path.witdb") == index:sub(1, -4) .. ".wit.db")
say("netdb", setman.get("path.netdb"))
say("state", setman.get("path.state"))
setman.set("persistent", true)
setman.set("ocr", "auto")
LUA

out=$("$bin" -L "$t/lib" -o pages=4 -o ocr=never run "$t/probe.lua" 2>&1)
pixi=$(PIXI_ENVIRONMENT_NAME=default "$bin" -L "$t/lib" run "$t/probe.lua" 2>&1)
state=$(cat "$t/state/lulibre/settings" 2>/dev/null || true)
printf 'setman.set("pages", 9)\n' >"$cfg/init.lua"
rm -f "$t/state/lulibre/settings"
"$bin" -L "$t/lib" run "$t/probe.lua" >/dev/null 2>&1 || true
printf '' >"$cfg/init.lua"
again=$("$bin" -L "$t/lib" -o persistent=true run "$t/probe.lua" 2>&1)
# the saved state somewhere else, from the command line
elsewhere=$("$bin" -L "$t/lib" -o path.state="$t/st/saved" -o persistent=true run "$t/probe.lua" 2>&1)
saved=$(cat "$t/st/saved" 2>/dev/null || true)

# a reader of Lua's in tesseract's place (lulibre.ocr.read), and back
cat >"$cfg/init.lua" <<'LUA'
local ocr = require "lulibre.ocr"
function ocr.read(path, page, lang) return "Read By Lua\npage " .. page .. " " .. lang end
LUA
"$bin" -L "$t/lib" -o ocr=auto index >/dev/null 2>&1
db=$(ls "$t"/data/lulibre/lib-*.db | grep -v '\.[a-z]*\.db$')
ocr=$(sqlite3 "$db" "SELECT group_concat(text, '|') FROM lines WHERE file = 1" 2>/dev/null || true)
printf '' >"$cfg/init.lua"

# a calibre store of Lua's in calibredb's place (lulibre.stores.calibre)
cat >"$t/store.lua" <<'LUA'
local stores = require "lulibre.stores"
local store = require "store"
local seen, changed = {}, nil
evman.add("records_changed", function(ev) changed = table.concat(ev.ids, ",") .. "|" .. table.concat(ev.fields, ",") end)
function stores.calibre(book, fields) seen[#seen + 1] = book .. ":" .. fields.title; return true end
local batch = store.apply({ { book = 1, field = "title", value = "Stored By Lua" } })
local sql, sqlite3 = require "sql", require "lsqlite3"
local jdb = sql.open(setman.get("path.journaldb"), sqlite3.OPEN_READONLY)
local row = sql.run(jdb, "SELECT store, state FROM journal WHERE batch = ?", batch)[1]
jdb:close()
print("store|" .. table.concat(seen, ",") .. "|" .. row.store .. "|" .. row.state)
for _ = 1, 50 do if changed then break end taskman.sleep(20) end
print("changed|" .. tostring(changed))
function stores.calibre() return nil, "not today" end
print("refused|" .. tostring(select(2, store.apply({ { book = 1, field = "title", value = "Again" } }))))
-- a store whose task is cancelled while it waits still answers: the write fails
function stores.calibre() taskman.sleep(60000) return true end
taskman.spawn(function()
  taskman.sleep(100)
  for _, t in ipairs(taskman.tasks()) do if t.name:find("lulibre.stores.calibre", 1, true) then taskman.cancel(t.id) end end
end)
print("cancelled|" .. tostring(select(2, store.apply({ { book = 1, field = "title", value = "Never" } }))))
LUA
store=$("$bin" -L "$t/lib" run "$t/store.lua" 2>&1)

# coroutine.resume and coroutine.wrap are lulibre's, and behave as Lua's
cat >"$t/co.lua" <<'LUA'
local function say(...) local t = {} for i = 1, select("#", ...) do t[i] = tostring(select(i, ...)) end print(table.concat(t, "|")) end
local co = coroutine.create(function(a, b) local c = coroutine.yield(a + b) return c * 2 end)
say("co", coroutine.resume(co, 1, 2))
say("co", coroutine.resume(co, 5))
say("co", coroutine.resume(co))
say("co", coroutine.resume(coroutine.create(function() error("boom", 0) end)))
local gen = coroutine.wrap(function() for i = 1, 3 do coroutine.yield(i) end end)
say("wrap", gen(), gen(), gen())
local ok, err = pcall(coroutine.wrap(function() error("inside") end))
say("wrap error", ok, err)
say("nested", coroutine.wrap(function() return coroutine.wrap(function() coroutine.yield("deep") end)() end)())
LUA
co=$("$bin" -L "$t/lib" run "$t/co.lua" 2>&1)

# a task that runs 2 s without waiting is reported, inside a coroutine it
# resumed too, and goes on; one that waits as often is not. The loop
# allocates: under TSan, a signal waits for a call into the C library.
cat >"$t/busy.lua" <<'LUA'
local function busy(s) local t = os.clock() while os.clock() - t < s do local _ = {} end end
taskman.spawn(function() coroutine.wrap(busy)(2.5) print("busy|done") end)
taskman.spawn(function() for _ = 1, 25 do busy(0.1) taskman.sleep(0) end print("polite|done") end)
LUA
busy=$("$bin" -L "$t/lib" run "$t/busy.lua" 2>&1)

# expr: string's operations over strings and texts, with Lua and LPeg
# patterns
cat >"$t/expr.lua" <<'LUA'
local expr = require "expr"
local function say(...) local t = {} for i = 1, select("#", ...) do t[i] = tostring(select(i, ...)) end print(table.concat(t, "|")) end
local word = expr.C(expr.R("az", "AZ") ^ 1)
say("find", expr.find("one two", word, 4))
say("find lua", expr.find("one two", "%a+", 4))
say("match", expr.match("x = 12", expr.C(expr.R"09" ^ 1)))
say("match whole", expr.match("x = 12", expr.R"09" ^ 1))
local seen = {}
for w in expr.gmatch("a bb ccc", word) do seen[#seen + 1] = w end
say("gmatch", table.concat(seen, ","))
say("gsub", expr.gsub("erdos paul", word, function(w) return w:sub(1, 1):upper() .. w:sub(2) end))
say("gsub table", expr.gsub("a b c", word, { a = "1", c = "3" }))
say("gsub string", expr.gsub("Erdos, Paul", word * ", " * word, "%2 %1"))
say("gsub n", expr.gsub("a a a", "a", "b", 2))
say("anchored", expr.find("ab ab", -expr.B(1) * "ab", 2))
say("list", expr.gsub("the art of the deal", expr.list { "of", "the", "the art" }, "_"))
local key = expr.chain(expr.fold, { "%p", " " }, { "%s+", " " })
say("chain", key("Éléments  de Géométrie!"))
local t = { text = "Title\nby Someone\n", at = function(_, pos) return { bold = pos <= 6 } end }
local bold = expr.where(function(line) return line.bold end)
say("where", expr.match(t, bold * expr.C(expr.line)), expr.match("Title", bold * expr.C(expr.line)))
say("upto", expr.match(t, expr.upto(expr.P "by") * expr.C(expr.line)))
LUA
ex=$("$bin" -L "$t/lib" run "$t/expr.lua" 2>&1)

# iter: sequences, as vim.iter, with group and diff
cat >"$t/iter.lua" <<'LUA'
local iter = require "iter"
local function say(...) local t = {} for i = 1, select("#", ...) do t[i] = tostring(select(i, ...)) end print(table.concat(t, "|")) end
local n = { 1, 2, 3, 4, 5, 6 }
say("filter map", iter(n):filter(function(x) return x % 2 == 0 end):map(function(x) return x * 10 end):join(","))
say("map drops nil", iter(n):map(function(x) if x > 4 then return x end end):join(","))
say("fold", iter(n):fold(0, function(a, x) return a + x end))
say("pairs", iter({ a = 1 }):map(function(k, v) return k .. "=" .. v end):join(","))
say("take skip", iter(n):skip(1):take(2):join(","))
say("enumerate", iter({ "x", "y" }):enumerate():map(function(i, v) return i .. v end):join(","))
say("find any all", iter(n):find(function(x) return x > 3 end), iter(n):any(function(x) return x > 5 end),
  iter(n):all(function(x) return x > 0 end))
say("function", iter(("a b c"):gmatch("%a")):join(""))
local files = { { size = 3, p = "a" }, { size = 5, p = "b" }, { size = 3, p = "c" } }
local out = {}
for size, fs in iter(files):group(function(f) return f.size end) do
  out[#out + 1] = size .. ":" .. iter(fs):map(function(f) return f.p end):join("")
end
say("group", table.concat(out, ","))
say("diff", iter(files):diff({ { p = "a" } }, function(f) return f.p end):map(function(f) return f.p end):join(","))
LUA
it=$("$bin" -L "$t/lib" run "$t/iter.lua" 2>&1)

# lex: identifiers in their canonical form, where the check digit is right
cat >"$t/lex.lua" <<'LUA'
local expr, lex = require "expr", require "lex"
local function say(...) local t = {} for i = 1, select("#", ...) do t[i] = tostring(select(i, ...)) end print(table.concat(t, "|")) end
say("isbn", expr.match("ISBN 0-387-90040-3", lex.isbn), expr.match("ISBN 0 387 90040 3", lex.isbn),
  expr.match("see 978-0-387-90040-7.", lex.isbn))
say("not isbn", expr.match("phone 0387900404", lex.isbn), expr.match("x 0 387 90040 3", lex.isbn))
say("issn", expr.match("ISSN 0012-7094", lex.issn), expr.match("ISSN 0012-7095", lex.issn))
say("doi", expr.match("https://doi.org/10.1016/S1570-7954(96)80014-3.", lex.doi),
  expr.match("(see doi:10.1000/x)", lex.doi))
say("arxiv", expr.match("arXiv:1012.6008v1 [math.CO] 29 Dec 2010", lex.arxiv))
say("arxiv old", expr.match("arXiv:math/0601054", lex.arxiv), expr.match("1012.6008", lex.arxiv))
LUA
lx=$("$bin" -L "$t/lib" run "$t/lex.lua" 2>&1)

# the bundled scripts dupes and orphans, on a library of their own: book 3
# a byte-for-byte copy of book 1, book 4's file gone, a stray file and an
# empty folder
sh "$src/mklib.sh" "$t/two" >/dev/null 2>&1
mkdir -p "$t/two/Copy/paper (3)" "$t/two/Empty/x (9)"
cp "$t/two/Unknown/paper (1)/paper - Unknown.pdf" "$t/two/Copy/paper (3)/paper - Copy.pdf"
echo stray >"$t/two/Unknown/paper (1)/stray.txt"
sqlite3 "$t/two/metadata.db" "INSERT INTO books(id, title, sort, path, last_modified) VALUES
  (3, 'paper copy', 'paper copy', 'Copy/paper (3)', '2024-01-03 00:00:00+00:00'),
  (4, 'gone', 'gone', 'Copy/gone (4)', '2024-01-03 00:00:00+00:00');
  INSERT INTO data VALUES (3, 3, 'PDF', 0, 'paper - Copy'), (4, 4, 'EPUB', 0, 'gone - Copy');"
dupes=$("$bin" -L "$t/two" run dupes 2>&1)
orphans=$("$bin" -L "$t/two" run orphans 2>&1)

# lsqlite3, built in: a database of the script's own, with lulibre's SQL
# functions on its connection
cat >"$t/sql.lua" <<'LUA'
local sqlite = require "lsqlite3"
local db = sqlite.open(os.getenv("SQLDB"))
db:exec("CREATE TABLE t(name TEXT); INSERT INTO t VALUES ('Paul Erdős'), ('Terence Tao')")
for row in db:nrows("SELECT name, fold(name) AS key FROM t WHERE find(fold(name), '^paul')") do
  print("sql|" .. row.name .. "|" .. row.key)
end
db:close()
LUA
sql=$(SQLDB="$t/own.db" "$bin" -L "$t/lib" run "$t/sql.lua" 2>&1)

fails=0
contains() { # description, needle, haystack
  case "$3" in *"$2"*) echo "ok    $1" ;; *) echo "FAIL  $1: '$2' not in:"; echo "$3" | sed 's/^/      /'; fails=$((fails + 1)) ;; esac
}
lacks() { # description, needle, haystack
  case "$3" in *"$2"*) echo "FAIL  $1: '$2' in:"; echo "$3" | sed 's/^/      /'; fails=$((fails + 1)) ;; *) echo "ok    $1" ;; esac
}
contains "init.lua's value over the command line's" "pages|9" "$out"
contains "the command line's where init.lua is silent" "ocr|never" "$out"
contains "lulibre's own module before the user's of the same name" "packaged|table" "$out"
contains "the user's own module is found" "user|the user's own" "$out"
contains "mod_tree, set in init.lua, is searched" "mod_tree|from mod_tree" "$out"
contains "in a pixi environment, mod_tree is not" "mod_tree|not found" "$pixi"
contains "a command-line-only setting is refused from Lua" "cli only|false" "$out"
contains "a bad value is refused, saying which are allowed" "never|auto|always" "$out"
contains "persistence on: the state is written at exit, the API's values in it" "ocr=auto" "$state"
contains "and read back at the next start" "ocr|auto" "$again"
contains "an empty path setting is the path in use: beside the index" "witdb|true" "$out"
contains "and under the data folder" "netdb|$t/data/lulibre/net.db" "$out"
contains "and the saved state's" "state|$t/state/lulibre/settings" "$out"
contains "path.state from the command line is where the state is read" "state|$t/st/saved" "$elsewhere"
contains "and written" "ocr=auto" "$saved"
if command -v sqlite3 >/dev/null; then
  contains "OCR reads with the reader Lua put in tesseract's place" "Read By Lua|page 1 eng" "$ocr"
fi
contains "a change goes to the calibre store Lua put in calibredb's place, journaled" "store|1:Stored By Lua|calibre|2" "$store"
contains "and what it refuses fails, with its reason" "refused|not today" "$store"
contains "a change that applied posts records_changed with its books and fields" "changed|1|title" "$store"
contains "a store's task cancelled before it answers fails the write" "cancelled|the task that was to answer ended" "$store"
contains "coroutine.resume passes values both ways" "co|true|3" "$co"
contains "and returns the function's results at its end" "co|true|10" "$co"
contains "a dead coroutine is refused, as Lua refuses it" "co|false|cannot resume dead coroutine" "$co"
contains "an error inside is false and the error" "co|false|boom" "$co"
contains "coroutine.wrap yields its values" "wrap|1|2|3" "$co"
contains "and raises the error inside, where it was called" "wrap error|false|" "$co"
contains "a coroutine inside a coroutine" "nested|deep" "$co"
contains "a task that runs 2 s without waiting is reported" "busy.lua:2) has run 2." "$busy"
contains "and goes on" "busy|done" "$busy"
lacks "one that waits as often is not" "busy.lua:3)" "$busy"
contains "expr.find, with an LPeg pattern, as string.find" "find|5|7|two" "$ex"
contains "with a Lua pattern, string.find itself" "find lua|5|7" "$ex"
contains "expr.match: the captures" "match|12" "$ex"
contains "or the whole match" "match whole|12" "$ex"
contains "expr.gmatch" "gmatch|a,bb,ccc" "$ex"
contains "expr.gsub with a function" "gsub|Erdos Paul|2" "$ex"
contains "with a table, a missing key keeping the match" "gsub table|1 b 3|3" "$ex"
contains "with a string and its captures" "gsub string|Paul Erdos|1" "$ex"
contains "at most n" "gsub n|b b a|2" "$ex"
contains "-B(1) anchors at the start" "anchored|nil" "$ex"
contains "expr.list: whole words, the longest first" "list|_ _ _ deal|3" "$ex"
contains "expr.chain: fold, then the gsubs in order" "chain|elements de geometrie " "$ex"
contains "expr.where tests the line at the position; a string has none" "where|Title|nil" "$ex"
contains "expr.upto: whole lines up to a match" "upto|by Someone" "$ex"
contains "iter: filter, then map" "filter map|20,40,60" "$it"
contains "an item map makes nil of is dropped" "map drops nil|5,6" "$it"
contains "fold" "fold|21" "$it"
contains "a table's keys and values" "pairs|a=1" "$it"
contains "skip and take" "take skip|2,3" "$it"
contains "enumerate" "enumerate|1x,2y" "$it"
contains "find, any, all" "find any all|4|true|true" "$it"
contains "an iterator function" "function|abc" "$it"
contains "group: by key, in the order first met" "group|3:ac,5:b" "$it"
contains "diff: the items whose key the other has not" "diff|b,c" "$it"
contains "lex.isbn: 10 digits as 13, with hyphens, spaces after its label, or 13" "isbn|9780387900407|9780387900407|9780387900407" "$lx"
contains "but not a wrong check digit, nor spaces without the label" "not isbn|nil|nil" "$lx"
contains "lex.issn, by its check digit" "issn|0012-7094|nil" "$lx"
contains "lex.doi: its label off, lower case, its own parentheses kept, a sentence's not" "doi|10.1016/s1570-7954(96)80014-3|10.1000/x" "$lx"
contains "lex.arxiv: the number without its version, and the class" "arxiv|1012.6008|math.CO" "$lx"
contains "and the old form; never without the label" "arxiv old|math/0601054|nil" "$lx"
contains "lsqlite3 opens a database of the script's own, with lulibre's SQL functions" "sql|Paul Erdős|paul erdos" "$sql"
contains "and ends" "polite|done" "$busy"
contains "dupes: files of the same bytes, a group" "468 bytes  2 copies" "$dupes"
contains "with each book" "    3  paper copy" "$dupes"
contains "orphans: a file a record names, not on disk" "    4  Copy/gone (4)/gone - Copy.epub" "$orphans"
contains "a file no record names" "files no record names: 1" "$orphans"
contains "an empty folder" "Empty/x (9)" "$orphans"
[ $fails -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
