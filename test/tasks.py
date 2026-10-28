"""Tasks that never wait, in the interface: reported, stopped by :cancel
wherever they loop, and not in the way of quitting.

  python3 -I test/tasks.py BIN

Starts BIN on a pseudo-terminal with a library of its own (test/mklib.sh),
types the commands below, and reads what happened from its log file."""
import fcntl, os, pty, select, shutil, struct, subprocess, sys, tempfile, termios, time

bin_ = os.path.abspath(sys.argv[1])
here = os.path.dirname(os.path.abspath(__file__))
t = tempfile.mkdtemp()
log = os.path.join(t, "log")
subprocess.run(["sh", os.path.join(here, "mklib.sh"), os.path.join(t, "lib")], capture_output=True, check=True)
env = dict(os.environ, TERM="xterm-256color", LULIBRE_LOG=log, XDG_CONFIG_HOME=t + "/config",
           XDG_DATA_HOME=t + "/data", XDG_STATE_HOME=t + "/state")
pid, fd = pty.fork()
if pid == 0:
    fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 120, 0, 0))
    os.execve(bin_, [bin_, "--clean", "-L", os.path.join(t, "lib")], env)


def pump(secs):
    end = time.time() + secs
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.05)
        if not r:
            continue
        try:
            data = os.read(fd, 65536)
        except OSError:
            return
        if b"\x1b[c" in data:  # notcurses asks what the terminal is; the answer ends its questions
            os.write(fd, b"\x1b[?62;22c")


def line(s, then):
    os.write(fd, s.encode() + b"\r")
    pump(then)


LOOPS = [
    "while true do end",
    "while true do pcall(function() while true do end end) end",
    "coroutine.wrap(function() while true do end end)()",
    "local co = coroutine.create(function() while true do pcall(function() while true do end end) end end) "
    "while true do pcall(coroutine.resume, co) end",
]

pump(3)
for n, loop in enumerate(LOOPS, 1):
    line(":lua " + loop, 2.5 if n == 1 else 0.5)
    line(":cancel all", 0.5)
    line(':lua lulibre.notify("after %d")' % n, 0.5)
line(":lua while true do end", 0.5)
line(":q", 0)
end = time.time() + 5
status = None
while time.time() < end:
    pump(0.1)
    done, st = os.waitpid(pid, os.WNOHANG)
    if done:
        status = os.waitstatus_to_exitcode(st)
        break
if status is None:
    os.kill(pid, 9)
    os.waitpid(pid, 0)

text = open(log, errors="replace").read() if os.path.exists(log) else ""
shutil.rmtree(t)
fails = 0


def check(what, ok):
    global fails
    print(("ok    " if ok else "FAIL  ") + what)
    fails += not ok


check("a task that runs 2 s without waiting is reported", "has run 2." in text)
check("and :cancel stops it", "after 1" in text)
check("one that loops inside pcall", "after 2" in text)
check("one that loops in a coroutine it resumed", "after 3" in text)
check("and inside pcall(coroutine.resume)", "after 4" in text)
check("quitting while one runs ends lulibre at once, with status 0", status == 0)
if fails:
    print(text)
    sys.exit(1)
print("all passed")
