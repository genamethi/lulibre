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
setman.set("mod_tree", "$t/mods")
LUA
cat >"$t/probe.lua" <<'LUA'
local function say(...) local t = {} for i = 1, select("#", ...) do t[i] = tostring(select(i, ...)) end print(table.concat(t, "|")) end
say("pages", setman.get("pages"))
say("ocr", setman.get("ocr"))
say("packaged", type(require("lulibre.grammar")))
say("user", require("mine"))
local ok, m = pcall(require, "modprobe")
say("mod_tree", ok and m or "not found")
say("cli only", (pcall(setman.set, "config_dir", "/x")))
say("bad value", select(2, pcall(setman.set, "ocr", "sometimes")))
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

# a reader of Lua's in tesseract's place (lulibre.ocr.read), and back
cat >"$cfg/init.lua" <<'LUA'
local ocr = require "lulibre.ocr"
function ocr.read(path, page, lang) return "Read By Lua\npage " .. page .. " " .. lang end
LUA
"$bin" -L "$t/lib" -o ocr=auto index >/dev/null 2>&1
db=$(ls "$t"/data/lulibre/lib-*.db | grep -v 'journal\|custom')
ocr=$(sqlite3 "$db" "SELECT group_concat(text, '|') FROM lines WHERE file = 1" 2>/dev/null || true)
printf '' >"$cfg/init.lua"

# a calibre store of Lua's in calibredb's place (lulibre.stores.calibre)
cat >"$t/store.lua" <<'LUA'
local stores = require "lulibre.stores"
local library = require "lulibre.library"
local seen, changed = {}, nil
evman.add("records_changed", function(ev) changed = table.concat(ev.ids, ",") .. "|" .. table.concat(ev.fields, ",") end)
function stores.calibre(book, fields) seen[#seen + 1] = book .. ":" .. fields.title; return true end
local batch = library.apply({ { book = 1, field = "title", value = "Stored By Lua" } })
local row = lulibre.sql("SELECT store, state FROM history.journal WHERE batch = ?", batch)[1]
print("store|" .. table.concat(seen, ",") .. "|" .. row.store .. "|" .. row.state)
for _ = 1, 50 do if changed then break end lulibre.sleep(20) end
print("changed|" .. tostring(changed))
function stores.calibre() return nil, "not today" end
print("refused|" .. tostring(select(2, library.apply({ { book = 1, field = "title", value = "Again" } }))))
-- a store whose task is cancelled while it waits still answers: the write fails
function stores.calibre() lulibre.sleep(60000) return true end
lulibre.spawn(function()
  lulibre.sleep(100)
  for _, t in ipairs(lulibre.tasks()) do if t.name:find("lulibre.stores.calibre", 1, true) then lulibre.cancel(t.id) end end
end)
print("cancelled|" .. tostring(select(2, library.apply({ { book = 1, field = "title", value = "Never" } }))))
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
lulibre.spawn(function() coroutine.wrap(busy)(2.5) print("busy|done") end)
lulibre.spawn(function() for _ = 1, 25 do busy(0.1) lulibre.sleep(0) end print("polite|done") end)
LUA
busy=$("$bin" -L "$t/lib" run "$t/busy.lua" 2>&1)

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
contains "lsqlite3 opens a database of the script's own, with lulibre's SQL functions" "sql|Paul Erdős|paul erdos" "$sql"
contains "and ends" "polite|done" "$busy"
[ $fails -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
