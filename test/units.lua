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
  eq("same: a bare year against a date in that year", propose.same("pubdate", "1996-05-01", "1996"), true)
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
  lulibre.map("n", "<Leader>z", "echo led")
  local found
  for _, m in ipairs(lulibre.maps()) do
    if m.command == "echo led" then found = m end
  end
  eq("lulibre.maps lists bindings", found and found.modes, "n")
end

print(("%d checks, %d failed"):format(count, fails))
if fails > 0 then error("unit checks failed", 0) end
