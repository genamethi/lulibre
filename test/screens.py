"""uiman.list and uiman.form, in the interface: a key's action on the item
under the cursor, the items read again after it, an action's error shown,
a refresh on an event, a field edited through the form, the edit form, review, a key
bound to a function, a pick cancelled late, on_change let go, one task
per panel, uiman.jump's answer, sleepers gone with their state, and the
sync folder read again by :source sync, and completion of arguments.

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
scrnman.create("demolist", {
  actions = { { "drop", "x", "drop the item" }, { "refuse", "y", "refuse, saying why" } },
  hint = { "drop" },
})
keymap.set("demolist", "z", "drop") -- rebound beside x
cmdman.create("demolist", function()
  uiman.list {
    title = "demo", screen = "demolist", items = function() return items end,
    actions = {
      drop = function(item, i) note("x|" .. item .. "|" .. i) table.remove(items, i) end,
      refuse = function() return nil, "not this one" end,
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
-- completion of a command's arguments: a list of words, a kind of
-- lulibre's, a function asked when the arguments reach a word
cmdman.create("compwords", function(o) note("compwords|" .. o.args) end, { complete = { "alpha", "beta" } })
cmdman.create("compkind", function(o) note("compkind|" .. o.args) end, { complete = "filter" })
cmdman.create("compfn", function(o) note("compfn|" .. o.args) end, {
  complete = function(lead, line) taskman.sleep(100) return { "gamma", { text = "delta", detail = "the fourth" } } end,
})
-- an action of your own added to review (expose_modules, on by default)
local review = require "lulib._review"
table.insert(review.screen.actions, { "mine", "m", "note the row" })
review.actions.mine = function(e, alt) note("mine|" .. e.field .. "|" .. alt.value) return true end
scrnman.create("review", review.screen)
-- two wits for book 1's title, and a store in calibredb's place: review
-- writes nothing to the library
cmdman.create("demowits", function()
  require("store").calibre = function(book, fields)
    note("stored|" .. book .. "|" .. tostring(fields.title) .. (fields.authors and "|authors" or "")) return true
  end
  require("wit").set(1, { { field = "title", value = "First Title", source = "front" },
                          { field = "title", value = "Second Title", source = "crossref" } })
  note("wits")
end)
-- a dialog: a box ticked, a choice stepped through, a value typed, an action
cmdman.create("demodialog", function()
  local did, v = uiman.form {
    title = "demo dialog",
    sections = {
      { title = "Things", items = {
        { id = "box", kind = "check", label = "a box", value = false },
        { id = "pick", kind = "choice", label = "a choice", value = 1, choices = { "one", "two" } },
        { id = "typed", kind = "text", label = "a value", value = "" },
        { id = "barred", kind = "check", label = "barred", value = true, off = "not now" },
        { kind = "note", label = "a note" },
      } },
      { title = "", items = { { id = "go", kind = "action", label = "Go" } } },
    },
  }
  note(("dialog|%s|%s|%s|%s|%s"):format(tostring(did), tostring(v.box), tostring(v.pick), tostring(v.typed), tostring(v.barred)))
end)
cmdman.create("demoverify", function()
  uiman.notify("verify")
  require("lulib._verify").open(require("bookman").ids(""))
  note("verify closed")
end)
cmdman.create("demoreview", function() note("review named|" .. tostring(require("wit").reviews()[1].name)) end)
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
keys("z")            # c goes: z was bound to drop too
keys("q", 0.6)
keys(":demoform\r", 1)
keys("e", 0.6)       # pages, its value 6 to edit
keys("\x7f9\r", 0.6)
keys("q", 0.6)
keys(":demowits\r", 1)
keys(":review\r", 1.5)
keys("j")            # the title's row, under the book's heading
keys(" ")            # its second alternative
keys("m")            # an action added to review
keys("a", 0.8)       # marked; nothing written yet
keys("s", 0.4)       # names the review
keys("kept\r", 0.6)
keys("w", 1.5)       # written through store.calibre
keys("q", 0.6)
keys(":demoreview\r", 0.6)
keys(":demodialog\r", 1)
keys(" ", 0.3)        # the box
keys("j", 0.2)
keys("l", 0.3)        # the choice's next
keys("j", 0.2)
keys("\r", 0.4)       # types the value
keys("filled\r", 0.5)
keys("w", 0.8)        # the first action
keys(":demoverify\r", 1.5)
keys("z", 0.4)
keys("q", 0.6)
keys(":browse author\r", 1)
keys("j", 0.5)        # narrows the list to the author
keys("f", 0.5)
keys("q", 0.6)
keys(":lua uiman.filter('')\r", 0.4)
keys(":features\r", 0.6)
keys("q", 0.4)
keys(":offline\r", 0.6)
keys("q", 0.4)
keys(":history\r", 0.8)
keys("\r", 0.4)        # a batch's rows
keys("a", 0.4)
keys("q", 0.5)
keys(":snapshots\r", 1)
keys("n", 0.3)
keys("first\r", 0.8)
keys("q", 0.6)
keys(":lua note('snapshots|' .. #require('lulib._snapshots').list())\r", 0.5)
keys(":orphans\r", 1)  # none here: it says so and opens nothing
keys(":dupes\r", 1)
keys(":lua uiman.jump(1)\r", 0.6)
keys(":edit\r", 1)  # the edit form on book 1, a form that writes on w
keys("e", 0.4)       # the title
keys("\x15Edited Title\r", 0.4)
keys("je", 0.4)      # the authors
keys("\x15Someone Else\r", 0.4)
keys("x", 0.3)       # and that change taken back
keys("w", 1.5)       # written through store.calibre: the title alone
with open(os.path.join(t, "sync", "arrived.txt"), "w") as f:
    f.write("a file put in the sync folder while lulibre runs\n")
keys(":source sync\r", 1.5)  # the folder read again
keys(":lua note('in sync|' .. #require('bookman').ids('in:sync'))\r", 0.6)
keys(":source library\r", 0.6)
keys(":lua note('jump|' .. tostring(uiman.jump(999999)))\r", 0.6)
keys(":compwords b", 0.3)
keys("\t\r", 0.6)
keys(":compkind titl", 0.3)
keys("\t\r", 0.6)
keys(":compfn ", 0.8)         # the function answers after a moment
keys("d\t\r", 0.6)
keys(":sort tit", 0.3)        # one of lulibre's own, from the command table
keys("\t\r", 0.6)
keys(":lua note('sorted|' .. uiman.filter())\r", 0.6)
keys(":sort\r", 0.4)
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
check("and the items are read again after it; keymap.set rebinds a screen's action", "x|c|2" in got)
check("an action's refusal is shown as an error", "not this one" in text)
check("an event in refresh runs its function, and the list reads its items again", "refreshed" in got)
check("the list returns when it closes", "list closed|a" in got)
check("e edits a form's field, through edit", "edit|pages|9" in got)
check("and the form returns when it closes", "form closed|9|never" in got)
check("review, a list: space shows the next alternative, a marks it, w writes it", "stored|1|Second Title" in got)
check("s names the review", "review named|kept" in got)
check("a dialog: a box, a choice, a typed value, what can't be changed, an action",
      "dialog|go|true|2|filled|false" in got)
check(":verify opens, and closes", "verify closed" in got)
check(":snapshots takes one", "snapshots|1" in got)
check("an action added to review through its module runs on the row", "mine|title|Second Title" in got)
check("the edit form: e edits a field, x takes a change back, w writes the rest",
      "stored|1|Edited Title" in got and "stored|1|Edited Title|authors" not in got)
check(":source sync reads the sync folder again", "in sync|1" in got)
check("uiman.jump answers false for a book not in the list", "jump|false" in got)
check("Tab completes a command's arguments from its list of words", "compwords|beta" in got)
check("from a kind of lulibre's: the filter language", "compkind|title:" in got)
check("from a Lua function, whose answer comes when it comes", "compfn|delta" in got)
check("lulibre's own commands complete from the same table", "sorted|sort:title" in got)
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
