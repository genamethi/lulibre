-- The commands that run a bundled script (scripts/*.lua).
-- Loaded by the prelude at startup; each is a `:` command
-- (lulibre.command), and `:help` lists them.

local function script(name)
  return function(args) lulibre.exec("run " .. name .. (args ~= "" and " " .. args or "")) end
end
lulibre.command("bib", script("bib"), "[file]  write the selected books as BibTeX")
lulibre.command("verify", script("verify"),
  "[--list title|authors|ids|unread] [filter]  the library held against its files: titles, authors and identifiers the pages bear out")
lulibre.command("server-unit", script("server-unit"),
  "[apply | remove]  calibre's content server with calibre's own opf backup: what runs it, and the change to its unit")
lulibre.command("backup", script("backup"),
  "[now [why] | check | compare N | restore N | always | next | never | DAYS | prune [keep]]  copies of calibre's database: list, make, check, put back")
lulibre.command("offline", script("offline"),
  "[restart | cancel ID]  the changes calibre makes only while the content server is stopped: what waits; restart the server for them now")
lulibre.command("snapshot", script("snapshot"),
  "[NAME] | list | plan SNAP | rollback SNAP [--exact --unsync --fields] | retire SNAP | import FILE  points the library can be put back to")
lulibre.command("rollback", function(args) lulibre.exec("run snapshot rollback " .. (args or "")) end,
  "SNAP [--exact --unsync --fields]  put the library back to a snapshot (shows what it will do, then asks)")
lulibre.command("ocr", script("ocr"), "[filter | all]  read text from page images with tesseract")
lulibre.command("enrich", script("enrich"),
  "[--offline] [--titles] [filter]  look books up by their identifiers (arXiv, CrossRef, zbMATH, Open Library); proposes")
lulibre.command("onboard", script("onboard"), "DIR  add the ebook files under a directory to calibre, with metadata")
lulibre.command("datasets", script("datasets"),
  "[list | fetch NAME... | add FILE...]  databases for looking books up offline (arXiv, Open Library, zbMATH): pick one to fetch")
lulibre.command("arxiv-fetch", script("arxiv-fetch"),
  "[--force]  fetch arXiv's snapshot of its records from Kaggle (through pixi), for :enrich to read instead of asking arXiv")
lulibre.command("refs", script("refs"), "[--force] [filter | all]  read what the books cite, from the bibliography at the end of each file")
lulibre.command("propose", script("propose"), "[filter]  propose metadata from the files, for :review")
lulibre.command("notation", script("notation"),
  "[filter]  propose titles with their mathematics in Unicode (SL₂(ℤ), GLₙ(ℚₚ)), read from the title page where it has them")
lulibre.command("sync", script("sync"),
  "[add | move | drop] [filter]  the sync folder: show it; add the selection; add and delete; drop without adding")
