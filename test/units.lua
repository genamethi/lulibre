-- Unit checks for the Lua runtime modules and the API. Run headless:
--   lulibre run test/units.lua
-- Uses whatever library is configured only for API smoke checks that hold
-- for any library; the module checks need none.
local ids = require "lulibre.ids"
local json = require "lulibre.json"
local junk = require "lulibre.junk"
local names = require "lulibre.names"
local subjects = require "lulibre.subjects"
local taxonomy = require "lulibre.taxonomy"
local titlepage = require "lulibre.titlepage"

local fails, count = 0, 0
local function eq(what, got, want)
  count = count + 1
  if lulibre.inspect(got) ~= lulibre.inspect(want) then
    fails = fails + 1
    print(("FAIL  %s\n      got  %s\n      want %s"):format(what, lulibre.inspect(got), lulibre.inspect(want)))
  end
end

-- identifiers
eq("doi", ids.doi("see https://doi.org/10.1016/S1570-7954(07)05013-9."), "10.1016/S1570-7954(07")
eq("doi plain", ids.doi("DOI 10.1007/978-3-540-06140-1, more"), "10.1007/978-3-540-06140-1")
eq("isbn13 bad check digit", ids.isbn("ISBN 978-0-387-90244-0 (hardcover)"), nil)
eq("isbn13 ok", ids.isbn("ISBN 978-3-16-148410-0"), "9783161484100")
eq("isbn10", ids.isbn("ISBN 0-306-40615-2"), "0306406152")
eq("isbn10 labelled", ids.isbn("ISBN-10: 3-540-06140-1"), "3540061401")
eq("not an isbn", ids.isbn("pages 9781234567890 of nothing"), nil)
eq("arxiv stamp", { ids.arxiv_stamp("arXiv:1012.6008v1  [math.CO]  29 Dec 2010") }, { "1012.6008", "math.CO" })
eq("arxiv old", { ids.arxiv("arXiv:math/0601054v1 [math.QA] 3 Jan 2006") }, { "math/0601054", "math.QA" })
eq("arxiv filename", ids.arxiv("", "/x/y/2405.20552v2.pdf"), "2405.20552")
eq("arxiv filename strict", ids.arxiv("", "[Springer] 1996.00312 Harmonic.pdf"), nil)
eq("arxiv year new", ids.arxiv_year("1012.6008"), 2010)
eq("arxiv year old", ids.arxiv_year("math/9901054"), 1999)
eq("msc", ids.msc("2010 Mathematics Subject Classification. Primary 11B37; Secondary 05A"), "11")
eq("msc ams", ids.msc("AMS subject classification: 68W30, 65C60"), "68")
eq("msc none", ids.msc("no such thing here"), nil)

-- taxonomy
eq("arxiv class", taxonomy.from_arxiv("math.NT"), "math/number-theory")
eq("arxiv archive", taxonomy.from_arxiv("math.XX"), "math/general")
eq("alias", taxonomy.canonical("math/geometry/algebraic"), "math/algebraic-geometry")

-- junk
eq("junk filename", junk.title("pftb.dvi"), true)
eq("junk springer", junk.title("2008_Book_Something"), true)
eq("junk heading", junk.title("Contents"), true)
eq("junk error page", junk.title("503 Service Temporarily Unavailable"), true)
eq("real title", junk.title("A Walk in the Noncommutative Garden"), false)
eq("junk author", junk.author("Microsoft Word"), true)
eq("junk author tex", junk.author("TeX output 2004.07.14"), true)
eq("real author", junk.author("Jean-Pierre Serre"), false)

-- names
eq("clean", names.clean("William A. Stein1"), "William A. Stein")
eq("clean marks", names.clean("E. Di Nardo ∗"), "E. Di Nardo")
eq("clean degree", names.clean("Dr. Jane Q. Public"), "Jane Q. Public")
eq("clean particle", names.clean("Gerard van der Geer"), "Gerard van der Geer")
eq("not a name: institution", names.clean("Princeton University"), nil)
eq("not a name: one word", names.clean("Bourbaki"), nil)
eq("not a name: digits", names.clean("July 14 2004"), nil)
eq("not a name: quote", names.clean("” Einige"), nil)
eq("accented", names.clean("Loïc Foissy"), "Loïc Foissy")
eq("split semicolons", names.split("ALAIN CONNES; MATILDE MARCOLLI"), { "ALAIN CONNES", "MATILDE MARCOLLI" })
eq("split and", names.split("Yuri Manin and Matilde Marcolli"), { "Yuri Manin", "Matilde Marcolli" })
eq("split keeps Last, First", names.split("Knuth, Donald"), { "Knuth, Donald" })
eq("split commas of full names", names.split("George Casella, Roger L. Berger"), { "George Casella", "Roger L. Berger" })
eq("validate caps list", names.validate({ "DANIEL J. BERNSTEIN, HENDRIK W. LENSTRA, JR., AND JONATHAN PILA" }),
  { "DANIEL J. BERNSTEIN", "HENDRIK W. LENSTRA", "JONATHAN PILA" })
eq("validate across lines", names.validate({ "Steven J. Miller and", "Ramin Takloo-Bighash" }),
  { "Steven J. Miller", "Ramin Takloo-Bighash" })
eq("titlecase", names.titlecase("JEAN-PIERRE SERRE"), "Jean-Pierre Serre")
eq("titlecase accents", names.titlecase("PAUL ERDŐS"), "Paul Erdős")
eq("titlecase latin1", names.titlecase("ÉTIENNE FOUVRY"), "Étienne Fouvry")
eq("titlecase leaves mixed", names.titlecase("N. K. Meher"), "N. K. Meher")
eq("title caps", names.title_caps("A WALK IN THE NONCOMMUTATIVE GARDEN"), "A Walk in the Noncommutative Garden")
eq("authors line", names.looks_like_authors("E. Di Nardo ∗, G. Guarino †, D. Senato ‡"), true)
eq("prose line", names.looks_like_authors("A new algorithm for computing the formula"), false)
eq("affiliation line", names.looks_like_authors("Department of Mathematics, MIT"), false)

-- title page
local function L(text, size, extra)
  local l = { text = text, size = size, rotated = false, super = false }
  for k, v in pairs(extra or {}) do l[k] = v end
  return l
end
local tp = titlepage.classify({
  L("arXiv:1012.6008v1  [math.CO]  29 Dec 2010", 20, { rotated = true }),
  L("A new algorithm for computing the multivariate", 17.2),
  L("formula", 17.2),
  L("E. Di Nardo ∗, G. Guarino †, D. Senato ‡", 12, { super = true }),
  L("October 29, 2018", 12),
  L("Abstract", 10),
  L("We use a symbolic approach.", 10),
})
eq("tp arxiv", tp.arxiv, "1012.6008")
eq("tp subject", tp.subject, "math/combinatorics")
eq("tp title", tp.title, "A new algorithm for computing the multivariate formula")
eq("tp authors", tp.authors, { "E. Di Nardo", "G. Guarino", "D. Senato" })
tp = titlepage.classify({
  L("Documenta Math.", 8), L("587", 10), L("Visibility of Mordell-Weil Groups", 12),
  L("William A. Stein1", 10, { super = true }), L("Received: March 8, 2005", 8), L("Abstract.", 10),
  L("2000 Mathematics Subject Classification: 11G05, 11G10", 8),
})
eq("tp page number skipped", tp.title, "Visibility of Mordell-Weil Groups")
eq("tp footnote digit", tp.authors, { "William A. Stein" })
eq("tp msc", tp.subject, "math/number-theory")
tp = titlepage.classify({ L("Graduate Texts in Mathematics", 24), L("Springer", 12) })
eq("tp series is not a title", tp.title, nil)

