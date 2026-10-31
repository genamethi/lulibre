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
mkdir -p "$cfg/lua" "$t/mods/share/lua"
lv=$("$bin" -V | sed -n 's/.*Lua \([0-9.]*\)).*/\1/p')
mkdir -p "$t/mods/share/lua/$lv"
echo 'return "from mod_tree"' >"$t/mods/share/lua/$lv/modprobe.lua"
echo 'return "the user'"'"'s copy"' >"$cfg/lua/exprman.lua"
echo 'return "the user'"'"'s own"' >"$cfg/lua/mine.lua"

mkdir -p "$cfg/lua/config"
cat >"$cfg/init.lua" <<'LUA'
require "config.options"
LUA
cat >"$cfg/lua/config/options.lua" <<LUA
local opt = lulib.opt
opt.pages = 9
opt.jobs = 3
opt.path.modtree = "$t/mods"
LUA
cat >"$t/probe.lua" <<'LUA'
local function say(...) local t = {} for i = 1, select("#", ...) do t[i] = tostring(select(i, ...)) end print(table.concat(t, "|")) end
say("pages", setman.get("pages"))
say("jobs", setman.get("jobs"))
local opt = lulib.opt
opt.path.librar, opt.mine = "x", 1
say("opt own", rawget(opt.path, "librar"), opt.mine, opt.path.library == setman.get("path.library"))
local function reader() end
local function writer() end
setman.set("ocr_eng", reader)
opt.store.calibre = writer
say("handlers", utils.ocr_eng == reader, opt.ocr_eng == reader, require("store").calibre == writer,
  setman.get("store.calibre") == writer)
opt.ocr_eng, opt.store.calibre = nil, nil
say("handlers back", utils.ocr_eng == nil, require("store").calibre == nil)
say("ocr", setman.get("ocr"))
say("packaged", type(require("exprman")))
say("prelude", type(uiman.list), type(uiman.form))
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

# a reader of Lua's in tesseract's place (utils.ocr_eng), and back; it waits
# once before it answers
cat >"$cfg/init.lua" <<'LUA'
utils.ocr_eng = function(path, page, lang) taskman.sleep(10) return "Read By Lua\npage " .. page .. " " .. lang end
LUA
"$bin" -L "$t/lib" -o ocr=auto index >/dev/null 2>&1
db=$(ls "$t"/data/lulibre/lib-*.db | grep -v '\.[a-z]*\.db$')
ocr=$(sqlite3 "$db" "SELECT group_concat(text, '|') FROM lines WHERE file = 1" 2>/dev/null || true)
printf '' >"$cfg/init.lua"

