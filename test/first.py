"""The questions lulibre asks on a terminal when no library is set: the
library calibre opened last, then calibre's content server when one runs
(one of the test's own, found among the processes, its port from its
socket, asking for a password), its user and its password file. The
answers hold for the run: nothing is kept, and they are asked again. Inside
private process and network namespaces, where the only calibre-server is
the test's.

  unshare -rnpf --mount-proc python3 -I test/first.py BIN"""
import os, pty, select, shutil, subprocess, sys, tempfile, time

bin_ = os.path.abspath(sys.argv[1])
here = os.path.dirname(os.path.abspath(__file__))
subprocess.run(["ip", "link", "set", "lo", "up"], capture_output=True)
t = tempfile.mkdtemp()
subprocess.run(["sh", os.path.join(here, "mklib.sh"), os.path.join(t, "lib")], capture_output=True, check=True)

# a calibre-server: a script of that name that listens, given --enable-auth
with open(t + "/calibre-server", "w") as f:
    f.write("import socket, time\ns = socket.socket()\ns.bind(('127.0.0.1', 8099))\ns.listen()\ntime.sleep(60)\n")
server = subprocess.Popen([sys.executable, "-I", t + "/calibre-server", "--enable-auth", t + "/lib"])
time.sleep(0.5)


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
check("no library set: asked whether to open calibre's last", "Library not set. Open %s/lib" % t in first, first)
check("taken, it opens", "books" in first, first)
check("the content server that runs: asked, with the port it listens on and its password",
      "http://127.0.0.1:8099, asking for a password" in first and "user [" in first and
      "file holding its password [%s/calibre/password-file]" % yes in first, first)
check("nothing is kept: no init.lua, no saved settings", not os.path.exists(yes + "/lulibre/init.lua") and
      not os.path.exists(t + "/state/lulibre/settings"))
again = run(yes, [("(y|N)", "n")])
check("so the next start asks again", "Library not set" in again and "no library" in again, again)
server.kill()
shutil.rmtree(t)
if fails:
    sys.exit(1)
print("all passed")
