"""The questions lulibre asks on a terminal when no library is set: the
library calibre opened last, then calibre's content server where calibre
puts it (one of the test's own, asking for a password), its user and its
password file, each added to init.lua and asked once; and no library when
the answer is no. Inside a private network namespace (unshare -rn).

  unshare -rn python3 -I test/first.py BIN"""
import http.server, os, pty, select, shutil, subprocess, sys, tempfile, threading, time

bin_ = os.path.abspath(sys.argv[1])
here = os.path.dirname(os.path.abspath(__file__))
subprocess.run(["ip", "link", "set", "lo", "up"], capture_output=True)
t = tempfile.mkdtemp()
subprocess.run(["sh", os.path.join(here, "mklib.sh"), os.path.join(t, "lib")], capture_output=True, check=True)


class Asks(http.server.BaseHTTPRequestHandler):  # a content server that asks for a password
    def do_GET(self):
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Digest realm="calibre"')
        self.end_headers()

    def log_message(self, *a):
        pass


server = http.server.HTTPServer(("127.0.0.1", 8080), Asks)
threading.Thread(target=server.serve_forever, daemon=True).start()


def run(cfg, answers):
    """lulibre stats on a terminal, each answer typed when its question shows; what it printed"""
    env = dict(os.environ, XDG_CONFIG_HOME=cfg, XDG_DATA_HOME=t + "/data", XDG_STATE_HOME=t + "/state")
    env.pop("LULIBRE_LIBRARY", None)
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(t)
        os.execve(bin_, [bin_, "stats"], env)
    out, pending, end = b"", list(answers), time.time() + 20
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            try:
                data = os.read(fd, 65536)
            except OSError:
                break
            if not data:
                break
            out += data
        if pending and out.rstrip().endswith(pending[0][0].encode()):
            os.write(fd, pending.pop(0)[1].encode() + b"\n")
    os.waitpid(pid, 0)
    return out.decode(errors="replace")


def config(name):
    cfg = os.path.join(t, name)
    os.makedirs(cfg + "/calibre")
    os.makedirs(cfg + "/lulibre")
    with open(cfg + "/calibre/global.py.json", "w") as f:
        f.write('{"library_path": "%s"}' % (t + "/lib"))
    with open(cfg + "/calibre/password-file", "w") as f:
        f.write("secret\n")
    return cfg


fails = 0


def check(what, ok, more=""):
    global fails
    print(("ok    " if ok else "FAIL  ") + what)
    if not ok:
        print(more)
    fails += not ok


yes = config("yes")
first = run(yes, [("(y|N)", "y"), ("(y|N)", "y"), ("]:", "tester"), ("]:", "")])
init = open(yes + "/lulibre/init.lua").read() if os.path.exists(yes + "/lulibre/init.lua") else ""
check("no library set: asked whether to open calibre's last", "Library not set. Open %s/lib" % t in first, first)
check("taken, it opens", "books" in first, first)
check("the content server where calibre puts it, asking for a password: asked", "asks for a password" in first, first)
check("each answer is in init.lua", 'setman.set("path.library", "%s/lib")' % t in init and
      'setman.set("server", "http://127.0.0.1:8080")' in init and 'setman.set("user", "tester")' in init and
      'setman.set("path.password", "%s/calibre/password-file")' % yes in init, init)
again = run(yes, [])
check("and asked once", "(y|N)" not in again and "books" in again, again)

no = config("no")
said = run(no, [("(y|N)", "n")])
check("no: no library, and nothing added", "no library" in said and not os.path.exists(no + "/lulibre/init.lua"), said)

server.shutdown()
shutil.rmtree(t)
if fails:
    sys.exit(1)
print("all passed")