# a calibre store of Lua's in calibredb's place (store.calibre)
cat >"$t/store.lua" <<'LUA'
local store = require "store"
local seen, changed = {}, nil
evman.add("records_changed", function(ev) changed = table.concat(ev.ids, ",") .. "|" .. table.concat(ev.fields, ",") end)
function store.calibre(book, fields) seen[#seen + 1] = book .. ":" .. fields.title; return true end
local batch = store.apply({ { book = 1, field = "title", value = "Stored By Lua" } })
local sql, sqlite3 = require "sql", require "lsqlite3"
local jdb = sql.open(setman.get("path.journaldb"), sqlite3.OPEN_READONLY)
local row = sql.run(jdb, "SELECT store, state FROM journal WHERE batch = ?", batch)[1]
jdb:close()
print("store|" .. table.concat(seen, ",") .. "|" .. row.store .. "|" .. row.state)
for _ = 1, 50 do if changed then break end taskman.sleep(20) end
print("changed|" .. tostring(changed))
function store.calibre() return nil, "not today" end
print("refused|" .. tostring(select(2, store.apply({ { book = 1, field = "title", value = "Again" } }))))
function store.calibre() taskman.sleep(10) error("broken") end
print("raised|" .. tostring(select(2, store.apply({ { book = 1, field = "title", value = "Again" } }))))
print("kept|" .. type(store.calibre) .. "|" .. type(store.apply))
-- a store whose task is cancelled while it waits still answers: the write fails
function store.calibre() taskman.sleep(60000) return true end
taskman.spawn(function()
  taskman.sleep(100)
  for _, t in ipairs(taskman.tasks()) do if t.name:find("store.calibre", 1, true) then taskman.cancel(t.id) end end
end)
print("cancelled|" .. tostring(select(2, store.apply({ { book = 1, field = "title", value = "Never" } }))))
LUA
store=$("$bin" -L "$t/lib" run "$t/store.lua" 2>&1)

# taskman.self, a sleep until woken, and wake (which ends a timed sleep too)
cat >"$t/wake.lua" <<'LUA'
local woke = {}
local a = taskman.spawn(function() taskman.sleep() woke[#woke + 1] = "a" end)
local b = taskman.spawn(function() taskman.sleep(60000) woke[#woke + 1] = "b" end)
local c = taskman.spawn(function() taskman.sleep() woke[#woke + 1] = "c" end)
taskman.sleep(20)
local mine
taskman.spawn(function() mine = taskman.self() end)
print("wake|" .. tostring(taskman.wake(a)) .. "|" .. tostring(taskman.wake(a)) .. "|" .. tostring(taskman.wake(b)))
taskman.cancel(c)
taskman.sleep(20)
print("woke|" .. table.concat(woke, ",") .. "|" .. #taskman.tasks() .. "|" .. type(taskman.self()) .. "|" .. tostring(mine ~= taskman.self()))
LUA
wake=$("$bin" -L "$t/lib" run "$t/wake.lua" 2>&1)

# the example grammars (examples/grammars), each over a first page made
# for it: a PDF of lines, each "size|text", from the top
pdf() {
  out=$1; shift
  s="" y=740
  for l in "$@"; do
    s="${s}BT /F1 ${l%%|*} Tf 72 $y Td (${l#*|}) Tj ET
"
    y=$((y - 40))
  done
  {
    printf '%s\n' '%PDF-1.4' '1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj' '2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj' \
      '3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 612 792]/Contents 4 0 R/Resources<</Font<</F1 5 0 R>>>>>>endobj'
    printf '4 0 obj<</Length %d>>stream\n%s' "$(printf '%s' "$s" | wc -c)" "$s"
    printf '%s\n' 'endstream' 'endobj' '5 0 obj<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>endobj' \
      'trailer<</Root 1 0 R/Size 6>>' '%%EOF'
  } >"$out"
}
cp "$src"/../examples/grammars/*.lua "$cfg/lua/"
cat >"$t/grammar.lua" <<'LUA'
local exprman, txt = require "exprman", require "txt"
require(...)
local t <close> = txt.of(1)
for _, p in ipairs(exprman.parse(t, 1)) do
  if p.grammar == ... then
    local f = {}
    for _, k in ipairs { "title", "authors", "publisher", "pubdate", "#partof", "#part" } do
      f[#f + 1] = p.fields[k] and p.fields[k].value or "-"
    end
    print(p.grammar .. "|" .. table.concat(f, "|"))
  end
end
LUA
grammar() { # name, then the first page's lines
  name=$1; shift
  rm -rf "$t/g"
  sh "$src/mklib.sh" "$t/g" >/dev/null 2>&1
  pdf "$t/g/Unknown/paper (1)/paper - Unknown.pdf" "$@"
  printf 'Chapters in reading order\n| 1 | introduction | 10 | x |\n| 29 | morphisms | 100 | x |\n' \
    >"$t/g/Paul Erdos/Notes (2)/Notes - Paul Erdos.txt"
  "$bin" -L "$t/g" -o path.indexdb="$t/g.db" index >/dev/null 2>&1
  "$bin" -L "$t/g" -o path.indexdb="$t/g.db" run "$t/grammar.lua" "$name" 2>&1
  rm -f "$t"/g.db*
}
kc=$(grammar keith-conrad "24|GALOIS GROUPS OF CUBICS" "12|KEITH CONRAD" "10|1. Introduction")
hb=$(grammar handbook-of-algebra "24|Quantum Groups" "12|A. Author" "10|HANDBOOK OF ALGEBRA, VOL. 3" "10|2003 Elsevier Science B.V.")
sp=$(grammar stacks-project "24|MORPHISMS OF SCHEMES" "12|01QZ" "10|Contents")

# subjects at calibre's ".": the filters, calibre's list of the categories
# it shows as trees, and tag-dots, which rewrites "/" as "." (through a
# store in calibredb's place)
sh "$src/mklib.sh" "$t/tags" >/dev/null 2>&1
sqlite3 "$t/tags/metadata.db" "DELETE FROM tags; DELETE FROM books_tags_link;
  INSERT INTO tags VALUES (1, 'math.number-theory.additive'), (2, 'math/algebra');
  INSERT INTO books_tags_link(book, tag) VALUES (1, 1), (2, 2);
  CREATE TABLE preferences(id INTEGER PRIMARY KEY, key TEXT NOT NULL, val TEXT NOT NULL, UNIQUE(key));
  INSERT INTO preferences(key, val) VALUES ('categories_using_hierarchy', '[\"tags\", \"#genre\"]');"
cat >"$t/levels.lua" <<'LUA'
local bookman, sql, sqlite3 = require "bookman", require "sql", require "lsqlite3"
local function ids(f) return table.concat(bookman.ids(f), ",") end
print("levels|" .. ids("subject:number-theory") .. "|" .. ids("subject:math.number-theory") .. "|" .. ids("tag:=.math")
      .. "|" .. ids("tag:=..additive") .. "|" .. ids("tag:=.math.number"))
local db = sql.open(setman.get("path.indexdb"), sqlite3.OPEN_READONLY)
print("trees|" .. sql.run(db, "SELECT value FROM meta WHERE key = 'calibre_hierarchical'")[1].value)
db:close()
LUA
levels=$("$bin" -L "$t/tags" run "$t/levels.lua" 2>&1)
dots=$("$bin" -L "$t/tags" run tag-dots 2>&1)
printf 'require("store").calibre = function(book, f) print("stored|" .. book .. "|" .. f.tags) return true end\n' >"$cfg/init.lua"
dotsw=$("$bin" -L "$t/tags" run tag-dots write 2>&1)
printf '' >"$cfg/init.lua"

# every Lua file of lulibre's compiles in the Lua lulibre runs (5.5 will
# not load a file that assigns to a for loop's own variable)
cat >"$t/compile.lua" <<'LUA'
local luv = require "luv"
local bad = {}
local function walk(dir)
  local req = luv.fs_scandir(dir)
  while req do
    local name, kind = luv.fs_scandir_next(req)
    if not name then break end
    local path = dir .. "/" .. name
    if kind == "directory" then walk(path)
    elseif name:match("%.lua$") then
      local ok, err = loadfile(path)
      if not ok then bad[#bad + 1] = err end
    end
  end
end
for _, dir in ipairs { ... } do walk(dir) end
print(#bad == 0 and "compiled|all" or "compiled|" .. table.concat(bad, "\n"))
LUA
compiled=$("$bin" -L "$t/lib" run "$t/compile.lua" "$src/../lua" "$src/../scripts" "$src/../examples" 2>&1)

# the sync folder, read with calibre's records: an ebook file is a book in
# in:sync, named after its file; a copy of a library book's file is
# is:inlibrary; hidden files, unsynced/ and other files are passed over;
# a file taken out is dropped at the next reading
mkdir -p "$t/sync/sub" "$t/sync/unsynced"
cp "$t/lib/Unknown/paper (1)/paper - Unknown.pdf" "$t/sync/copy.pdf"
printf 'notes\n' >"$t/sync/sub/My_Notes.txt"
printf 'x\n' >"$t/sync/unsynced/back.txt"
printf 'x\n' >"$t/sync/.hidden.txt"
printf 'x\n' >"$t/sync/readme.md"
cat >"$t/sync.lua" <<'LUA'
local bookman, store = require "bookman", require "store"
local dir = ...
local function titles()
  local t = {}
  for _, b in ipairs(bookman.books("in:sync sort:title")) do t[#t + 1] = b.title end
  return table.concat(t, ",")
end
store.reload()
print("synced|" .. titles() .. "|" .. #bookman.ids("in:sync is:inlibrary"))
os.remove(dir .. "/sub/My_Notes.txt")
store.reload()
print("resynced|" .. titles())
LUA
synced=$("$bin" -L "$t/lib" -o path.sync="$t/sync" run "$t/sync.lua" "$t/sync" 2>&1)

# expose_modules: a packaged module's internal functions in its table, or not
cat >"$t/expose.lua" <<'LUA'
local review = require "lulib._review"
print("exposed|" .. type(review.actions) .. "|" .. type(review.open))
LUA
exposed=$("$bin" -L "$t/lib" run "$t/expose.lua" 2>&1)
hidden=$("$bin" -L "$t/lib" -o expose_modules=false run "$t/expose.lua" 2>&1)

# cmdman: every command, lulibre's and one made in Lua, and one by name
cat >"$t/cmd.lua" <<'LUA'
cmdman.create("hello", function() end, { desc = "say hello" })
local n = 0
for _, c in ipairs(cmdman.ls()) do if c.name == "propose" or c.name == "hello" then n = n + 1 end end
local h = cmdman.get("hello")
print("cmdman|" .. n .. "|" .. tostring(h and h.help) .. "|" .. tostring(cmdman.get("nope")))
-- a command made in Lua in front of one of lulibre's, then removed: lulibre's is back
cmdman.create("quit", function() end, { desc = "mine" })
local mine = cmdman.get("quit")
cmdman.del("quit")
local back = cmdman.get("quit")
print("in front|" .. tostring(mine and mine.help) .. "|" .. tostring(back and back.help))
-- a key bound to a function, twice: a binding with its desc, no command made for it
keymap.set("n", "gx", function() end, { desc = "first" })
keymap.set("n", "gx", function() end, { desc = "second" })
local made, about = 0, nil
for _, c in ipairs(cmdman.ls()) do if c.name:match("^lua%.") then made = made + 1 end end
for _, m in ipairs(uiman.maps()) do if m.keys == "gx" then about = m.about end end
local f, callback = function() end, nil
keymap.set("n", "gz", f)
for _, m in ipairs(uiman.maps()) do if m.keys == "gz" then callback = m.callback end end
local function refused(...) return tostring((pcall(scrnman.create, ...))) end
print("screens|" .. refused("panel", { actions = {} }) .. "|" .. refused("nv", { actions = {} }) .. "|"
  .. refused("s", { actions = { { "go", "g" } }, hint = { "stop" } }) .. "|"
  .. refused("s", { actions = { { "go", "x", "go" } }, hint = { "go" } }))
print("bad complete|" .. tostring((pcall(cmdman.create, "x", function() end, { complete = "nope" }))))
print("scrnman.set|" .. tostring((pcall(scrnman.set, "console", 5))) .. "|" .. tostring((pcall(scrnman.set, "console", { hint = "close" })))
  .. "|" .. tostring((pcall(scrnman.set, "console", { hint = { 1 } }))) .. "|" .. tostring((pcall(scrnman.set, "console", { hint = { "close" }, title = "LOG" })))
  .. "|" .. tostring((pcall(cmdman.create, "y", function() end, { complete = "help" }))))
print("fn key|" .. made .. "|" .. tostring(about) .. "|" .. tostring(callback == f))
LUA
cmds=$("$bin" -L "$t/lib" run "$t/cmd.lua" 2>&1)

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
local a = taskman.spawn(function() coroutine.wrap(busy)(2.5) print("busy|done") end)
local b = taskman.spawn(function() for _ = 1, 25 do busy(0.1) taskman.sleep(0) end print("polite|done") end)
print(("ids|task %d has|task %d has"):format(a, b))
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
contains "the command line's value over init.lua's" "pages|4" "$out"
contains "the command line's where init.lua is silent" "ocr|never" "$out"
contains "lua/config/options.lua, required by init.lua, sets through lulib.opt" "jobs|3" "$out"
contains "a name lulib.opt does not know is its own field, under a part too" "opt own|x|1|true" "$out"
contains "ocr_eng and store.calibre: the handlers, through setman and lulib.opt" "handlers|true|true|true|true" "$out"
contains "and nil gives them back to C" "handlers back|true|true" "$out"
contains "lulibre's own module before the user's of the same name" "packaged|table" "$out"
contains "the prelude loaded: uiman.list and uiman.form are there" "prelude|function|function" "$out"
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
contains "wake ends a sleep until woken, once, and a timed one" "wake|true|false|true" "$wake"
contains "the woken run on; a cancelled sleeper ends; self is each task's own" "woke|a,b|1|number|true" "$wake"
contains "the Keith Conrad grammar: the title in title case, the author as spelled" "keith-conrad|Galois Groups of Cubics|Keith Conrad|-|-|-|-" "$kc"
contains "the Handbook of Algebra grammar: the volume from the page's foot, the year, the title" "handbook-of-algebra|Quantum Groups|-|Elsevier|2003|Handbook of Algebra, Volume 3|-" "$hb"
contains "the Stacks project grammar: the chapter, and its number from the reading order" "stacks-project|Morphisms of Schemes|The Stacks Project|-|-|The Stacks Project|29" "$sp"
contains "subject: whole levels; tag:=. the tag or inside it; tag:=.. a level; never part of one" "levels|1|1|1|1|" "$levels"
contains "the categories calibre shows as trees, from its preferences" 'trees|["tags", "#genre"]' "$levels"
contains "tag-dots lists the tags it would rewrite" "    2  math/algebra  →  math.algebra" "$dots"
contains "and with write, rewrites them as one operation" "stored|2|math.algebra" "$dotsw"
contains "which it says can be undone" "as operation" "$dotsw"
contains "every Lua file in lua/, scripts/ and examples/ compiles" "compiled|all" "$compiled"
contains "the sync folder's ebook files are books, named after their files; a copy of the library's is in the library" "synced|copy,My Notes|1" "$synced"
contains "a file taken out of the sync folder is dropped at the next reading" "resynced|copy" "$synced"
contains "with expose_modules, a packaged module's internal functions are in its table" "exposed|table|function" "$exposed"
contains "without, they are not; its own functions still are" "exposed|nil|function" "$hidden"
contains "cmdman.ls lists lulibre's commands and Lua's, cmdman.get finds one or none" "cmdman|2|say hello|nil" "$cmds"
contains "a command made in Lua stands in front of lulibre's, which comes back when it goes" "in front|mine|leave lulibre" "$cmds"
contains "scrnman.create refuses a place of lulibre's, a name like modes, a hint that is no action; takes a screen" "screens|false|false|false|true" "$cmds"
contains "scrnman.set refuses what is not {hint=, title=}; takes a hint for a place of lulibre's; complete = \"help\"" "scrnman.set|false|false|false|true|true" "$cmds"
contains "cmdman.create refuses a complete it does not know" "bad complete|false" "$cmds"
contains "a key bound to a function is a binding with its desc, not a command; uiman.maps gives the function" "fn key|0|second|true" "$cmds"
contains "a change goes to the calibre store Lua put in calibredb's place, journaled" "store|1:Stored By Lua|calibre|2" "$store"
contains "and what it refuses fails, with its reason" "refused|not today" "$store"
contains "a store that raises after it waits fails the write, with the error" "raised|" "$store"
contains "and broken" "broken" "$store"
contains "the handler reads back; the module's functions are untouched" "kept|function|function" "$store"
contains "a change that applied posts records_changed with its books and fields" "changed|1|title" "$store"
contains "a store's task cancelled before it answers fails the write" "cancelled|the task that was to answer ended" "$store"
contains "coroutine.resume passes values both ways" "co|true|3" "$co"
contains "and returns the function's results at its end" "co|true|10" "$co"
contains "a dead coroutine is refused, as Lua refuses it" "co|false|cannot resume dead coroutine" "$co"
contains "an error inside is false and the error" "co|false|boom" "$co"
contains "coroutine.wrap yields its values" "wrap|1|2|3" "$co"
contains "and raises the error inside, where it was called" "wrap error|false|" "$co"
contains "a coroutine inside a coroutine" "nested|deep" "$co"
busy_id=$(printf '%s\n' "$busy" | sed -n 's/^ids|\([^|]*\)|.*/\1/p')
polite_id=$(printf '%s\n' "$busy" | sed -n 's/^ids|[^|]*|\(.*\)/\1/p')
contains "a task that runs 2 s without waiting is reported" "${busy_id} run 2." "$busy"
contains "and goes on" "busy|done" "$busy"
lacks "one that waits as often is not" "${polite_id} run" "$busy"
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
# settings made in Lua: in init.lua, given on the command line before they
# are made, listed and described as lulibre's are
mkdir -p "$t/made/lulibre"
cat >"$t/made/lulibre/init.lua" <<'LUA'
setman.create("mine.colour", { default = "red", choices = { "red", "blue" }, help = "a colour of mine" })
setman.create("mine.count", { default = 3, help = "how many" })
LUA
cat >"$t/made.lua" <<'LUA'
local function say(...) local t = {} for i = 1, select("#", ...) do t[i] = tostring(select(i, ...)) end print(table.concat(t, "|")) end
local i = setman.info("mine.colour")
say("made", setman.get("mine.colour"), lulib.opt.mine.colour, i.from, i.default, i.choices[2], i.help, i.made, i.type)
say("made count", setman.get("mine.count"), math.type(setman.get("mine.count")), setman.info("mine.count").type)
say("made refused", (pcall(setman.set, "mine.colour", "green")))
setman.set("mine.count", 9)
say("made set", setman.get("mine.count"))
say("own not made", (pcall(setman.create, "pages", {})), select(2, pcall(setman.create, "pages", {})):match("lulibre's own") ~= nil)
local names = table.concat(setman.ls(), " ")
say("ls", names:match("^path%.library") ~= nil, names:match("mine%.colour") ~= nil)
say("lulibre's info", setman.info("pages").from, setman.info("pages").made, setman.info("nothing"))
setman.create("mine.colour", { default = "red", choices = { "red", "blue", "green" }, help = "made again" })
say("made again", setman.get("mine.colour"), setman.info("mine.colour").help)
LUA
made=$(XDG_CONFIG_HOME="$t/made" "$bin" -L "$t/lib" -o mine.colour=blue -o typo=1 run "$t/made.lua" 2>&1)
contains "a setting made in init.lua takes the command line's value given before it was made" "made|blue|blue|command line|red|blue|a colour of mine|true|string" "$made"
contains "its type from its default" "made count|3|integer|integer" "$made"
contains "a value outside its choices is refused" "made refused|false" "$made"
contains "and set as any other" "made set|9" "$made"
contains "lulibre's own are not made again" "own not made|false|true" "$made"
contains "setman.ls names lulibre's and the made" "ls|true|true" "$made"
contains "setman.info describes lulibre's too" "lulibre's info|default|false|nil" "$made"
contains "made again: its value kept, its definition new" "made again|blue|made again" "$made"
contains "a value for a name nothing makes is said, and lulibre goes on" "typo=1 (the command line): no setting is called typo" "$made"
echo 'print("kept|" .. setman.get("mine.count"))' >"$t/kept.lua"
XDG_CONFIG_HOME="$t/made" XDG_STATE_HOME="$t/made-state" "$bin" -L "$t/lib" -o persistent=true run "$t/made.lua" >/dev/null 2>&1
kept=$(XDG_CONFIG_HOME="$t/made" XDG_STATE_HOME="$t/made-state" "$bin" -L "$t/lib" -o persistent=true run "$t/kept.lua" 2>&1)
contains "a made setting's value is kept in the saved state, and read when it is made again" "kept|9" "$kept"

# an empty init.lua, no -L, nobody at a terminal: calibre's last library is
# named, not opened (test/first.py asks on a terminal)
mkdir -p "$t/blank/lulibre" "$t/blank/calibre" "$t/elsewhere"
: >"$t/blank/lulibre/init.lua"
printf '{\n  "library_path": "%s"\n}\n' "$t/lib" >"$t/blank/calibre/global.py.json"
blank=$(cd "$t/elsewhere" && env -u LULIBRE_LIBRARY XDG_CONFIG_HOME="$t/blank" "$bin" stats 2>&1 </dev/null || true)
contains "an empty init.lua, no terminal: calibre's last library named" "calibre opened $t/lib last" "$blank"
contains "and not opened" "no library" "$blank"
printf '{"library_path": "%s"}' "$t/no-such-library" >"$t/blank/calibre/global.py.json"
gone=$(cd "$t/elsewhere" && env -u LULIBRE_LIBRARY XDG_CONFIG_HOME="$t/blank" "$bin" stats 2>&1 </dev/null || true)
contains "one that is not there is not named" "no library" "$gone"
[ $fails -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
