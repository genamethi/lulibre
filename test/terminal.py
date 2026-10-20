"""lulibre on a terminal of its own, not in tmux: keys as a terminal sends
them, plain or in the kitty keyboard protocol (ghostty, kitty), which tmux
never passes on, so test/smoke.sh and test/forms.sh cannot see it.

  python3 -I test/terminal.py BIN LIB LOG plain|kitty TEXT

Starts BIN on a pseudo-terminal (120x30, TERM=xterm-ghostty), answers the
questions notcurses asks a terminal at start (in kitty mode: that it has
the keyboard protocol), then types ":echo TEXT" Enter, Tab, and ":q" Enter,
and exits with lulibre's status. What lulibre did is in LOG (its log file):
the echo's text, Tab's answer.

The kitty encoding is ghostty's, byte for byte, as captured from it with
notcurses' flags (CSI = 27 u: every key an escape code, with its event and
the text it types): a key with its text and its release, and a shifted key
as the key, Shift, and the text it types (":" is ";" with Shift, typing
":"), between Shift's own press and release."""
import fcntl, os, pty, select, struct, sys, termios, time

bin_, lib, log, mode, text = sys.argv[1:6]
kitty = mode == "kitty"

SHIFTED = {':': ';', '?': '/', '!': '1', '@': '2', '#': '3', '$': '4', '%': '5', '^': '6', '&': '7',
           '*': '8', '(': '9', ')': '0', '_': '-', '+': '=', '{': '[', '}': ']', '|': '\\', '"': "'",
           '<': ',', '>': '.', '~': '`'}
LSHIFT = 57441


def encode(ch):
    """The bytes a terminal sends for the key that types ch."""
    if not kitty:
        return {"\r": b"\r", "\t": b"\t"}.get(ch, ch.encode())
    if ch == "\r":
        return b"\x1b[13u\x1b[13;1:3u"
    if ch == "\t":
        return b"\x1b[9u\x1b[9;1:3u"
    base = SHIFTED.get(ch) or (ch.lower() if ch.isupper() else None)
    if base:
        k = ord(base)
        return (b"\x1b[%d;2u" % LSHIFT + b"\x1b[%d;2;%du" % (k, ord(ch)) + b"\x1b[%d;2:3u" % k
                + b"\x1b[%d;1:3u" % LSHIFT)
    k = ord(ch)
    return b"\x1b[%d;;%du\x1b[%d;1:3u" % (k, k, k)


env = dict(os.environ, TERM="xterm-ghostty", LULIBRE_LOG=log)
pid, fd = pty.fork()
if pid == 0:
    fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 120, 0, 0))
    os.execve(bin_, [bin_, "--clean", "-L", lib], env)


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
        # notcurses' questions end with the primary device attributes (CSI c):
        # answer that one last, after what else the terminal would say
        if b"\x1b[c" in data:
            reply = b""
            if kitty and b"\x1b[?u" in data:
                reply += b"\x1b[?0u"
            reply += b"\x1b[?62;22c"
            os.write(fd, reply)


def typing(s):
    for ch in s:
        os.write(fd, encode(ch))
        pump(0.05)


pump(3)
typing(":echo " + text + "\r")
pump(0.5)
typing("\t")
pump(0.5)
typing(":q\r")
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
    print("lulibre did not quit on :q")
    sys.exit(1)
sys.exit(status)
