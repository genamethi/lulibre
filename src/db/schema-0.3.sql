-- index.db in 0.3 (design 19, 26, 27, 38; data representation). The
-- mirror of calibre's records (books, authors, tags, idents, custom
-- columns) stays as in 0.2.

CREATE TABLE files(
  id INTEGER PRIMARY KEY, book INTEGER, format TEXT NOT NULL, path TEXT NOT NULL,
  size INTEGER, mtime INTEGER,
  outcome INTEGER NOT NULL DEFAULT 0,   -- enum file_outcome (index/outcome.h)
  error TEXT,
  npages INTEGER, nchars INTEGER, quality REAL, garbled REAL,
  ocr_pages INTEGER, ocr_lang TEXT,     -- what OCR read, when it did
  emb_title TEXT, emb_author TEXT, emb_subject TEXT, emb_keywords TEXT,
  emb_creator TEXT, emb_producer TEXT,
  indexed_at INTEGER,
  UNIQUE(book, format));

-- the only stored text: one row per printed line
CREATE TABLE lines(
  id INTEGER PRIMARY KEY,
  file INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
  page INTEGER NOT NULL, n INTEGER NOT NULL,
  text TEXT NOT NULL, size REAL, flags INTEGER,
  x0 REAL, y0 REAL, x1 REAL, y1 REAL, math TEXT, src TEXT,
  UNIQUE(file, page, n));

-- one row per paragraph, built from the lines; rowid = the paragraph's first line
CREATE VIRTUAL TABLE paragraphs_fts USING fts5(
  text, content='', contentless_delete=1, tokenize='unicode61 remove_diacritics 2');

-- one proposal per book and field, from one parse or collective (design 16, 18)
CREATE TABLE proposals(
  id INTEGER PRIMARY KEY, book INTEGER NOT NULL, field TEXT NOT NULL, value TEXT,
  parse TEXT NOT NULL,        -- the grammar or service, or 'collective'
  alt INTEGER NOT NULL,       -- 1 for the first-ranked, then each alternative
  score REAL,
  agree TEXT, disagree TEXT,  -- the sources, as JSON
  file INTEGER, span_start INTEGER, span_end INTEGER,
  ts INTEGER,
  UNIQUE(book, field, alt));

-- every calibre operation, one lifecycle (design 25, 26, 27); replaces the
-- journal and the offline queue
CREATE TABLE journal(
  id INTEGER PRIMARY KEY, batch INTEGER NOT NULL, label TEXT,
  need INTEGER NOT NULL,      -- enum op_need
  store TEXT NOT NULL,
  state INTEGER NOT NULL,     -- enum op_state
  error TEXT, ts INTEGER,
  book INTEGER, field TEXT, old TEXT, new TEXT,
  argv TEXT,                  -- a structural command, as JSON
  proposal INTEGER, proposed TEXT, source TEXT);

-- every online answer, kept (design 43)
CREATE TABLE lookups(
  service TEXT NOT NULL, key TEXT NOT NULL, answer TEXT, ts INTEGER,
  PRIMARY KEY(service, key));
