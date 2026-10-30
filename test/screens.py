"""uiman.list and uiman.form, in the interface: a key's action on the item
under the cursor, the items read again after it, an action's error shown,
a refresh on an event, a field edited through the form, review, a key
bound to a function, a pick cancelled late, on_change let go, one task
per panel, uiman.jump's answer, sleepers gone with their state, and the
sync folder read again by :source sync.

  python3 -I test/screens.py BIN

Starts BIN on a pseudo-terminal with a library of its own (test/mklib.sh)
and an init.lua of its own that makes the commands :demolist and
:demoform, types keys, and reads what the actions wrote to a file."""
import fcntl, os, pty, select, shutil, struct, subprocess, sys, tempfile, termios, time

bin_ = os.path.abspath(sys.argv[1])
here = os.path.dirname(os.path.abspath(__file__))
t = tempfile.mkdtemp()
log, out = os.path.join(t, "log"), os.path.join(t, "out")
subprocess.run(["sh", os.path.join(here, "mklib.sh"), os.path.join(t, "lib")], capture_output=True, check=True)
os.makedirs(os.path.join(t, "config", "lulibre"))
with open(os.path.join(t, "config", "lulibre", "init.lua"), "w") as f:
    f.write(r'''
function note(s) local f = io.open(os.getenv("SCREENS_OUT"), "a") f:write(s, "\n") f:close() end -- :lua too
keymap.set("n", "gx", function(o) note("key|" .. o.name .. "|" .. tostring(o.book)) end, { desc = "note the book" })
local items = { "a", "b", "c" }
cmdman.create("demolist", function()
  uiman.list {
    title = "demo", items = function() return items end,
    keys = {
      x = function(item, i) note("x|" .. item .. "|" .. i) table.remove(items, i) end,
      y = function() return nil, "not this one" end,
    },
    refresh = { records_changed = function() note("refreshed") end },
  }
  note("list closed|" .. table.concat(items, ","))
end)
local rec = { pages = "6", ocr = "never" }
cmdman.create("demoform", function()
  uiman.form {
    title = "form", record = function() return rec end, fields = { "pages", { "ocr", "OCR" } },
    edit = function(field, value) note("edit|" .. field .. "|" .. value) rec[field] = value end,
  }
  note("form closed|" .. rec.pages .. "|" .. rec.ocr)
end)
-- a task waiting on a pick, cancelled after a picker of lulibre's took the
-- pick's place but before the task heard so: the other picker stays open
cmdman.create("demopick", function()
  local a = taskman.spawn(function() uiman.pick({ "one", "two" }, { title = "demo pick" }) end)
  taskman.sleep(300)
  uiman.exec("pick books")
  taskman.cancel(a)
end)
-- a question with on_change, answered: nothing holds on_change afterwards
local held = setmetatable({}, { __mode = "v" })
cmdman.create("demoinput", function()
  local function ask()
    local f = function() end
    held[1] = f
    uiman.input { prompt = "say: ", on_change = f }
  end
  ask()
  collectgarbage()
  collectgarbage()
  note("on_change let go|" .. tostring(held[1] == nil))
end)
-- a second task waiting on a panel is refused; the first still hears it close
cmdman.create("demowait", function()
  local p <close> = uiman.panel { title = "two waits", rows = { { "a" } }, focus = false }
  taskman.spawn(function() note("first|" .. tostring(p:wait())) end)
  taskman.sleep(200)
  note("second|" .. tostring((pcall(p.wait, p))))
  p:close()
end)
-- two wits for book 1's title, and a store in calibredb's place: review
-- writes nothing to the library
cmdman.create("demowits", function()
  require("store").calibre = function(book, fields) note("stored|" .. book .. "|" .. fields.title) return true end
  require("wit").set(1, { { field = "title", value = "First Title", source = "front" },
                          { field = "title", value = "Second Title", source = "crossref" } })
  note("wits")
end)
''')
env = dict(os.environ, TERM="xterm-256color", LULIBRE_LOG=log, XDG_CONFIG_HOME=t + "/config",
           XDG_DATA_HOME=t + "/data", XDG_STATE_HOME=t + "/state", SCREENS_OUT=out)
