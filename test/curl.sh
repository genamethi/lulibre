#!/bin/sh
# The curl module against a server of the test's own, inside a private
# network namespace (unshare -rn): answers whatever their status, headers,
# redirects, a body sent, a timeout, a refused connection, requests at
# once, and a cancelled task's request. Needs python3 and unshare.
#   curl.sh BUILT_BINARY
set -eu

bin=$(realpath "$1")
src=$(cd "$(dirname "$0")" && pwd)
command -v python3 >/dev/null || { echo "curl: python3 not found, skipping"; exit 0; }
command -v unshare >/dev/null || { echo "curl: unshare not found, skipping"; exit 0; }
unshare -rn true 2>/dev/null || { echo "curl: no private namespace (unshare -rn), skipping"; exit 0; }

t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
sh "$src/mklib.sh" "$t/lib" >/dev/null 2>&1

cat >"$t/server.py" <<'PY'
import http.server, sys, time

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def answer(self, code, body=b"", headers=()):
        self.send_response(code)
        for k, v in headers: self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def do_GET(self):
        if self.path == "/hello": self.answer(200, b"hi", [("X-Thing", "a"), ("X-Thing", "b")])
        elif self.path == "/agent": self.answer(200, self.headers.get("User-Agent", "").encode())
        elif self.path == "/moved": self.answer(302, b"", [("Location", "/hello")])
        elif self.path == "/busy": self.answer(429, b"", [("Retry-After", "7")])
        elif self.path == "/slow":
            time.sleep(1)
            self.answer(200, b"late")
        else: self.answer(404, b"no")
    def do_PUT(self):
        n = int(self.headers.get("Content-Length", 0))
        self.answer(200, self.command.encode() + b" " + self.rfile.read(n))
    do_POST = do_PUT

class S(http.server.ThreadingHTTPServer):
    def handle_error(self, *a): pass  # a client that left (the timeout, the cancel)

S(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY

cat >"$t/requests.lua" <<'LUA'
local curl = require "curl"
local base = "http://127.0.0.1:8098"
local function say(...) local t = {} for i = 1, select("#", ...) do t[i] = tostring(select(i, ...)) end print(table.concat(t, "|")) end
local r = curl.req(base .. "/hello")
say("get", r.status, r.body, r.headers["x-thing"], r.headers["content-length"])
r = curl.req(base .. "/agent", { headers = { ["User-Agent"] = "test agent" } })
say("header sent", r.body)
r = curl.req(base .. "/moved")
say("redirect", r.status, r.body, r.url)
r = curl.req(base .. "/nowhere")
say("status", r.status, r.body)
r = curl.req(base .. "/busy")
say("retry", r.status, r.headers["retry-after"])
r = curl.req(base .. "/echo", { body = "a body" })
say("post", r.body)
r = curl.req(base .. "/echo", { method = "PUT", body = "put" })
say("put", r.body)
local none, err = curl.req(base .. "/slow", { timeout = 200 })
say("timeout", none, err ~= nil)
none, err = curl.req("http://127.0.0.1:8097/")
say("refused", none, err ~= nil)
local started, ended = os.time(), 0
local clock = require("luv").now
local t0 = clock()
for i = 1, 3 do
  lulibre.spawn(function()
    curl.req(base .. "/slow")
    ended = ended + 1
    if ended == 3 then say("at once", clock() - t0 < 1900) end
  end)
end
local id = lulibre.spawn(function()
  local _ <close> = setmetatable({}, { __close = function() say("cancelled ends", clock() - t0 < 600) end })
  curl.req(base .. "/slow")
  say("cancelled", "answered anyway")
end)
lulibre.sleep(100)
lulibre.cancel(id)
LUA

cat >"$t/inside.sh" <<'IN'
#!/bin/sh
t=$1; bin=$2
export XDG_CONFIG_HOME=$t/config XDG_DATA_HOME=$t/data XDG_STATE_HOME=$t/state HOME=$t
ip link set lo up 2>/dev/null || true
python3 -I "$t/server.py" 8098 &
pid=$!
i=0
while [ $i -lt 50 ] && ! python3 -c 'import socket; socket.create_connection(("127.0.0.1", 8098), 0.2)' 2>/dev/null; do
  sleep 0.1; i=$((i + 1))
done
"$bin" -L "$t/lib" run "$t/requests.lua" 2>&1
kill $pid
IN
out=$(unshare -rn sh "$t/inside.sh" "$t" "$bin")

fails=0
expect() { # description, expected line
  case "$out" in *"$2"*) echo "ok    $1" ;; *) echo "FAIL  $1: '$2' not in:"; echo "$out" | sed 's/^/      /'; fails=$((fails + 1)) ;; esac
}
expect "a GET answers with its status, body and headers, repeated ones joined" "get|200|hi|a, b|2"
expect "headers are sent" "header sent|test agent"
expect "a redirect is followed, and says where the answer came from" "redirect|200|hi|http://127.0.0.1:8098/hello"
expect "an answer of any status is an answer" "status|404|no"
expect "a header a service sends to hold callers back" "retry|429|7"
expect "a body is sent, by POST" "post|POST a body"
expect "another method" "put|PUT put"
expect "a timeout is an error" "timeout|nil|true"
expect "a refused connection is an error" "refused|nil|true"
expect "requests run at once" "at once|true"
expect "a cancelled task's request ends with it" "cancelled ends|true"
case "$out" in *"answered anyway"*) echo "FAIL  the cancelled task went on"; fails=$((fails + 1)) ;; esac
[ $fails -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