-- subjects
local ranked = subjects.score("modular forms and elliptic curves over number fields; the riemann hypothesis")
eq("subject vocabulary", ranked[1] and ranked[1].subject, "math/number-theory")
eq("subject none", #subjects.score("lorem ipsum dolor sit amet"), 0)

-- json
eq("json decode", json.decode('{"a": [1, 2.5, "x\\ny", true, null], "b": {"c": "\\u00e9"}}'),
  { a = { 1, 2.5, "x\ny", true }, b = { c = "é" } })
eq("json round trip", json.decode(json.encode({ k = { 1, 2, "three" } })), { k = { 1, 2, "three" } })

-- templates
local template = require "lulibre.template"
local c = assert(template.compile("%author% - %title% (%year%)"))
eq("template match", template.match(c, "Serge Lang -  Algebra (2002)"), { author = "Serge Lang", title = "Algebra", year = "2002" })
eq("template miss", template.match(c, "no separators here"), nil)
c = assert(template.compile("%title% - %author% - %year%"))
eq("template three", template.match(c, "A - B C - 1999"), { title = "A", author = "B C", year = "1999" })
c = assert(template.compile("^(%d+)%.(%d+) => major, minor"))
eq("raw pattern", template.match(c, "1012.6008"), { major = "1012", minor = "6008" })
eq("template needs fields", (template.compile("just text")), nil)
eq("bad raw pattern", (template.compile("(unclosed => x")), nil)
eq("canonical year", { template.canonical("year", "1999") }, { "pubdate", "1999" })
eq("canonical doi", { template.canonical("doi", "10.1/x") }, { "identifiers", "doi:10.1/x" })
eq("template format", template.format("%author% - %title% (%year%)",
  { id = 1, title = "A/B", author = "X Y", year = 2001, tags = {} }), "X Y - A-B (2001)")

-- edits
local edit = require "lulibre.edit"
local book = { id = 1, title = "T", author = "A One & B Two", authors = { "A One", "B Two" },
  tags = { "math/algebra", "x" }, idents = { isbn = "123", doi = "10.1/a" }, pubdate = "2001-02-03" }
eq("current authors", edit.current(book, "authors"), "A One & B Two")
eq("current identifiers", edit.current(book, "identifiers"), "doi:10.1/a, isbn:123")
eq("unknown author is empty", edit.current({ author = "Unknown", authors = { "Unknown" } }, "authors"), "")
eq("add tag keeps the others", edit.resolve(book, "tags", "add", "cs"), "cs, math/algebra, x")
eq("add existing tag", edit.resolve(book, "tags", "add", "X"), "X, math/algebra")
eq("remove tag", edit.resolve(book, "tags", "remove", "x"), "math/algebra")
eq("set tags", edit.resolve(book, "tags", "set", "b, a"), "a, b")
eq("add identifier replaces its type", edit.resolve(book, "identifiers", "add", "doi:10.2/b"), "doi:10.2/b, isbn:123")
eq("remove identifier by type", edit.resolve(book, "identifiers", "remove", "isbn"), "doi:10.1/a")
eq("authors keep their order", edit.resolve(book, "authors", "set", "Z Last; A First"), "Z Last & A First")
eq("add author", edit.resolve(book, "authors", "add", "C Three"), "A One & B Two & C Three")
eq("year becomes a date", edit.resolve(book, "pubdate", "set", "1999"), "1999-01-01")
eq("bad date", (pcall(edit.resolve, book, "pubdate", "set", "July")), false)
eq("bad identifier", (pcall(edit.resolve, book, "identifiers", "add", "1999")), false)
eq("title has no add", (pcall(edit.resolve, book, "title", "add", "x")), false)
eq("resolve from text", edit.resolve_from("a, b", "tags", "add", "c"), "a, b, c")

-- bibtex
local bib = require "lulibre.bib"
eq("last, first", bib.last_first("Jean-Pierre Serre"), "Serre, Jean-Pierre")
eq("particles", bib.last_first("Gerard van der Geer"), "van der Geer, Gerard")
eq("corporate author", bib.last_first("The Sage Development Team"), "{The Sage Development Team}")
local parsed = bib.parse([[
@article{key1, title = {A {Nested} Title}, author = "Lang, Serge and Tate, John", year = 1999,
  doi = {10.1/x} }
@comment{ignored}
@book{key2,
  title = {Second \& Last},
}]])
eq("bib entries", #parsed, 2)
eq("bib fields", { parsed[1].type, parsed[1].key, parsed[1].fields.title, parsed[1].fields.year, parsed[1].fields.doi },
  { "article", "key1", "A Nested Title", "1999", "10.1/x" })
eq("bib people", bib.people(parsed[1].fields.author), { "Serge Lang", "John Tate" })
eq("bib unescape", parsed[2].fields.title, "Second & Last")

-- online lookups: only the part that needs no network
eq("same title", require("lulibre.net").same_title("Detecting perfect powers by factoring into coprimes",
  "Detecting Perfect Powers by Factoring into Coprimes."), true)
eq("different title", require("lulibre.net").same_title("Algebra", "Linear Algebra Done Right"), false)

-- lulibre's own tables
lulibre.store("INSERT OR REPLACE INTO kv(key, value) VALUES('unit-test', ?)", "v1")
eq("store round trip", lulibre.store("SELECT value FROM kv WHERE key = 'unit-test'")[1].value, "v1")
lulibre.store("DELETE FROM kv WHERE key = 'unit-test'")
eq("store cannot touch the mirror", (pcall(lulibre.store, "DELETE FROM books")), false)
eq("store cannot change the schema", (pcall(lulibre.store, "DROP TABLE kv")), false)

-- the API, on whatever library is configured
eq("count is a number", type(lulibre.count("")), "number")
eq("ids agrees with count", #lulibre.ids("author:unknown"), lulibre.count("author:unknown"))
eq("bad filter raises", (pcall(lulibre.ids, "nosuchfield:1")), false)
eq("sql is read-only", (pcall(lulibre.sql, "delete from books")), false)
eq("fold", lulibre.fold("Erdős"), "erdos")
eq("fuzzy miss", lulibre.fuzzy("xyz", "abc"), nil)

-- tasks: a computation does not starve a timer
local ticks = 0
lulibre.spawn(function() for _ = 1, 4 do lulibre.sleep(10); ticks = ticks + 1 end end)
local t0 = os.clock()
while os.clock() - t0 < 0.1 do end
eq("preempted busy loop let the timer task run", ticks >= 3, true)
local r = lulibre.system({ "sh", "-c", "cat; echo err >&2; exit 3" }, { stdin = "in" })
eq("system", { r.code, r.stdout, r.stderr }, { 3, "in", "err\n" })
eq("system timeout", lulibre.system({ "sleep", "5" }, { timeout = 50 }).timed_out, true)
eq("system missing", (lulibre.system({ "/no/such/program" })), nil)
local ok, uv = pcall(require, "luv")
if ok then
  local fired = false
  local timer = uv.new_timer()
  timer:start(10, 0, function() fired = true; timer:close() end)
  lulibre.sleep(40)
  eq("luv runs on the host loop", fired, true)
  eq("lulibre.uv is luv", lulibre.uv, uv)
else
  print("skip  luv checks (luv is not installed for this Lua version)")
end


-- content hashes
do
  local dir = os.tmpname()
  os.remove(dir)
  local function write(name, data)
    local f = assert(io.open(dir .. name, "wb"))
    f:write(data)
    f:close()
    return dir .. name
  end
  eq("md5 of nothing", lulibre.md5(write("-a", "")), "d41d8cd98f00b204e9800998ecf8427e")
  eq("md5 abc", lulibre.md5(write("-b", "abc")), "900150983cd24fb0d6963f7d28e17f72")
  eq("md5 across a block boundary", lulibre.md5(write("-c", ("1234567890"):rep(8))),
    "57edf4a22be3c955ac49da2e2107b67a")
  eq("md5 of a megabyte", lulibre.md5(write("-d", ("a"):rep(1000000))), "7707d6ae4e027c70eea2a935c2296f21")
  eq("md5 again comes from the cache", lulibre.md5(dir .. "-d"), "7707d6ae4e027c70eea2a935c2296f21")
  write("-d", ("a"):rep(999999) .. "b")
  eq("md5 notices a changed file", lulibre.md5(dir .. "-d") ~= "7707d6ae4e027c70eea2a935c2296f21", true)
  eq("md5 of a missing file", (lulibre.md5(dir .. "-nope")), nil)
  for _, n in ipairs { "-a", "-b", "-c", "-d" } do os.remove(dir .. n) end
end

-- lulibre.each: every item exactly once, however the tasks interleave
do
  local items, seen = {}, {}
  for i = 1, 500 do items[i] = i end
  lulibre.each(items, function(v)
    local x = 0
    for _ = 1, 2000 do x = x + 1 end -- long enough to be preempted now and then
    table.insert(seen, v)
  end, { jobs = 8 })
  table.sort(seen)
  eq("each ran every item once", { #seen, seen[1], seen[250], seen[500] }, { 500, 1, 250, 500 })
  eq("each raises the first error", (pcall(lulibre.each, { 1, 2, 3 }, function() error("no") end)), false)
end

-- editing: typed values, series index
do
  local edit = require "lulibre.edit"
  eq("typed replaces", edit.typed(7, "title", "New"), { { id = 7, field = "title", value = "New", op = "set" } })
  eq("typed adds and removes", edit.typed(7, "tags", "+a/b, -c"),
    { { id = 7, field = "tags", value = "a/b", op = "add" }, { id = 7, field = "tags", value = "c", op = "remove" } })
  local book = { title = "T", author = "A", tags = {}, idents = {}, series = "S", series_index = 3.0 }
  eq("series index shown plainly", edit.current(book, "series_index"), "3")
  eq("series index normalised", edit.resolve(book, "series_index", "set", " 10.50 "), "10.5")
  eq("series index must be a number", (pcall(edit.resolve, book, "series_index", "set", "ten")), false)
  book.series = nil
  eq("no series, no index", edit.current(book, "series_index"), "")
end

-- BibTeX in: files, corporate authors, metadata
do
  local bib = require "lulibre.bib"
  local e = bib.parse([[
@incollection{stacks-algebra,
  author = {{The Stacks project authors}},
  title = {Commutative Algebra}, series = {Stacks Project}, number = {10},
  date = {2026-07-28}, year = {2026}, keywords = {math/algebraic-geometry, math/algebra},
  url = {https://stacks.math.columbia.edu/download/algebra.pdf},
  file = {algebra.pdf},
}
@book{k, author = {Knuth, Donald E. and {Free Software Foundation}}, title = {T}, year = 1984,
  doi = {https://doi.org/10.1000/X}, file = {Full Text:/a/b c.pdf:application/pdf;:rel/d.pdf:PDF}}
]])
  eq("bib entries", #e, 2)
  local m = bib.metadata(e[1])
  eq("bib corporate author stays whole", m.authors, "The Stacks project authors")
  eq("bib series, index, date, tags", { m.series, m.series_index, m.pubdate, m.tags },
    { "Stacks Project", "10", "2026-07-28", "math/algebraic-geometry, math/algebra" })
  eq("bib url identifier", m.identifiers, { "url:https://stacks.math.columbia.edu/download/algebra.pdf" })
  eq("bib plain file, relative", bib.files(e[1], "/x/y"), { "/x/y/algebra.pdf" })
  local m2 = bib.metadata(e[2])
  eq("bib people", m2.authors, "Donald E. Knuth & Free Software Foundation")
  eq("bib year and doi", { m2.pubdate, m2.identifiers[1] }, { "1984", "doi:10.1000/X" })
  eq("bib zotero and jabref files", bib.files(e[2], "/x"), { "/a/b c.pdf", "/x/rel/d.pdf" })
end

-- duplicates: which copy is kept
do
  local dupes = require "lulibre.dupes"
  local bare = { title = "untitled3", author = "Unknown", tags = {}, idents = {} }
  local rich = { title = "Knots and Links", author = "Ann Lee", tags = { "math/topology" }, idents = { doi = "10.1/x" }, year = 2004 }
  eq("richer record scores higher", dupes.score(rich) > dupes.score(bare), true)
  local groups = { { keep = 2, books = { { id = 2, title = "A B", author = "X", tags = {}, idents = {} },
    { id = 5, title = "a", author = "Unknown", tags = { "t/u" }, idents = { isbn = "9" }, publisher = "P" } } } }
  eq("surplus is everything but the kept copy", dupes.surplus(groups), { 5 })
  local carried = {}
  for _, c in ipairs(dupes.gather(groups)) do carried[#carried + 1] = c.field .. " " .. c.op .. " " .. c.value end
  eq("gather carries what the kept copy lacks", carried, { "tags add t/u", "publisher set P", "identifiers add isbn:9" })
  groups[1].skip = true
  eq("a skipped group loses nothing", dupes.surplus(groups), {})
end

-- colours
do
  local was = lulibre.theme.border
  lulibre.theme.border = "#102030"
  eq("theme set by string", lulibre.theme.border, "#102030")
  lulibre.theme.border = 0xa0b0c0
  eq("theme set by number", lulibre.theme().border, "#a0b0c0")
  eq("theme rejects nonsense", (pcall(function() lulibre.theme.border = "blue" end)), false)
  eq("theme rejects unknown names", (pcall(function() lulibre.theme.nope = "#000000" end)), false)
  lulibre.theme.border = was
end

-- options that only take certain values, and what they decide
do
  eq("a policy option rejects other values", (pcall(function() lulibre.o.repair_links = "sometimes" end)), false)
  local was = lulibre.o.carry_metadata
  lulibre.o.carry_metadata = "auto"
  eq("policy auto", lulibre.policy("carry_metadata", "?"), true)
  lulibre.o.carry_metadata = "never"
  eq("policy never", lulibre.policy("carry_metadata", "?"), false)
  lulibre.o.carry_metadata = "ask"
  eq("policy ask, with nobody to ask", lulibre.policy("carry_metadata", "?"), false)
  lulibre.o.carry_metadata = was
  eq("filters default to the library", lulibre.source(), "library")
  eq("no staged file has a positive id", #lulibre.sql("SELECT 1 FROM books WHERE id < 0 AND id IN (SELECT id FROM books WHERE id > 0)"), 0)
  eq("in:sync and in:library partition in:all", lulibre.count("in:sync") + lulibre.count("in:library"), lulibre.count("in:all"))
  eq("an unknown scope is an error", (pcall(lulibre.count, "in:nowhere")), false)
end

-- version, build, log
do
  eq("version is a semantic version", lulibre.version:match("^%d+%.%d+%.%d+[-%w.]*$") ~= nil, true)
  local b = lulibre.build
  eq("build repeats it", b.version, lulibre.version)
  eq("build has its parts", ("%d.%d.%d"):format(b.major, b.minor, b.patch) .. (b.pre ~= "" and "-" .. b.pre or ""),
    lulibre.version)
  eq("build says what kind it is", type(b.debug), "boolean")
  eq("log takes a level", (pcall(lulibre.log, "from the unit checks", "info")), true)
  eq("log refuses an unknown level", (pcall(lulibre.log, "x", "loud")), false)
  eq("log defaults to info", (pcall(lulibre.log, "plain")), true)
  local edit = require "lulibre.edit"
  if pcall(require, "luv") then -- without luv it cannot tell, and says so by answering true
    eq("server_up: nothing listens on a closed port", edit.server_up("http://127.0.0.1:1"), false)
    eq("server_up: nonsense is not a server", edit.server_up("not a url"), false)
  end
end

-- settings
do
  local S = lulibre.settings
  eq("settings.get", S.get("layout_pages"), lulibre.o.layout_pages)
  S.set("ocr_pages", 7)
  eq("settings.set", { S.get("ocr_pages"), lulibre.o.ocr_pages }, { 7, 7 })
  S.set { ocr_pages = 4, ocr_lang = "deu" }
  eq("settings.set with a table", { S.get("ocr_pages"), S.get("ocr_lang") }, { 4, "deu" })
  S.reset("ocr_pages")
  S.reset("ocr_lang")
  eq("settings.reset", { S.get("ocr_pages"), S.get("ocr_lang") }, { 3, "eng" })
  eq("settings.get() has every option", S.get().write_via, "auto")
  local names = S.names()
  eq("settings.names lists them in order", { names[1], #names > 20 }, { "library", true })
  local info = S.info("repair_links")
  eq("settings.info", { info.type, info.default, info.choices, info.help ~= "" },
    { "string", "ask", { "auto", "ask", "never" }, true })
  eq("settings.info of a number", { S.info("pages").type, S.info("pages").default }, { "number", 6 })
  eq("unknown options are errors", { (pcall(S.get, "nope")), (pcall(S.set, "nope", 1)), (pcall(S.info, "nope")) },
    { false, false, false })
  eq("a refused value changes nothing", { (pcall(S.set, "write_via", "carrier pigeon")), S.get("write_via") },
    { false, "auto" })

  -- the configuration directory can be read, and moved
  local was = S.get("config_dir")
  eq("config_dir reads as the directory in effect", was:sub(1, 1) == "/" and was:find("lulibre") ~= nil, true)
  local paths = S.paths()
  eq("paths follow it", { paths.config_dir, paths.init, paths.scripts }, { was, was .. "/init.lua", was .. "/scripts" })
  eq("paths names the index", paths.index:match("%.db$") ~= nil, true)
  local has_luv, uv = pcall(require, "luv")
  if not has_luv then goto no_luv end
  local dir = os.tmpname()
  os.remove(dir)
  uv.fs_mkdir(dir, 448)
  uv.fs_mkdir(dir .. "/lua", 448)
  local f = assert(io.open(dir .. "/lua/unit_probe.lua", "w"))
  f:write("return { answer = 42 }\n")
  f:close()
  S.set("config_dir", dir)
  eq("config_dir can be set", { S.get("config_dir"), lulibre.o.config_dir, S.paths().scripts }, { dir, dir, dir .. "/scripts" })
  eq("modules are then found there", require("unit_probe").answer, 42)
  S.reset("config_dir")
  eq("and reset", S.get("config_dir"), was)
  os.remove(dir .. "/lua/unit_probe.lua")
  uv.fs_rmdir(dir .. "/lua")
  uv.fs_rmdir(dir)
  ::no_luv::
end

-- cover sheets that label their fields
do
  local lab = titlepage.labelled {
    "What is an Answer?", "Author(s): Herbert S. Wilf",
    "Source: The American Mathematical Monthly, Vol. 89, No. 5 (May, 1982), pp. 289-292",
    "Published by: Mathematical Association of America", "Stable URL: http://www.jstor.org/stable/2321713 .",
    "Accessed: 21/01/2015 04:38",
  }
  eq("labelled cover sheet", { lab.title, lab.authors, lab.year, lab.publisher, lab.jstor, lab.labels },
    { "What is an Answer?", { "Herbert S. Wilf" }, "1982", "Mathematical Association of America", "2321713", 4 })
  local two = titlepage.labelled { "A Long Title That Runs", "onto a Second Line", "Author(s): A. One and B. Two", "Source: J. Thing, 2001" }
  eq("labelled: wrapped title, two authors", { two.title, two.authors }, { "A Long Title That Runs onto a Second Line", { "A. One", "B. Two" } })
  eq("no author label, no cover sheet", titlepage.labelled { "A Title", "by Somebody", "Source: nowhere" }, nil)
  local cands = require("lulibre.extract").from_doc { lines = {
    { text = "What is an Answer?", size = 11, x0 = 72, y0 = 100, x1 = 300, y1 = 112 },
    { text = "Author(s): Herbert S. Wilf", size = 11, x0 = 72, y0 = 114, x1 = 300, y1 = 126 },
    { text = "Source: The American Mathematical Monthly, Vol. 89, No. 5 (May, 1982), pp. 289-292", size = 11,
      x0 = 72, y0 = 128, x1 = 500, y1 = 140 } }, text = "" }
  local best = {}
  for _, c in ipairs(cands) do best[c.field] = best[c.field] or c end
  eq("a labelled author is trusted", { best.authors.value, best.authors.confidence >= 0.9, best.pubdate.value },
    { "Herbert S. Wilf", true, "1982" })
end

-- thesis cover pages, by rule (works on OCR text: no font sizes needed)
do
  local th = titlepage.thesis {
    "ON THE STRUCTURE OF", "FINITE WIDGETS", "by", "Jane Q. Roe",
    "B.S., Some State University (1961)", "Submitted in partial fulfillment of the requirements",
    "for the degree of", "Doctor of Philosophy in Mathematics", "at the",
    "MASSACHUSETTS INSTITUTE OF TECHNOLOGY", "June, 1968", "Certified by", "Arthur B. Guide", "Thesis Supervisor",
  }
  eq("thesis: title and author either side of by", { th.title, th.authors }, { "ON THE STRUCTURE OF FINITE WIDGETS", { "Jane Q. Roe" } })
  eq("thesis: degree, program, year", { th.degree, th.program, th.year }, { "Doctor of Philosophy", "Mathematics", "1968" })
  eq("thesis: institution, advisor", { th.institution, th.advisor }, { "MASSACHUSETTS INSTITUTE OF TECHNOLOGY", "Arthur B. Guide" })
  local vt = titlepage.thesis {
    "Soil Moisture and Yield", "by John Smith", "Dissertation submitted to the Faculty of the",
    "Virginia Polytechnic Institute and State University", "in partial fulfillment of the requirements for the degree of",
    "MASTER OF SCIENCE", "in", "Agronomy", "APPROVED:", "R. T. Chair, Chairman", "August 1974", "Blacksburg, Virginia",
  }
  eq("thesis: by on the author's line", { vt.title, vt.authors, vt.year }, { "Soil Moisture and Yield", { "John Smith" }, "1974" })
  eq("thesis: faculty of the", vt.institution, "Virginia Polytechnic Institute and State University")
  eq("an article is not a thesis", titlepage.thesis { "A Note on Sieves", "by", "P. Erdos", "Received May 1950" }, nil)
end

-- indexing from a script
do
  local r = lulibre.index()
  eq("index returns what it did", { type(r.files), type(r.ok), type(r.seconds), r.failed }, { "number", "number", "number", 0 })
  local again = lulibre.index { force = true }
  eq("force reads every file again", again.ok, again.files - again.missing)
  local one = lulibre.index { filter = "id:1", force = true }
  eq("a filter limits the run", one.files, #lulibre.files(1))
  eq("a bad filter is an error, not a hang", (pcall(lulibre.index, { filter = "nosuch:field" })), false)
end

-- title case (APA) and case beyond ASCII
do
  local tc = require "lulibre.titlecase"
  eq("minor words stay small, subtitles start again", tc.apply("ON THE THEORY OF GROUPS: AN INTRODUCTION"),
    "On the Theory of Groups: An Introduction")
  eq("four letters or more are capitalised", tc.apply("ALGEBRA WITH GALOIS THEORY FROM THE START"),
    "Algebra With Galois Theory From the Start")
  eq("hyphens: major words, and after a prefix", tc.apply("SELF-REPORT MEASURES IN MID-YEAR ANTI-HERO STUDIES"),
    "Self-Report Measures in Mid-year Anti-hero Studies")
  eq("numerals, initialisms and known spellings survive capitals", tc.apply("PDE AND NMR METHODS, VOL. II, 3D CASE"),
    "PDE and NMR Methods, Vol. II, 3D Case")
  eq("accented letters", tc.apply("ÉTUDE SUR LES ÉQUATIONS"), "Étude Sur Les Équations")
  eq("possessives and O'", tc.apply("HILBERT'S PROBLEMS AND O'NEIL"), "Hilbert's Problems and O'Neil")
  eq("capitals put there on purpose are kept", tc.apply("an introduction to LaTeX and McKean's PDE"),
    "An Introduction to LaTeX and McKean's PDE")
  eq("a capitalised minor word is lowered", tc.apply("What Is An Answer?"), "What Is an Answer?")
  eq("is_caps", { tc.is_caps("SIEVE METHODS"), tc.is_caps("Sieve Methods"), tc.is_caps("A"), tc.is_caps("1234") },
    { true, false, false, false })
  tc.minor["with"] = true
  eq("the minor words can be added to", tc.apply("ALGEBRA WITH GALOIS THEORY"), "Algebra with Galois Theory")
  tc.minor["with"] = nil
  eq("lulibre.titlecase", lulibre.titlecase("A NOTE ON SIEVES"), "A Note on Sieves")
  eq("lower and upper know more than ASCII", { lulibre.lower("ÉCOLE ΑΒΓ ЖЗ"), lulibre.upper("école αβγ жз") },
    { "école αβγ жз", "ÉCOLE ΑΒΓ ЖЗ" })
  eq("proposed: only what came in capitals", { tc.proposed("A NOTE ON SIEVES"), tc.proposed("A note on sieves") },
    { "A Note on Sieves", "A note on sieves" })
  lulibre.o.title_case = "never"
  eq("and not when the option says never", tc.proposed("A NOTE ON SIEVES"), "A NOTE ON SIEVES")
  lulibre.o.title_case = "auto"
  local ex = require "lulibre.extract"
  local got
  for _, c in ipairs(ex.from_doc { title = "LECTURES ON RIEMANN SURFACES", pages = {} }) do
    if c.field == "title" then got = c.value end
  end
  eq("a title found in capitals is suggested in title case", got, "Lectures on Riemann Surfaces")
end

-- proposing for a field that already has a value
do
  local propose = require "lulibre.propose"
  local proposals = require "lulibre.proposals"
  eq("same: quotes, case and punctuation do not matter",
    propose.same("title", 'On Riemann\'s Paper, "On the Number"', "On Riemann’s paper, “on the number”"), true)
  eq("same: authors as a set", propose.same("authors", "A. One & B. Two", "B. Two & A. One"), true)
  eq("same: the same people named less fully say nothing new", { propose.same("authors", "Sérgio Joffily", "S. Joffily"),
    propose.same("authors", "Todd K. Timberlake & Jeffery M. Tucker", "Todd Timberlake & Jeffery Tucker"),
    propose.same("authors", "Adrian W. Dudek", "Adrian Dudek") }, { true, true, true })
  eq("named more fully they do", { propose.same("authors", "P. Selinger", "Peter Selinger"),
    propose.same("authors", "R. Taylor", "Richard Taylor") }, { false, false })
  eq("another person is another person", { propose.same("authors", "P. Selinger", "Q. Selinger"),
    propose.same("authors", "Peter Selinger", "Paul Selinger"), propose.same("authors", "A. One", "A. One & B. Two") }, { false, false, false })
  eq("same: a hyphen is a hyphen however it is drawn", { propose.same("authors", "Eric Vanden‐Eijnden", "Eric Vanden-Eijnden"),
    propose.same("title", "Erdős–Kac theorems", "Erdős-Kac Theorems"), propose.same("title", "Zipf’s Law", "Zipf's law") }, { true, true, true })
  eq("same: a bare year offered against a date in that year", propose.same("pubdate", "1996-05-01", "1996"), true)
  eq("but a full date offered against a bare year is news", propose.same("pubdate", "2010-01-01", "2010-12-29"), false)
  eq("not the same", { propose.same("authors", "Bernhard Riemann", "W. Dittrich"), propose.same("pubdate", "2017-08-03", "2016") },
    { false, false })
  local book = lulibre.book(2) -- Notes, by Paul Erdős, 1996
  local cands = {
    { field = "authors", value = "P. Turan", source = "title page", confidence = 0.85 },
    { field = "authors", value = "Somebody Else", source = "embedded", confidence = 0.6 },
    { field = "publisher", value = "Acme", source = "title page", confidence = 0.55 },
    { field = "title", value = "notes", source = "embedded", confidence = 0.6 },
  }
  local function fields(mode)
    local out = {}
    for _, w in ipairs(propose.wanted(book, cands, mode)) do out[#out + 1] = w.field .. (w.over and "!" or "") end
    return table.concat(out, " ")
  end
  eq("gaps: only what is empty", fields("gaps"), "publisher")
  eq("sure: also a confident candidate that differs, the strongest only", fields("sure"), "authors! publisher")
  eq("any: the same here, since the title agrees", fields("any"), "authors! publisher")
  cands[1].confidence = 0.6
  eq("sure: a weak candidate does not go over a value", fields("sure"), "publisher")
  eq("any: it does", fields("any"), "authors! publisher")
  -- one field at a time, and as if the fields were empty
  eq("--only takes names or letters", { propose.fields("title,ids"), propose.fields("t a d"), (propose.fields("t,nosuch")) },
    { { identifiers = true, title = true }, { authors = true, pubdate = true, title = true } })
  cands[1].confidence = 0.6
  local function fresh(o)
    local out = {}
    for _, w in ipairs(propose.wanted(book, cands, o)) do out[#out + 1] = w.field .. (w.over and "!" or "") end
    return table.concat(out, " ")
  end
  eq("fresh: the file's reading of every field, whatever the book says", fresh { fresh = true }, "authors! publisher")
  eq("only: kept to the fields named", { fresh { fresh = true, only = { publisher = true } }, fresh { only = { authors = true }, over = "any" } },
    { "publisher", "authors!" })
  -- one word may be a title: a plain capitalised word is, what is left of a file name is not
  eq("Algebra and Topology are titles; infinite and E807en are not", { junk.unlikely_title("Algebra"), junk.unlikely_title("Topology"),
    junk.unlikely_title("ALGEBRA"), junk.unlikely_title("Élasticité"), junk.unlikely_title("infinite"), junk.unlikely_title("E807en"),
    junk.unlikely_title("wilf.dvi"), junk.unlikely_title("tensorprod"), junk.unlikely_title("Dune"), junk.unlikely_title("Set"),
    junk.unlikely_title("Lambda-Rings") }, { false, false, false, false, true, true, true, true, false, true, false })
  lulibre.o.one_word_titles = "junk"
  eq("one_word_titles = junk: none of them is", { junk.unlikely_title("Algebra"), junk.unlikely_title("A Course in Arithmetic") }, { true, false })
  lulibre.o.one_word_titles = "ok"
  eq("one_word_titles = ok: any single word is, a file name still is not", { junk.unlikely_title("infinite"), junk.unlikely_title("wilf.dvi"),
    junk.unlikely_title("417675") }, { false, true, true })
  lulibre.o.one_word_titles = "check"
  lulibre.o.good_titles = "Set, 1984, infinite"
  eq("good_titles vouches for a title whatever it looks like", { junk.unlikely_title("Set"), junk.unlikely_title("1984"),
    junk.unlikely_title("Infinite"), junk.title("1984"), junk.unlikely_title("1985") }, { false, false, false, false, true })
  lulibre.o.good_titles = ""
  do
    local quality = require "lulibre.quality"
    eq("a title that looks like junk is a gap", propose.is_gap("title", "infinite", 2), true)
    quality.set_good({ 2 }, true)
    eq("but not in a record confirmed as good", { propose.is_gap("title", "infinite", 2), propose.is_gap("authors", "libgen.li", 2),
      propose.is_gap("title", "", 2) }, { false, false, true })
    quality.set_good({ 2 }, false)
  end
  eq("what is plainly no value is a gap", { propose.is_gap("title", "417675"), propose.is_gap("title", "annals-v163-n3-p05"),
    propose.is_gap("title", "2019 44 31 x"), propose.is_gap("title", "A Course in Arithmetic"), propose.is_gap("authors", "libgen.li"),
    propose.is_gap("authors", "Professor Emeritus"), propose.is_gap("authors", "Jean-Pierre Serre"), propose.is_gap("authors", "") },
    { true, true, true, false, true, true, false, true })
  -- a rejection is remembered
  local ok, pid = proposals.add(2, "publisher", "Rejected House", { source = "test", confidence = 0.9 })
  eq("a proposal is added", ok, true)
  proposals.set_status(pid, "rejected")
  eq("what was rejected is not proposed again", proposals.add(2, "publisher", "Rejected House", { source = "test" }), false)
  eq("unless asked to", (proposals.add(2, "publisher", "Rejected House", { source = "test", again = true })), true)
  eq("replaces: a value over a value", { proposals.replaces { book = 2, field = "authors", op = "set" },
    proposals.replaces { book = 2, field = "publisher", op = "set" }, proposals.replaces { book = 2, field = "tags", op = "add" } },
    { true, false, false })
  lulibre.store("DELETE FROM proposals WHERE book = 2 AND field = 'publisher'")
end

-- by-lines
do
  eq("by A. Name", titlepage.byline("By David Foster Wallace"), "David Foster Wallace")
  eq("capitals, a footnote mark", titlepage.byline("By ANDREW WILES*"), "ANDREW WILES")
  eq("surname first", { titlepage.byline("by RIBET, K. A."), titlepage.byline("by Deligne, Pierre; Ribet, Kenneth A.") },
    { "K. A. RIBET", "Pierre Deligne; Kenneth A. Ribet" })
  eq("what trails the name is dropped", { titlepage.byline("by Ursula K LeGuin - from The Wind's Twelve Quarters"),
    titlepage.byline("by Torbjorn Granlund and the GMP development team"), titlepage.byline("by Emil Artin:") },
    { "Ursula K LeGuin", "Torbjorn Granlund", "Emil Artin" })
  eq("by alone: the names are on the next line", titlepage.byline("  BY "), "")
  eq("a sentence that begins with by is not a by-line", { titlepage.byline("by Gauss in 1801 in his book Disquisitiones"),
    titlepage.byline("by I.R. Shafarevich [130]. This proof is"), titlepage.byline("by University of Arizona Library user"),
    titlepage.byline("By General Stream of Consciousness we mean"), titlepage.byline("Bylaws of the Society") }, {})
  local function line(text, size) return { text = text, size = size } end
  local got = titlepage.classify { line("THE DEPRESSED PERSON", 20), line("By David Foster Wallace", 12), line("The depressed person was in terrible pain.", 10) }
  eq("a by-line under the title names the author", { got.title, got.authors, got.byline },
    { "THE DEPRESSED PERSON", { "David Foster Wallace" }, true })
  got = titlepage.classify { line("AN INTRODUCTION TO SOMETHING", 18), line("by", 18), line("Jane Q. Public", 14), line("Abstract", 10) }
  eq("by on a line of its own, as large as the title", { got.title, got.authors, got.byline },
    { "AN INTRODUCTION TO SOMETHING", { "Jane Q. Public" }, true })
  local authors
  for _, c in ipairs(require("lulibre.extract").from_doc { lines = { line("HARMONIC ANALYSIS", 18), line("BY GEORGE W. MACKEY", 11) } }) do
    if c.field == "authors" then authors = c end
  end
  eq("and is proposed with the page's word for it", { authors.value, authors.source, authors.confidence },
    { "George W. Mackey", "by-line", 0.85 })
end

-- who is not an author, and a page that opens with its author's name
do
  eq("ranks and roles are never authors", { names.never("Professor Emeritus"), names.never("Lecture Notes"),
    names.never("David Mumford"), names.never("John Dean") }, { true, true, false, false })
  eq("so they are not names", { names.clean("Professor Emeritus"), names.clean("David Mumford") }, { nil, "David Mumford" })
  -- words that are a rank in one place and a name in another stay names
  eq("Dean, Senior, Reader, Fellow and Chair are people's names", { names.never("Dean Koontz"), names.never("Mary Senior"),
    names.never("John Reader"), names.never("Anne Fellow"), names.clean("W. Reader"), names.clean("Dean Rickles") },
    { false, false, false, false, "W. Reader", "Dean Rickles" })
  lulibre.o.never_authors = "visiting scholar, Brown and Harvard"
  eq("the option adds to them", { names.never("Brown and Harvard Universities"), names.never("Harvard Brown") }, { true, false })
  lulibre.o.never_authors = ""
  eq("a person on more than shape: an initial, a given name, an e-mail", { names.is_person("Sidney A. Morris"),
    names.is_person("David Mumford"), names.is_person("Xu Zhang", "write to x.zhang@example.org"), names.is_person("Hopf Algebras"),
    names.is_person("Delta Lake") }, { true, true, true, false, false })
  local function line(text, size) return { text = text, size = size } end
  local page = {
    line("David Mumford", 23.8), line("Archive for Reprints,", 16.8), line("Notes, Talks, and Blog", 16.8),
    line("Professor Emeritus", 12.5), line("Brown and Harvard Universities", 12.5), line("David_Mumford@brown.edu", 12.6),
    line("Finding the Rhythms of the Primes", 20), line("October 30, 2014", 11.7),
    line("Barry Mazur and William Stein are writing an excellent book entitled", 13.2),
    line("What is Riemann's Hypothesis? The book leads up to Riemann's", 13.2),
    line("explicit formula which, in von Mangoldt's form, is the formula for the", 13.2),
  }
  local got = titlepage.classify(page)
  eq("the name on the first line is the author, the next largest line the title",
    { got.authors, got.title, got.name_first }, { { "David Mumford" }, "Finding the Rhythms of the Primes", true })
  local text = {}
  for i, l in ipairs(page) do text[i] = l.text end
  local authors
  for _, c in ipairs(require("lulibre.extract").from_doc { lines = page, text = table.concat(text, "\n") }) do
    if c.field == "authors" then authors = authors or c end
  end
  eq("proposed as such, surer for being on the page twice", { authors.value, authors.source, authors.confidence },
    { "David Mumford", "first line, named twice", 0.85 })
  got = titlepage.classify { line("Hopf Algebras", 22), line("Miriam Cohen", 14), line("An introduction", 16), line("text text text", 10) }
  eq("a title of two capitalised words is not taken for a name", { got.title, got.name_first }, { "Hopf Algebras" })
  got = titlepage.classify { line("Introduction to", 26.6), line("Commutative Algebra", 35.6), line("M. F. ATIYAH, Frs", 13),
    line("UNIVERSITY OF OXFORD", 7.6) }
  eq("a title may begin with Introduction, and with a smaller line that leads into it", { got.title, got.authors },
    { "Introduction to Commutative Algebra", { "M. F. ATIYAH" } })
  got = titlepage.classify { line("ON THE LOGARITHMS OF", 10), line("NEGATIVE AND IMAGINARY NUMBERS", 10), line("Leonhard Euler", 10),
    line("1. In the exchange of letters between Messrs. Leibnitz and Jean Bernoulli, we find", 10),
    line("a great controversy over the logarithms of negative and imaginary numbers.", 10), line("more text here", 10) }
  eq("a page in one size: the capitals at the top are the title, the name under them the author", { got.title, got.authors },
    { "ON THE LOGARITHMS OF NEGATIVE AND IMAGINARY NUMBERS", { "Leonhard Euler" } })
  eq("a title before a name is taken off it", { names.clean("Professor Karen E. Smith"), names.never("Professor Karen E. Smith"),
    names.never("Professor Emeritus"), names.never("Professor") }, { "Karen E. Smith", false, true, true })
end

-- how far a record can be trusted, and the ones confirmed
do
  local quality = require "lulibre.quality"
  local full = { title = "A Course in Arithmetic", author = "Jean-Pierre Serre", authors = { "Jean-Pierre Serre" },
    tags = { "math/number-theory" }, year = 1973, idents = { isbn = "9780387900407" }, publisher = "Springer" }
  eq("a complete record scores 1", (quality.score(full)), 1)
  local s, why = quality.score { title = "S0025-5718-1975-0376583-0", author = "Unknown", authors = {}, tags = {}, idents = {} }
  eq("a file name for a title and nothing else scores 0", { s, why[1] }, { 0, "the title looks like a file name or a heading" })
  s, why = quality.score { title = "Notes on Sieves", author = "P. Erdos", authors = { "P. Erdos" }, tags = { "math/general" },
    year = 1950, idents = {} }
  eq("a catch-all subject counts for little", { s < 0.85, table.concat(why, "; "):find("catch%-all") ~= nil }, { true, true })
  eq("which subjects are catch-alls", { quality.catchall("math/general"), quality.catchall("linguistics/papers"),
    quality.catchall("math/number-theory") }, { true, true, false })
  lulibre.o.subject_catchall = "to-read"
  eq("the option adds to them", quality.catchall("math/to-read"), true)
  lulibre.o.subject_catchall = ""
  eq("odd characters and figures pull a title down",
    (quality.score { title = "x__[3]==|| 2019 44 31", author = "A. Name", authors = { "A. Name" }, tags = {}, idents = {} }) < 0.3, true)
  quality.set_good({ 2 }, true)
  eq("a record can be confirmed", { quality.is_good(2), quality.is_good(1), quality.good_ids(), lulibre.count("is:good") }, { true, false, { 2 }, 1 })
  local ranked = quality.ranked { good = true }
  eq("ranked lists them with their scores", { #ranked, ranked[1].book.id, ranked[1].good }, { 1, 2, true })
  quality.set_good({ 2 }, false)
  eq("and unconfirmed", quality.is_good(2), false)
end

-- phrases, and what is learned from them
do
  local t = "The ring of integers of a number field is a Dedekind domain. Class field theory (of the\nring of inte-\ngers); x2 breaks it. Modular forms and elliptic curves."
  eq("the phrases of a text: within a clause, no function word at either end, a broken word joined",
    lulibre.phrases(t), { "ring of integers", "number field", "dedekind domain", "class field", "class field theory",
      "field theory", "modular forms", "forms and elliptic", "elliptic curves" })
  eq("words of the trade make no phrases, words that only look like them do",
    lulibre.phrases("All rights reserved. Copyright Springer Verlag. Power series over a number field."),
    { "power series", "number field" })
  eq("symbols and other scripts end a clause", lulibre.phrases("zeta · function ∞ random matrix"), { "random matrix" })
  local c = lulibre.counter()
  c:add(t)
  c:add("Elliptic curves over a number field. Modular forms again, modular forms.")
  c:add("nothing of note here")
  eq("a counter counts texts, not mentions", { c:texts(), c:count("modular forms"), c:count("ring of integers"), c:count("no such") },
    { 3, 2, 1, 0 })
  eq("prune forgets the rare", { c:prune(2), c:of("On modular forms and the ring of integers of a number field") },
    { 3, { "modular forms", "number field" } })
  local lines = lulibre.counter()
  for i = 1, 3 do
    lines:add_lines("No part of this publication may be reproduced in any form\nwithout permission.\nBook " .. i .. " is about something of its own entirely")
  end
  lines:add_lines("No part of this publication may be reproduced in any form\nanother copy", true)
  eq("lines many texts share are found (a copy of the last text is not another text)",
    lines:count("no part of this publication may be reproduced in any form"), 3)
  eq("and can be taken out", lines:strip("Sieve methods\nNo part of this Publication may be reproduced in any form\nby A. Name", 3),
    "Sieve methods\n.\nby A. Name\n")

  local learn = require "lulibre.learn"
  eq("a subject and those above it", learn.lineage("math/number-theory/algebraic"), { "math/number-theory/algebraic", "math/number-theory", "math" })
  local st, why = learn.run()
  eq("nothing is learned until records are confirmed", { st, why:find("confirmed as good") ~= nil }, { nil, true })
  for _, term in ipairs { "modular forms", "elliptic curves", "class field theory" } do learn.set("math/number-theory", term, "kept") end
  for _, term in ipairs { "class field theory", "ideal class group" } do learn.set("math/number-theory/algebraic", term, "kept") end
  for _, term in ipairs { "neural networks", "gradient descent" } do learn.set("cs", term, "kept") end
  eq("a subject's phrases", #learn.terms("math/number-theory"), 3)
  local got = learn.classify("We study modular forms and elliptic curves over the rationals.")
  eq("classify finds the subjects whose phrases a text holds", { got[1].subject, #got[1].matched, #got }, { "math/number-theory", 2, 1 })
  local subject, confidence, phrases = learn.suggest("Modular forms, elliptic curves and class field theory.")
  eq("suggest names the subject and the phrases", { subject, confidence > 0.5, #phrases }, { "math/number-theory", true, 3 })
  subject = learn.suggest("Class field theory and the ideal class group of a number field.")
  eq("the more particular subject, when it fits", subject, "math/number-theory/algebraic")
  eq("one phrase is not enough", learn.suggest("A note on neural networks."), nil)
  learn.set("cs", "gradient descent", "dropped")
  eq("a dropped phrase no longer counts", { #learn.terms("cs"), #learn.terms("cs", true) }, { 1, 2 })
  lulibre.store("DELETE FROM terms")
  learn.loaded = nil
  eq("with nothing learned there is nothing to suggest", { learn.ready(), learn.candidate(1) }, { false })
end

-- layouts: pages that say their facts in known places
do
  local layouts = require "lulibre.layouts"
  local cip = layouts.cip [[Mathematics Subject Classification: 22E46

Library of Congress Cataloging in Publication Data
Lang, Serge
SL2(R).
(Graduate texts in mathematics; 105)
Originally published: Reading, Mass.:
Addison-Wesley, 1975.
Bibliography: p.
Includes index.
I. Lie groups.
2. Representations of groups.
I. Title.
II. Series.
QA387.L35
1985
512'.55
85-14802
ISBN 978-1-4612-9581-5]]
  eq("a cataloguing block: who, what, the series and its number", { cip.authors, cip.title, cip.series, cip.series_index },
    { "Serge Lang", "SL2(R)", "Graduate Texts in Mathematics", "105" })
  eq("and the subject its class stands for", { cip.tags, cip.identifiers }, { "math/analysis", "isbn:9781461295815" })
  cip = layouts.cip [[Library of Congress Cataloging-in-Publication Data
Logic from computer science: proceedings of a workshop held November
13-17, 1989/Yiannis Moschovakis, editor.
p. cm. - (Mathematical Sciences Research Institute
publications; 27)
1. Logic, Symbolic and mathematical-Congresses.
QA9.AIL64 1991
511.3-dc20]]
  eq("a title filed under itself, with its editor after the stroke", { cip.title:sub(1, 27), cip.authors, cip.tags, cip.pubdate },
    { "Logic from computer science", "Yiannis Moschovakis", "math/logic", "1991" })
  eq("classes to subjects", { taxonomy.from_lcc("QA247 .S47"), taxonomy.from_lcc("QA564.H25"), taxonomy.from_lcc("QA76.9"),
    taxonomy.from_lcc("P291"), taxonomy.from_lcc("ZZ1"), taxonomy.from_dewey("512'.7"), taxonomy.from_dewey("516.3/5"), taxonomy.from_dewey("x") },
    { "math/number-theory", "math/algebraic-geometry", "cs", "linguistics", nil, "math/number-theory", "math/algebraic-geometry" })
  layouts.add {
    name = "test memoirs", marks = { "memoirs of the", "test society" },
    fields = { series = "Memoirs of the Test Society", series_index = "Number%s+(%d+)", publisher = function() return "TS" end },
    confidence = 0.7,
  }
  local got = {}
  for _, c in ipairs(layouts.read { texts = { "nothing here", "MEMOIRS OF THE\nTest Society\nNumber 412\nMay 1989" } }) do
    if c.source == "test memoirs" then got[c.field] = c.value .. " " .. c.confidence end
  end
  eq("a layout of one's own: a constant, a pattern, a function", got,
    { publisher = "TS 0.7", series = "Memoirs of the Test Society 0.7", series_index = "412 0.7" })
  eq("it does not apply where its marks are not all on a page", #layouts.read { texts = { "memoirs of the", "test society" } }, 0)
  layouts.remove("test memoirs")
  got = {}
  for _, c in ipairs(layouts.read { texts = { "Algebraic Curves and Riemann Surfaces\nRick Miranda\nGraduate Studies in Mathematics\nVolume 5\nAmerican Mathematical Society\n© 1995 by the American Mathematical Society" } }) do
    if c.source == "series page" then got[c.field] = c.value end
  end
  eq("a series page: the series, the volume, the house, the year",
    got, { publisher = "American Mathematical Society", pubdate = "1995", series = "Graduate Studies in Mathematics", series_index = "5" })
  got = {}
  for _, c in ipairs(layouts.read { texts = { "Graduate Texts in Mathematics 52\nSoftcover reprint of the hardcover 1st edition 1977\n© 2010 Springer\nalso available: Undergraduate Texts in Mathematics" } }) do
    if c.source == "series page" then got[c.field] = c.value end
  end
  eq("the series named first on the page, and a reprint's own year",
    { got.series, got.series_index, got.pubdate, got.publisher }, { "Graduate Texts in Mathematics", "52", "1977", "Springer" })
  got = layouts.read { texts = { "arXiv:1012.6008v1  [math.CO]  29 Dec 2010\nA Note on Sieves" } }
  eq("the arXiv stamp gives the day", { got[1].field, got[1].value, got[1].source }, { "pubdate", "2010-12-29", "arXiv stamp" })

  -- a series named in so many words
  local function series(text) return { layouts.series_line(text) } end
  eq("a house's series", series("Elementary Number Theory\nSpringer Undergraduate Mathematics Series\nGareth A. Jones"),
    { "Springer Undergraduate Mathematics Series", nil, "a house's series" })
  eq("with its volume on the line, or below", { series("IAS/Park City Mathematics Series, Volume 12")[1], series("IAS/Park City Mathematics Series, Volume 12")[2],
    series("Potsdam Cognitive Science Series | 7")[2], series("Association for Women in Mathematics Series\nVolume 3")[2] },
    { "IAS/Park City Mathematics Series", "12", "7", "3" })
  eq("a series of mathematics is not one of books", { series("Fourier Series\nSeries Editors\nA. N. Other")[1], series("1.2 The Taylor Series 179")[1],
    series("Dirichlet Series in Number Theory, Volume 41")[1], series("CHAPTER 5 SERIES AND PRODUCT DEVELOPMENTS 175")[1],
    series("a series of lectures given at Princeton University")[1], series("1. Algebra. I. Title. II. Series.")[1] }, {})
  eq("the line above the editors of the series", series("Graduate Texts in Mathematics\nSeries Editors\nSheldon Axler\nKenneth Ribet"),
    { "Graduate Texts in Mathematics", nil, "above the series' editors" })
  eq("above the first list of editors, past the volume", series("UNITEXT - La Matematica per il 3+2\nVolume 109\nEditor-in-chief\nAlfio Quarteroni\nSeries editors\nL. Ambrosio"),
    { "UNITEXT - La Matematica per il 3+2", "109", "above the series' editors" })
  eq("not an editor, who stands above 'Series editors' too", series("Springer Monographs in Mathematics\nEditors-in-chief\nIsabelle Gallagher, Paris, France\nMinhyong Kim, Oxford, UK\nSeries editors\nSheldon Axler")[1],
    "Springer Monographs in Mathematics")
  eq("nor the credit for a cover", series("Cover image: shuoshu / DigitalVision\nVectors / Getty Images\nSeries Editor\nRobert Freidin")[1], nil)
  eq("a name set over two lines", { series("Studies in Neuroscience, Psychology\nand Behavioral Economics\nSeries editors\nMartin Reuter, Bonn, Germany")[1],
    series("CAMBRIDGE TEXTS IN THE\nHISTORY OF POLITICAL THOUGHT\nSeries editors\nRAYMOND GEUSS")[1],
    series("SPRINGER SERIES IN COMPUTATIONAL NEURO-\nSCIENCE\nVolume 4")[1] },
    { "Studies in Neuroscience, Psychology and Behavioral Economics", "Cambridge Texts in the History of Political Thought",
      "Springer Series in Computational Neuroscience" })
  eq("a line about the series may stand between it and its editors",
    series("Lecture Notes in Computer Science\nCommenced Publication in 1973\nFounding and Former Series Editors:\nGerhard Goos")[1], "Lecture Notes in Computer Science")
  eq("a label says it outright", series("Series: Lecture Notes in Physics, Vol. 870"), { "Lecture Notes in Physics", "870", "labelled" })
  eq("a name alone, with nothing to bear it out, is not taken", series("Some Mathematics Series\nA. N. Other")[1], nil)
  got = {}
  for _, c in ipairs(layouts.read { texts = { "x", "Mathematics of Planet Earth\nVolume 4\nSeries editors\nKen Golden" } }) do
    if c.source == "series line" then got[c.field] = c.value end
  end
  eq("read as a layout", got, { series = "Mathematics of Planet Earth", series_index = "4" })

  -- dates
  eq("a date, however it is written", { layouts.date("8 February 1972"), layouts.date("Feb. 8, 1972"), layouts.date("March 2004"),
    layouts.date("SEPTEMBER 2002"), layouts.date("2004-03-12"), layouts.date("July, 2012"), layouts.date("12 mars 1985"),
    layouts.date("3. Mai 1962"), (layouts.date("May 3rd, 1999")) },
    { "1972-02-08", "1972-02-08", "2004-03-01", "2002-09-01", "2004-03-12", "2012-07-01", "1985-03-12", "1962-05-03", "1999-05-03" })
  eq("and what is not one", { layouts.date("3/12/2004"), layouts.date("Theorem 12, 2004"), layouts.date("31 February 9999"),
    layouts.date("the name of zeta functions") }, {})
  -- what one layout reads from a first page
  local function reads(name, ...)
    for _, c in ipairs(layouts.read { texts = { ... } }) do
      if c.source == name then return c.value end
    end
  end
  eq("the day a journal received an article", { reads("received date", "SCATTERING THEORY\nF. MAYNE\nReceived 8 February 1972\nSynopsis"),
    reads("received date", "Received by the editors May 3, 1999 and, in revised form, June 1, 2000."),
    reads("received date", "(Received: 21 October 2003 / Accepted: 2 March 2004)"), reads("received date", "Reçu le 12 mars 1985"),
    reads("received date", "Eingegangen am 3. Mai 1962") }, { "1972-02-08", "1999-05-03", "2003-10-21", "1985-03-12", "1962-05-03" })
  eq("'received' in a sentence is not a date", reads("received date", "bers, periodic orbits have received\nthe name of zeta functions in March 1990."), nil)
  eq("a date on a line of its own", { reads("dated page", "On Sums\nA. N. Other\n\nMarch 12, 2015\n\nAbstract"),
    reads("dated page", "Key words and phrases. Sieves.\nDate: December 11, 2008\n2001 PACS"), reads("dated page", "SEPTEMBER 2002\nNOTICES OF THE AMS"),
    reads("dated page", "Preprint submitted to Elsevier\n21 June 2021"), reads("dated page", "Version of 3 January 2020.") },
    { "2015-03-12", "2008-12-11", "2002-09-01", "2021-06-21", "2020-01-03" })
  eq("but not one that ends a sentence begun on the line above", reads("dated page",
    "July, 1801, and Jacobi introduced the Jacobi sum in a letter to Gauss[Ja1] dated\nFebruary 8, 1827.\n\nThe sum"), nil)
  eq("nor a date within a line", reads("dated page", "We met on March 12, 2015 in Bonn."), nil)
  local j = layouts.journal("Physica 63 (1973) 1-32\n© North-Holland Publishing Co.")
  eq("a journal's heading", { j.journal, j.volume, j.year, j.pages }, { "Physica", 63, 1973, "1" })
  j = layouts.journal("Journal of Algebra 320 (2008) 1234–1256")
  eq("with a dash between the pages", { j.journal, j.volume, j.year }, { "Journal of Algebra", 320, 2008 })
  j = layouts.journal("Invent. math. 123, 1–40 (1996)")
  eq("or the year last", { j.journal, j.volume, j.year }, { "Invent. math.", 123, 1996 })
  j = layouts.journal("Ann. of Math. (2) 141 (1995), 443–551")
  eq("or a series before the volume", { j.journal, j.volume, j.year }, { "Ann. of Math.", 141, 1995 })
  eq("a line of prose with a year is not one", layouts.journal("We follow Serre 12 (1973) and others in this"), nil)
  local function field_of(name, field, text)
    for _, c in ipairs(layouts.read { texts = { text } }) do
      if c.source == name and c.field == field then return c.value end
    end
  end
  eq("the year of the heading", field_of("journal header", "pubdate", "Journal of Algebra 320 (2008) 1234–1256\nOn groups"), "2008")
  j = layouts.journal("Milan J. Math. Vol. 78 (2010) 135–152")
  eq("'Vol.' is not part of a journal's name", { j.journal, j.volume }, { "Milan J. Math.", 78 })
  eq("nor are capitals", layouts.journal("INTERNATIONAL JOURNAL OF QUANTUM CHEMISTRY 8 (1974) 1-20").journal, "International Journal of Quantum Chemistry")
  -- an article's publisher is its journal, after the house behind it
  eq("a house is written one way", { layouts.house("Springer-Verlag New York, Inc."), layouts.house("Springer Science and Business Media LLC"),
    layouts.house("Elsevier BV"), layouts.house("Cambridge University Press (CUP)"), layouts.house("Informa UK Limited"),
    layouts.house("American Institute of Mathematical Sciences (AIMS)"), layouts.house("Example Press"), layouts.house("") },
    { "Springer", "Springer", "Elsevier", "Cambridge University Press", "Taylor & Francis", "American Institute of Mathematical Sciences", "Example Press" })
  eq("the journal after its house", { layouts.with_journal("Elsevier BV", "Journal of Algebra"), layouts.with_journal(nil, "Journal of Algebra"),
    layouts.with_journal("Springer", nil), layouts.with_journal(nil, nil) },
    { "Elsevier: Journal of Algebra", "Journal of Algebra", "Springer" })
  eq("an archive that only registers the articles is not the publisher", layouts.with_journal("JSTOR", "The Annals of Mathematics"), "The Annals of Mathematics")
  eq("a society's own journal says whose it is already",
    layouts.with_journal("American Mathematical Society (AMS)", "Transactions of the American Mathematical Society"), "Transactions of the American Mathematical Society")
  got = {}
  for _, c in ipairs(layouts.read { texts = { "Journal of Algebra 320 (2008) 1234–1256\nOn groups\n© 2008 Elsevier Inc. All rights reserved." } }) do
    if c.field == "publisher" then got[c.source] = { c.value, c.confidence } end
  end
  eq("read from a first page: the journal with its house is the surer publisher", got,
    { ["journal header"] = { "Elsevier: Journal of Algebra", 0.82 }, ["copyright line"] = { "Elsevier", 0.8 } })
  eq("a journal alone, when the page names no house", field_of("journal header", "publisher", "Physica 63 (1973) 1-32\nSCATTERING THEORY"), "Physica")
  local function year_of(text)
    for _, c in ipairs(layouts.read { texts = { text } }) do
      if c.source == "copyright line" and c.field == "pubdate" then return c.value end
    end
  end
  eq("the year of a copyright line", { year_of("© 2008 Elsevier Inc. All rights reserved."),
    year_of("Copyright (c) 1965, 1984, 2002 by A. N. Other"), year_of("Copyright © 1994–2023 Lua.org, PUC-Rio."),
    year_of("Copyright 1996, American Mathematical Society"), year_of("no sign here, only 1999") }, { "2008", "2002", "2023", "1996" })
  eq("whose copyright it is, when it is a publisher's", { layouts.copyright_holder("© Springer-Verlag Berlin Heidelberg 1999"),
    layouts.copyright_holder("© 2008 Elsevier Inc. All rights reserved."), layouts.copyright_holder("Copyright © 1984 by McGraw-Hill, Inc. All rights reserved. Printed in the"),
    layouts.copyright_holder("© Springer International Publishing AG, part of Springer Nature 2018, 2020"),
    layouts.copyright_holder("Copyright 1996, American Mathematical Society"),
    (layouts.copyright_holder("Copyright 1996 by the American Mathematical Society")) },
    { "Springer", "Elsevier", "McGraw-Hill", "Springer", "American Mathematical Society", "American Mathematical Society" })
  eq("and whether the house is a known one", select(2, layouts.copyright_holder("© 2008 Elsevier Inc.")), true)
  eq("a house that is not listed, as the line writes it", { layouts.copyright_holder("Copyright © 1971 by Chelsea Publishing Company.") },
    { "Chelsea Publishing Company", false })
  eq("an author's copyright names no publisher", { layouts.copyright_holder("© The Author(s) 2021"), layouts.copyright_holder("© 2019 Benjamin A. Smith"),
    layouts.copyright_holder("Copyright (c) 2010 by Jane Hermann"), layouts.copyright_holder("© 2023 Copyright held by the owner/author(s).") }, {})
  got = {}
  for _, c in ipairs(layouts.read { texts = { "© 2008 Elsevier Inc. All rights reserved." } }) do
    if c.source == "copyright line" then got[c.field] = { c.value, c.confidence } end
  end
  eq("the line gives the year and the house, each as sure as it is", got, { pubdate = { "2008", 0.75 }, publisher = { "Elsevier", 0.8 } })
  -- a reprint's series page knows better than its copyright line, and says so more surely
  local best
  for _, c in ipairs(layouts.read { texts = { "Graduate Texts in Mathematics 52\nSoftcover reprint of the hardcover 1st edition 1977\n© 2010 Springer" } }) do
    if c.field == "pubdate" and (not best or c.confidence > best.confidence) then best = c end
  end
  eq("the surest date of a reprint is the edition's", { best.value, best.source }, { "1977", "series page" })
end

-- references: the bibliography at the end of a file
do
  local refs = require "lulibre.refs"
  eq("the heading of a bibliography", { refs.is_heading("References"), refs.is_heading("  BIBLIOGRAPHY "), refs.is_heading("7. References"),
    refs.is_heading("References 213"), refs.is_heading("References to the literature are given below") }, { true, true, true, false, false })
  local function l(text, x0) return { text = text, x0 = x0, size = 9 } end
  local pages = {
    { no = 18, lines = { l("so the theorem follows.", 70), l("References", 270), l("[1] F. V. Atkinson, Some aspects of Baxter's functional", 75),
      l("equation, J. Math. Anal. Appl. 7 (1963), 1–30.", 88), l("[2] G. Baxter, An analytic problem, Pacific J. Math. 10", 75) } },
    { no = 19, lines = { l("(1960), 731–742.", 88), l("19", 300), l("[3] see the remark above", 75) } },
  }
  local lines, page = refs.find(pages)
  eq("the lines under it, over the page break, without the page number", { #lines, page }, { 5, 18 })
  local entries = refs.entries(lines)
  eq("numbered entries, their continuation lines joined", { #entries, entries[2] },
    { 3, "[2] G. Baxter, An analytic problem, Pacific J. Math. 10 (1960), 731–742." })
  entries = refs.entries { l("Abdulali, S. 1994. Algebraic cycles in families of abelian", 108), l("varieties. Canad. J. Math. 46, 1121–1134.", 122),
    l("André, Y. 2004. Une introduction aux motifs. Panoramas et", 108), l("Synthèses, 17. Société Mathématique de France.", 123) }
  eq("entries told apart by their hanging indent", { #entries, entries[2]:sub(1, 16) }, { 2, "André, Y. 2004." })
  eq("a key by which a work is known, however a list writes it", {
    refs.key("[1] F. V. Atkinson, Some aspects of Baxter's functional equation, J. Math. Anal. Appl. 7 (1963), 1–30."),
    refs.key("Abdulali, S. 1994. Algebraic cycles in families of abelian varieties. Canad. J. Math. 46 (1994), 1121–1134."),
    refs.key("[DG67] Jean Dieudonné and Alexander Grothendieck, Éléments de géométrie algébrique, Publ. Math. IHES (1967)."),
    refs.key("J.-P. Serre. A course in arithmetic. Springer, 1973."),
    refs.key("Serre, J.-P.: A course in arithmetic. Springer (1973)"),
    refs.key("Wiles, A. (1995). Modular elliptic curves. Annals of Mathematics 141, 443-551. doi:10.2307/2118559"),
    refs.key("H. Cohen, Number theory, arXiv:1012.6008v2, 2010."),
    refs.key("see the remark above") },
    { "atkinson:1963:1", "abdulali:1994:1121", "dieudonne:1967", "serre:1973", "serre:1973", "doi:10.2307/2118559", "arxiv:1012.6008" })
  -- coupling: books 1 and 2 cite the same two works
  for _, row in ipairs { { 1, "serre:1973" }, { 1, "wiles:1995:443" }, { 2, "serre:1973" }, { 2, "wiles:1995:443" }, { 2, "lang:2002" } } do
    lulibre.store("INSERT OR IGNORE INTO refs(book, key, raw) VALUES(?, ?, '')", row[1], row[2])
  end
  local c = refs.coupled(1)
  eq("the books that cite what a book cites", { #c, c[1].book, c[1].shared }, { 1, 2, 2 })
  eq("one such book is not enough to name a subject", refs.subject(1), nil)
  eq("what a book cites", #refs.of(2), 3)
  eq("how often a book's references are headed by a name", { refs.cites(2, "Jean-Pierre Serre"), refs.cites(2, "A. Wiles"), refs.cites(2, "N. Obody") },
    { 1, 1, 0 })
  lulibre.store("INSERT OR IGNORE INTO refs(book, key, raw) VALUES(1, 'lang:2002', '')")
  local near = refs.neighbours(1)
  eq("who wrote the books that share its references", { #near, near[1] and near[1].name, near[1] and near[1].shared }, { 1, "Paul Erdős", 3 })
  lulibre.store("DELETE FROM refs")
end

-- metadata services: answered from what is kept, never from the network here
do
  local net = require "lulibre.net"
  net.offline = true
  net.keep("arxiv", "1012.6008", 200, [[<entry>
    <id>http://arxiv.org/abs/1012.6008v2</id>
    <published>2010-12-29T18:01:10Z</published>
    <title>A Note on
  Sieve Methods</title>
    <summary>  We prove a thing. </summary>
    <author><name>Paul Erd&#39;os</name></author>
    <author><name>A. N. Other</name></author>
    <arxiv:doi xmlns:arxiv="http://arxiv.org/schemas/atom">10.1000/xyz</arxiv:doi>
    <arxiv:primary_category xmlns:arxiv="http://arxiv.org/schemas/atom" term="math.NT" scheme="http://arxiv.org/schemas/atom"/>
  </entry>]])
  local r = net.arxiv("1012.6008v2")
  eq("arXiv: title, authors, the day, the class as a subject, the DOI it knows",
    { r.title, r.authors, r.date, r.subjects[1].tag, r.ids.doi, r.ids.arxiv, r.source },
    { "A Note on Sieve Methods", { "Paul Erd'os", "A. N. Other" }, "2010-12-29", "math/number-theory", "10.1000/xyz", "1012.6008", "arXiv 1012.6008" })
  net.keep("crossref", "10.2307/2118559", 200, [=[{"status":"ok","message":{"DOI":"10.2307/2118559","type":"journal-article",
    "title":["Modular Elliptic Curves and Fermat's Last Theorem"],"author":[{"given":"Andrew","family":"Wiles"}],
    "publisher":"JSTOR","issued":{"date-parts":[[1995,5]]},"container-title":["The Annals of Mathematics"]}}]=])
  r = net.crossref("10.2307/2118559")
  eq("CrossRef: an article's registrant is not offered as its publisher", { r.title, r.authors, r.year, r.publisher, r.ids.doi },
    { "Modular Elliptic Curves and Fermat's Last Theorem", { "Andrew Wiles" }, 1995, nil, "10.2307/2118559" })
  eq("but its journal is kept, with who registered it", { r.container, r.member, r.type }, { "The Annals of Mathematics", "JSTOR", "journal-article" })
  net.keep("zbmath", "doi:10.2307/2118559", 200, [=[{"result":[{"contributors":{"authors":[{"name":"Wiles, Andrew"}]},
    "document_type":{"code":"j","description":"journal article"},"identifier":"0823.11029","year":"1995",
    "msc":[{"code":"11G05","scheme":"msc2020"},{"code":"11F11","scheme":"msc2020"},{"code":"14H52","scheme":"msc2020"}],
    "title":{"title":"Modular elliptic curves and Fermat's Last Theorem","subtitle":null}}],"status":{"status_code":200}}]=])
  r = net.zbmath { doi = "10.2307/2118559" }
  eq("zbMATH: the subject from the MSC codes, the main one surest, an area named once",
    { r.authors, r.ids.zbl, #r.subjects, r.subjects[1].tag, r.subjects[1].confidence, r.subjects[1].why, r.subjects[2].tag },
    { { "Andrew Wiles" }, "0823.11029", 2, "math/number-theory", 0.9, "MSC 11G05", "math/algebraic-geometry" })
  net.keep("openlibrary", "9780387902449", 200, [=[{"ISBN:9780387902449":{"title":"Algebraic Geometry (Graduate Texts in Mathematics)",
    "authors":[{"name":"Robin Hartshorne"}],"publishers":[{"name":"Springer"}],"publish_date":"April 1, 1997",
    "classifications":{"lc_classifications":["QA564-609"]}}}]=])
  r = net.openlibrary("978-0-387-90244-9")
  eq("Open Library: the series out of the title's bracket, the subject from the shelf class",
    { r.title, r.series, r.authors, r.publisher, r.date, r.subjects[1].tag }, { "Algebraic Geometry", "Graduate Texts in Mathematics",
      { "Robin Hartshorne" }, "Springer", "1997-04-01", "math/algebraic-geometry" })
  net.keep("crossref", "10.9999/none", 404)
  local none, why = net.crossref("10.9999/none")
  eq("what a service did not have is remembered as such", { none, why }, { nil, "crossref has no record of 10.9999/none" })
  none, why = net.crossref("10.1000/never-asked")
  eq("offline, nothing is asked", { none, why:find("offline") ~= nil }, { nil, true })
  eq("requests carry the contact address only when one is set", { net.agent():find("mailto") },  {})
  lulibre.o.contact_email = "me@example.org"
  eq("and then they do", net.agent():find("mailto:me@example.org", 1, true) ~= nil, true)
  lulibre.o.contact_email = ""
  lulibre.store("DELETE FROM lookups")
  net.offline = false

  -- how arXiv is asked: its terms allow one request every three seconds on
  -- one connection, and its manual wants a comma-delimited id_list
  eq("an arXiv number as arXiv writes it", { net.arxiv_id("1012.6008v2"), net.arxiv_id("arXiv:2301.00001"),
    net.arxiv_id("math.AG/0601001v3"), net.arxiv_id("hep-th/9711200"), net.arxiv_id("10.1000/xyz"), net.arxiv_id("1012.60") },
    { "1012.6008", "2301.00001", "math/0601001", "hep-th/9711200", nil, nil })
  eq("no faster than its terms allow", net.PACE.arxiv >= 3, true)
  eq("nor the others than theirs: Open Library one a second, CrossRef five", { net.PACE.openlibrary >= 1, net.PACE.crossref >= 0.2 }, { true, true })
  local ids = {}
  for i = 1, net.ARXIV_BATCH + 2 do ids[i] = ("1012.%04d"):format(i) end
  local urls = net.arxiv_urls(ids)
  eq("many numbers to a request", { #urls, #urls[1].ids, #urls[2].ids }, { 2, net.ARXIV_BATCH, 2 })
  eq("the numbers as they are, commas between",
    net.arxiv_urls({ "1012.6008", "hep-th/9711200" })[1].url,
    "https://export.arxiv.org/api/query?id_list=1012.6008,hep-th/9711200&start=0&max_results=2")

  local function feed(total, entries)
    return ('<?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom"><title>ArXiv Query: id_list=x</title>'
      .. '<opensearch:totalResults xmlns:opensearch="http://a9.com/-/spec/opensearch/1.1/">%d</opensearch:totalResults>%s</feed>'):format(
      total, entries)
  end
  local function entry(id)
    return ("<entry><id>http://arxiv.org/abs/%sv1</id><published>2010-12-29T18:01:10Z</published><title>Paper %s</title>"
      .. "<author><name>A. N. Other</name></author></entry>"):format(id, id)
  end
  -- an answer as arXiv gave it on 2026-10-13 (summary cut, one of its two
  -- entries): a number it does not have is simply not among the entries
  local real = [==[<?xml version='1.0' encoding='UTF-8'?>
<feed xmlns:opensearch="http://a9.com/-/spec/opensearch/1.1/" xmlns:arxiv="http://arxiv.org/schemas/atom" xmlns="http://www.w3.org/2005/Atom">
  <id>https://arxiv.org/api/d48WUdaM37IuC4PL4Oaz32kJO40</id>
  <title>arXiv Query: search_query=&amp;id_list=hep-th/9711200,0704.9999&amp;start=0&amp;max_results=2</title>
  <updated>2026-10-13T06:27:49Z</updated>
  <opensearch:itemsPerPage>2</opensearch:itemsPerPage>
  <opensearch:totalResults>1</opensearch:totalResults>
  <opensearch:startIndex>0</opensearch:startIndex>
  <entry>
    <id>http://arxiv.org/abs/hep-th/9711200v3</id>
    <title>The Large N Limit of Superconformal Field Theories and Supergravity</title>
    <updated>1998-01-22T15:42:41Z</updated>
    <link href="https://arxiv.org/abs/hep-th/9711200v3" rel="alternate" type="text/html"/>
    <summary>  We show that the large $N$ limit of certain conformal field theories ...</summary>
    <category term="hep-th" scheme="http://arxiv.org/schemas/atom"/>
    <published>1997-11-27T23:53:13Z</published>
    <arxiv:primary_category term="hep-th"/>
    <arxiv:journal_ref>Adv.Theor.Math.Phys.2:231-252,1998</arxiv:journal_ref>
    <author>
      <name>Juan M. Maldacena</name>
    </author>
    <arxiv:doi>10.1023/A:1026654312961</arxiv:doi>
    <link rel="related" href="https://doi.org/10.1023/A:1026654312961" title="doi"/>
  </entry>
</feed>]==]
  eq("arXiv's own answer: one record of the two asked for", net.arxiv_take({ "hep-th/9711200", "0704.9999" }, real), 1)
  net.offline = true
  local m = net.arxiv("hep-th/9711200")
  eq("read as it is written", { m.title, m.authors, m.date, m.class, m.ids.doi },
    { "The Large N Limit of Superconformal Field Theories and Supergravity", { "Juan M. Maldacena" }, "1997-11-27", "hep-th", "10.1023/A:1026654312961" })
  eq("and the number it did not return is known not to be there", net.kept("arxiv", "0704.9999"), false)
  net.offline = false

  local real_get, calls, answer = net.get, {}, nil
  local pace = net.PACE.arxiv
  net.PACE.arxiv = 0
  net.get = function(url)
    calls[#calls + 1] = url
    return answer(url)
  end
  local function fresh()
    lulibre.store("DELETE FROM lookups")
    lulibre.store("DELETE FROM kv WHERE key LIKE 'net.%'")
    calls = {}
  end

  fresh()
  answer = function() return feed(2, entry("1012.0001") .. entry("math/0601001")), 200 end
  eq("a batch: one request for three numbers", { net.arxiv_prefetch { "1012.0001", "math.AG/0601001v2", "1012.0003" }, #calls }, { 2, 1 })
  eq("each record kept under its number", { net.arxiv("1012.0001").title, net.arxiv("math.AG/0601001").title }, { "Paper 1012.0001", "Paper math/0601001" })
  local r3, why3 = net.arxiv("1012.0003")
  eq("the one arXiv did not return is remembered as not there, and nothing more was asked", { r3, why3, #calls },
    { nil, "arXiv has no record of 1012.0003", 1 })

  fresh()
  answer = function() return feed(0, ""), 200 end
  net.arxiv_prefetch { "1012.0001", "1012.0002" }
  eq("an empty answer about several numbers is not taken as 'none of them exists'",
    { net.kept("arxiv", "1012.0001"), net.kept("arxiv", "1012.0002") }, {})
  local r1, why1 = net.arxiv("1012.0001")
  eq("nor are they then asked for one by one", { r1, why1, #calls }, { nil, "arXiv gave no answer about 1012.0001", 1 })
  net.arxiv("1012.0009")
  eq("an empty answer about one number is", { net.kept("arxiv", "1012.0009"), #calls }, { false, 2 })
  eq("the feed's own title is not a paper's", net.arxiv("1012.0009"), nil)

  fresh()
  answer = function() return "Rate exceeded.", 429, 2400 end
  for i = 1, net.ARXIV_BATCH * 2 do ids[i] = ("1101.%04d"):format(i) end
  net.arxiv_prefetch(ids)
  eq("told 'too many requests': the request is not made again and the next batch is not sent", #calls, 1)
  local till = net.held("arxiv")
  eq("arXiv is left alone for as long as it asked, or longer", till ~= nil and till - os.time() >= 2390, true)
  local held, why = net.arxiv("1101.0001")
  eq("and until then nothing is asked of it", { held, why:find("pause") ~= nil, #calls }, { nil, true, 1 })
  held, why = net.arxiv("1201.0001")
  eq("not even about something else", { held, why:find("pause") ~= nil, #calls }, { nil, true, 1 })
  eq("another service is still asked", net.held("crossref"), nil)
  net.hold("arxiv", 0)
  eq("a pause can be lifted", net.held("arxiv"), nil)

  fresh()
  lulibre.store("INSERT INTO lookups(service, key, at, status) VALUES('arxiv', '0901.0001', ?, 404)", os.time() - 86400 * (net.FORGET_DAYS + 1))
  lulibre.store("INSERT INTO lookups(service, key, at, status) VALUES('arxiv', '0901.0002', ?, 404)", os.time() - 86400)
  eq("'no such record' is believed for a while, then asked again", { net.kept("arxiv", "0901.0001"), net.kept("arxiv", "0901.0002") }, { nil, false })

  -- arXiv's snapshot: papers read from a file, nothing asked
  fresh()
  local snap = os.tmpname()
  local sf = assert(io.open(snap, "w"))
  sf:write([=[{"id":"0704.0001","submitter":"Pavel Nadolsky","authors":"C. Bal\\'azs, E. L. Berger, P. M. Nadolsky, C.-P. Yuan","title":"Calculation of prompt diphoton production cross sections at Tevatron and\n  LHC energies","comments":"37 pages","journal-ref":"Phys.Rev.D76:013009,2007","doi":"10.1103/PhysRevD.76.013009","report-no":"ANL-HEP-PR-07-12","categories":"hep-ph","license":null,"abstract":"  A fully differential calculation in perturbative quantum chromodynamics\n","versions":[{"version":"v1","created":"Mon, 2 Apr 2007 19:18:42 GMT"},{"version":"v2","created":"Tue, 24 Jul 2007 20:10:27 GMT"}],"update_date":"2008-11-26","authors_parsed":[["Balázs","C.",""],["Berger","E. L.",""],["Nadolsky","P. M.",""],["Yuan","C. -P.",""]]}]=], "\n")
  sf:write([=[{"id":"0704.0002","authors":"Ileana Streinu and Louis Theran","title":"Sparsity-certifying Graph Decompositions","categories":"math.CO cs.CG","versions":[{"version":"v1","created":"Sat, 31 Mar 2007 02:26:18 GMT"}],"authors_parsed":[]}]=], "\n")
  sf:write([=[{"id":"math/0601001","authors":"A. N. Other","title":"An Old Paper","categories":"math.AG","versions":[{"version":"v1","created":"Sun, 1 Jan 2006 10:00:00 GMT"}],"authors_parsed":[["Other","A. N.","Jr"]]}]=], "\n")
  sf:close()
  local found, lines = net.arxiv_snapshot(snap, { "0704.0001v2", "math.AG/0601001", "2501.00001", "0704.0002" })
  eq("papers are read out of arXiv's snapshot", { found, lines, #calls }, { 3, 3, 0 })
  net.offline = true
  local s1, s2, s3 = net.arxiv("0704.0001"), net.arxiv("0704.0002"), net.arxiv("math/0601001")
  eq("a record of the snapshot: title on one line, the first version's day, the class, the DOI",
    { s1.title, s1.date, s1.class, s1.subjects[1] and s1.subjects[1].tag, s1.ids.doi, s1.source },
    { "Calculation of prompt diphoton production cross sections at Tevatron and LHC energies", "2007-04-02", "hep-ph",
      taxonomy.from_arxiv("hep-ph"), "10.1103/PhysRevD.76.013009", "arXiv 0704.0001" })
  eq("authors given name first", { s1.authors, s2.authors, s3.authors },
    { { "C. Balázs", "E. L. Berger", "P. M. Nadolsky", "C. -P. Yuan" }, { "Ileana Streinu", "Louis Theran" }, { "A. N. Other Jr" } })
  eq("the first class is the paper's own", s2.class, "math.CO")
  net.offline = false
  eq("a paper newer than the file is left to be asked for", net.kept("arxiv", "2501.00001"), nil)
  eq("a second reading has nothing left to look for but that", { net.arxiv_snapshot(snap, { "0704.0001", "0704.0002" }) }, { 0, 0 })
  eq("a file that is not there says so", (select(2, net.arxiv_snapshot("/nonexistent/snapshot.json", { "0801.0001" }))):find("cannot read") ~= nil, true)

  -- the other file of arXiv's records: a hypergraph, set out over many lines
  fresh()
  local hif = os.tmpname()
  sf = assert(io.open(hif, "w"))
  sf:write([=[{
  "metadata": {},
  "network-type": "undirected",
  "edges": [
    {
      "attrs": {
        "submitter": "A. N. Other",
        "title": "A proof of the Erd\\H{o}s primitive set\n  conjecture",
        "comments": null,
        "categories": [
          "math.NT",
          "math.CO"
        ],
        "abstract": "We prove \"it\".",
        "date": "2023-08-28"
      },
      "edge": "2202.02384"
    },
    {
      "attrs": {
        "submitter": "S",
        "title": "Not wanted",
        "categories": [
          "cs.LG"
        ],
        "date": "2025-05-28"
      },
      "edge": "2505.20698"
    },
    {
      "attrs": {
        "title": "On $p$-state $p$-adic Potts model",
        "categories": [
          "math-ph"
        ],
        "date": "2014-01-01"
      },
      "edge": "math/0601001"
    }
  ],
  "incidences": [
    {
      "edge": "2202.02384",
      "node": "Second Author"
    },
    {
      "edge": "2505.20698",
      "node": "Nobody Wanted"
    },
    {
      "edge": "2202.02384",
      "node": "Jared Duker Lichtman"
    },
    {
      "edge": "math/0601001",
      "node": "Cl\u00e9ment Dupont"
    }
  ]
}
]=])
  sf:close()
  found, lines = net.arxiv_snapshot(hif, { "2202.02384v3", "math.AG/0601001", "2609.00001" })
  eq("a hypergraph of arXiv: the papers wanted are found among its edges", { found, lines, #calls }, { 2, 3, 0 })
  net.offline = true
  local h1, h2 = net.arxiv("2202.02384"), net.arxiv("math/0601001")
  eq("its TeX put into plain text, its first class, the year its number says", { h1.title, h1.class, h1.year, h1.date, h1.title_tex },
    { "A proof of the Erdős primitive set conjecture", "math.NT", 2022 })
  eq("its authors, who come in no order", { h1.authors, h1.authors_unordered, h2.authors, h2.authors_unordered },
    { { "Second Author", "Jared Duker Lichtman" }, true, { "Clément Dupont" } })
  eq("simple mathematics needs no dollars", h2.title, "On p-state p-adic Potts model")
  net.offline = false
  eq("what the file does not hold is remembered, and not looked for in it again", { net.arxiv_snapshot(hif, { "2609.00001" }) }, { 0, 0 })
  eq("the page says who comes first", { net.in_order_of({ "Second Author", "Jared Duker Lichtman" }, "A PROOF\nJared Duker Lichtman and Second Author\nAbstract") },
    { { "Jared Duker Lichtman", "Second Author" }, true })
  eq("and when it does not name them all, the order is not to be trusted",
    select(2, net.in_order_of({ "Second Author", "Jared Duker Lichtman" }, "A PROOF\nJ. D. Lichtman\nAbstract")), false)
  -- arXiv's own snapshot says more than the hypergraph did: its record takes the place of the other
  sf = assert(io.open(snap, "w"))
  sf:write([=[{"id":"2202.02384","authors":"Jared Duker Lichtman, Second Author","title":"A proof of the Erd\\H{o}s primitive set conjecture","doi":"10.1017/fmp.2023.16","categories":"math.NT","versions":[{"version":"v1","created":"Fri, 4 Feb 2022 20:47:55 GMT"}],"authors_parsed":[["Lichtman","Jared Duker",""],["Author","Second",""]]}]=], "\n")
  sf:close()
  eq("a record from the hypergraph is looked for again in arXiv's own snapshot", { net.arxiv_snapshot(snap, { "2202.02384", "math/0601001" }) }, { 1, 1 })
  net.offline = true
  h1, h2 = net.arxiv("2202.02384"), net.arxiv("math/0601001")
  eq("and bettered: the authors in order, the DOI, the day", { h1.authors, h1.authors_unordered, h1.ids.doi, h1.date },
    { { "Jared Duker Lichtman", "Second Author" }, nil, "10.1017/fmp.2023.16", "2022-02-04" })
  eq("what the snapshot does not hold keeps the record it had", h2.title, "On p-state p-adic Potts model")
  net.offline = false
  eq("and is not looked for there again", { net.arxiv_snapshot(snap, { "2202.02384", "math/0601001" }) }, { 0, 0 })
  os.remove(snap)
  os.remove(hif)
  local nf = assert(io.open(hif, "w"))
  nf:write("just some text\n")
  nf:close()
  eq("a file that is neither says so", (select(2, net.arxiv_snapshot(hif, { "0801.0001" }))):find("knows how to read") ~= nil, true)
  os.remove(hif)

  -- TeX in titles and names
  local detex = require "lulibre.detex"
  eq("TeX accents and letters", { detex.plain("Erd\\H{o}s"), detex.plain("Bal\\'azs"), detex.plain("K\\\"ahler"), detex.plain("{\\v{C}}ech"),
    detex.plain("Poincar\\'{e}"), detex.plain("M{\\o}ller"), detex.plain("Fa\\`a di Bruno"), detex.plain("\\L ojasiewicz"), detex.plain("Stra\\ss en"),
    detex.plain("G\\\"{o}del"), (detex.plain("na\\\"\\i ve")) },
    { "Erdős", "Balázs", "Kähler", "Čech", "Poincaré", "Møller", "Faà di Bruno", "Łojasiewicz", "Straßen", "Gödel", "naïve" })
  eq("mathematics is left as it is, and said to be", { detex.plain("On $\\mathbb{Z}_p$-extensions") }, { "On $\\mathbb{Z}_p$-extensions", false })
  eq("plain text is not touched", { detex.plain("Sums of Primes & Squares") }, { "Sums of Primes & Squares", true })

  -- CrossRef and Open Library take many at a time too
  fresh()
  local pace_cr, pace_ol = net.PACE.crossref, net.PACE.openlibrary
  net.PACE.crossref, net.PACE.openlibrary = 0, 0
  answer = function(url)
    if url:find("crossref", 1, true) then
      return [=[{"status":"ok","message":{"total-results":1,"items":[{"DOI":"10.1000/ABC","type":"book","title":["A Book"],
        "author":[{"given":"A. N.","family":"Other"}],"publisher":"Example Press","issued":{"date-parts":[[1977]]},"ISBN":["9780387902449"]}]}}]=], 200
    end
    return [=[{"ISBN:9780387902449":{"title":"Algebraic Geometry","authors":[{"name":"Robin Hartshorne"}]}}]=], 200
  end
  eq("CrossRef: one request for several DOIs", { net.crossref_prefetch { "10.1000/abc", "10.1000/none", "10.1000/abc" }, #calls }, { 1, 1 })
  eq("asked for by filter, with only the fields that are read",
    { calls[1]:find("filter=doi:10.1000%2Fabc,doi:10.1000%2Fnone&rows=2", 1, true) ~= nil, calls[1]:find("select=DOI,", 1, true) ~= nil }, { true, true })
  local c = net.crossref("10.1000/ABC")
  eq("each kept as its own record", { c.title, c.authors, c.year, c.publisher, c.ids.isbn, #calls },
    { "A Book", { "A. N. Other" }, 1977, "Example Press", "9780387902449", 1 })
  eq("and the one it did not return as not there", { net.kept("crossref", "10.1000/none"), #calls }, { false, 1 })
  eq("Open Library: one request for several ISBNs", { net.openlibrary_prefetch { "978-0-387-90244-9", "9780000000019" }, #calls }, { 1, 2 })
  eq("asked for together", calls[2]:find("bibkeys=ISBN:9780387902449,ISBN:9780000000019", 1, true) ~= nil, true)
  eq("each kept", { net.openlibrary("9780387902449").title, net.kept("openlibrary", "9780000000019"), #calls }, { "Algebraic Geometry", false, 2 })
  answer = function() return "<html>busy</html>", 503 end
  net.crossref_prefetch { "10.1000/later1", "10.1000/later2" }
  local l1, lwhy = net.crossref("10.1000/later1")
  eq("a batch that fails is not asked for again piece by piece", { l1, lwhy:find("pause") ~= nil, #calls, net.kept("crossref", "10.1000/later1") },
    { nil, true, 3 })

  net.get, net.PACE.arxiv, net.PACE.crossref, net.PACE.openlibrary = real_get, pace, pace_cr, pace_ol
  fresh()
end

-- one record's values offered to another
do
  local dupes = require "lulibre.dupes"
  local from, to = lulibre.book(2), lulibre.book(1) -- Notes, by Paul Erdős, 1996, with a subject; paper, by nobody
  local n = dupes.pull(from, to)
  local got = {}
  for _, p in ipairs(lulibre.sql("SELECT field, op, value, source FROM proposals WHERE book = 1 AND source = 'book 2' ORDER BY field")) do
    got[#got + 1] = p.field .. ":" .. p.op
  end
  eq("pull proposes what the other record has", { n >= 3, table.concat(got, " "):find("authors:set") ~= nil,
    table.concat(got, " "):find("tags:add") ~= nil }, { true, true, true })
  eq("and nothing the second time", dupes.pull(from, to), 0)
  lulibre.store("DELETE FROM proposals WHERE source = 'book 2'")
end

-- which build this is
eq("the build has a number and a commit", { lulibre.build.number:match("^%d%d%d+$") ~= nil, #lulibre.build.commit > 0 }, { true, true })

-- keys: the screens' tables, and the global keymap as scripts see it
do
  local screens = require "lulibre.ui.keys"
  local review = screens.of("review")
  eq("a screen's key means an action", { review:action("a"), review:action("<CR>"), review:action("z") }, { "accept", "edit" })
  eq("its hint names the keys in force", review:hint("accept", "write"), "a accept   w write   ? keys")
  lulibre.map("review", "y", "accept")
  eq("lulibre.map puts a key on a screen's action", { review:action("y"), review:action("a") }, { "accept", "accept" })
  eq("and the hint shows the new key", review:hint("accept"), "y accept   ? keys")
  lulibre.map("review", "a", "")
  eq("an empty action frees a key", review:action("a"), nil)
  eq("an unknown action is refused", (pcall(lulibre.map, "review", "y", "nosuch")), false)
  screens.reset()
  eq("reset puts the keys back", { review:action("a"), review:action("y") }, { "accept" })
  eq("Enter is spelled out", screens.of("edit"):hint("edit"), "Enter edit   ? keys")
  eq("the global key for a command", { lulibre.key("undo"), lulibre.key("preview graphic"), lulibre.key("no such") }, { "u", "P" })
  eq("or the command, for a hint", { lulibre.hint("undo"), lulibre.hint("index") }, { "u", ":index" })
  lulibre.map("n", "gU", "undo")
  eq("a later binding is the one named", lulibre.key("undo"), "gU")
  -- places with keys of their own: a panel's movement, the line being typed ...
  lulibre.map("panel", "n", "down")
  eq("a place's key can be added", lulibre.place_keys("panel"):find("j  <Down>  n +down a row") ~= nil, true)
  lulibre.map("panel", "n", "")
  eq("and taken away", lulibre.place_keys("panel"):find("j  <Down> +down a row") ~= nil, true)
  lulibre.map("console", "gt", "top")
  eq("two keys in a row are allowed", lulibre.place_keys("console"):find("gg  gt +the oldest entry") ~= nil, true)
  eq("an unknown action of a place is refused", (pcall(lulibre.map, "line", "<C-g>", "nosuch")), false)
  eq("no such place", lulibre.place_keys("nowhere"), nil)
  lulibre.map("n", "gB", "run bib", "write the selection as BibTeX")
  lulibre.map("n", "gH", function() end, false)
  eq("a key can say what it does, or stay out of the help", { lulibre.key("run bib") }, { "gB" })
  lulibre.map("n", "<Leader>z", "echo led")
  local found
  for _, m in ipairs(lulibre.maps()) do
    if m.command == "echo led" then found = m end
  end
  eq("lulibre.maps lists bindings", found and found.modes, "n")
end

print(("%d checks, %d failed"):format(count, fails))
if fails > 0 then error("unit checks failed", 0) end