os.makedirs(os.path.join(t, "sync"))
pid, fd = pty.fork()
if pid == 0:
    fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 120, 0, 0))
    os.execve(bin_, [bin_, "-L", os.path.join(t, "lib"), "-o", "path.sync=" + os.path.join(t, "sync")], env)


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


def keys(s, then=0.4):
    os.write(fd, s.encode())
    pump(then)


pump(3)
keys("gx", 1)        # a key bound to a function: a task with the book under the cursor
keys(":demolist\r", 1)
keys("j")            # b
keys("x")            # b goes; c is under the cursor
keys("y")            # refused: shown as an error
keys(":lua evman.post('records_changed', { ids = {}, fields = {} })\r", 1)
keys("x")            # c goes
keys("q", 0.6)
keys(":demoform\r", 1)
keys("e", 0.6)       # pages, its value 6 to edit
keys("\x7f9\r", 0.6)
keys("q", 0.6)
keys(":demowits\r", 1)
keys(":review\r", 1.5)
keys("j")            # the title's row, under the book's heading
keys(" ")            # its second alternative
keys("a", 1.5)       # accepted: written through store.calibre
keys("q", 0.6)
with open(os.path.join(t, "sync", "arrived.txt"), "w") as f:
    f.write("a file put in the sync folder while lulibre runs\n")
keys(":source sync\r", 1.5)  # the folder read again
keys(":lua note('in sync|' .. #require('bookman').ids('in:sync'))\r", 0.6)
keys(":source library\r", 0.6)
keys(":lua note('jump|' .. tostring(uiman.jump(999999)))\r", 0.6)
keys(":demowait\r", 1)
keys(":demoinput\r", 0.6)
keys("hi\r", 0.8)
keys(":demopick\r", 1.5)
keys(":lua note('typed')\r", 0.6)   # into the books picker, which is still open
keys("\x1b", 0.3)
keys(":lua note('after')\r", 0.6)
keys(":lua note('asleep|' .. taskman.spawn(function() taskman.sleep(60000) end))\r", 0.6)
keys(":restart-scripts\r", 2.5)
asleep = [l for l in open(out).read().splitlines() if l.startswith("asleep|")] if os.path.exists(out) else []
keys(":lua note('stale|' .. tostring(taskman.wake(%s)))\r" % (asleep[0].split("|")[1] if asleep else "0"), 0.6)
keys(":q\r", 0)
end = time.time() + 5
while time.time() < end:
    pump(0.1)
    done, _ = os.waitpid(pid, os.WNOHANG)
    if done:
        break
else:
    os.kill(pid, 9)
    os.waitpid(pid, 0)

got = open(out).read() if os.path.exists(out) else ""
text = open(log, errors="replace").read() if os.path.exists(log) else ""
shutil.rmtree(t)
fails = 0


def check(what, ok):
    global fails
    print(("ok    " if ok else "FAIL  ") + what)
    fails += not ok


check("a key bound to a function runs it, with the book under the cursor", "key|gx|1" in got)
check("a key acts on the item under the cursor", "x|b|2" in got)
check("and the items are read again after it", "x|c|2" in got)
check("an action's refusal is shown as an error", "not this one" in text)
check("an event in refresh runs its function, and the list reads its items again", "refreshed" in got)
check("the list returns when it closes", "list closed|a" in got)
check("e edits a form's field, through edit", "edit|pages|9" in got)
check("and the form returns when it closes", "form closed|9|never" in got)
check("review, a list: space shows the next alternative, a accepts it", "stored|1|Second Title" in got)
check(":source sync reads the sync folder again", "in sync|1" in got)
check("uiman.jump answers false for a book not in the list", "jump|false" in got)
check("a second task's p:wait is refused, and the first hears the panel close",
      "second|false" in got and "first|nil" in got)
check("after :restart-scripts, wake finds no sleeper of the old state", "stale|false" in got)
check("uiman.input lets go of on_change once answered", "on_change let go|true" in got)
check("a task's pick cancelled late leaves the picker that took its place open",
      "after" in got and "typed" not in got)
if fails:
    print(got)
    print(text[-3000:])
    sys.exit(1)
print("all passed")
