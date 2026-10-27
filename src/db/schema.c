#include "db/db.h"

/* Bump SCHEMA_VERSION in db.c when this changes; the index is derived data
 * and is rebuilt rather than migrated. */
const char db_schema[] =
  "CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);"

  /* ---- mirror of calibre's metadata.db, replaced wholesale on change ---- */
  "CREATE TABLE IF NOT EXISTS books("
  " id INTEGER PRIMARY KEY, title TEXT, sort TEXT, authors TEXT, author_sort TEXT,"
  " tags TEXT, series TEXT, series_index REAL, publisher TEXT, pubdate TEXT,"
  " year INTEGER, languages TEXT, idents TEXT, has_comments INTEGER, path TEXT,"
  " formats TEXT, added TEXT, modified TEXT);"
  "CREATE TABLE IF NOT EXISTS authors("
  " id INTEGER PRIMARY KEY, name TEXT, sort TEXT, key TEXT, n_books INTEGER);"
  "CREATE TABLE IF NOT EXISTS book_authors(book INTEGER, author INTEGER, ord INTEGER);"
  "CREATE INDEX IF NOT EXISTS book_authors_book ON book_authors(book);"
  "CREATE INDEX IF NOT EXISTS book_authors_author ON book_authors(author);"
  "CREATE TABLE IF NOT EXISTS tags(id INTEGER PRIMARY KEY, name TEXT, n_books INTEGER);"
  "CREATE TABLE IF NOT EXISTS book_tags(book INTEGER, tag INTEGER);"
  "CREATE INDEX IF NOT EXISTS book_tags_book ON book_tags(book);"
  "CREATE INDEX IF NOT EXISTS book_tags_tag ON book_tags(tag);"
  "CREATE TABLE IF NOT EXISTS idents(book INTEGER, type TEXT, val TEXT);"
  "CREATE INDEX IF NOT EXISTS idents_book ON idents(book);"
  "CREATE VIRTUAL TABLE IF NOT EXISTS books_fts USING fts5("
  " title, authors, tags, publisher, series, tokenize='trigram');"
  /* calibre's custom columns, and their values, each as lulibre's custom
   * fields spell one (lua/lulibre/custom.lua): a number as %.10g, a date
   * as YYYY-MM-DD, a list one row per item in order */
  "CREATE TABLE IF NOT EXISTS cal_columns("
  " label TEXT PRIMARY KEY, name TEXT, datatype TEXT, multiple INTEGER);"
  "CREATE TABLE IF NOT EXISTS cal_values(book INTEGER, label TEXT, ord INTEGER, value TEXT);"
  "CREATE INDEX IF NOT EXISTS cal_values_label ON cal_values(label, book);"

  /* ---- the user's marked books; persists between sessions ---- */
  "CREATE TABLE IF NOT EXISTS marks(id INTEGER PRIMARY KEY);"

  /* ---- lulibre's own records. Unlike everything else here these are not
   * derived from the library, so they are never dropped on a schema change.
   * Lua reads and writes them through lulibre.store(). ---- */
  "CREATE TABLE IF NOT EXISTS proposals("
  " id INTEGER PRIMARY KEY, book INTEGER NOT NULL, field TEXT NOT NULL,"
  " op TEXT NOT NULL DEFAULT 'set', value TEXT NOT NULL, source TEXT, confidence REAL,"
  " status TEXT NOT NULL DEFAULT 'pending', created INTEGER, note TEXT, asked INTEGER);"
  "CREATE INDEX IF NOT EXISTS proposals_status ON proposals(status, book);"
  /* the journal of changes lives in the history file beside the index
   * (db.c, history_schema), so that nothing done to the index loses it */
  "CREATE TABLE IF NOT EXISTS kv(key TEXT PRIMARY KEY, value TEXT);"
  /* records the user has confirmed as right: what is learned about subjects
   * is learned from these (lua/lulibre/quality.lua, learn.lua) */
  "CREATE TABLE IF NOT EXISTS good(book INTEGER PRIMARY KEY, ts INTEGER);"
  /* works no catalogue has a record of (a handout, course notes): they have
   * no DOI or ISBN of their own and are not looked up by one
   * (lua/lulibre/noncatalog.lua) */
  "CREATE TABLE IF NOT EXISTS noncatalog(book INTEGER PRIMARY KEY, ts INTEGER);"
  /* the phrases that tell one subject from the others, learned from the good
   * records; state is 'learned', 'kept' (the user's own, or pinned) or
   * 'dropped' (never to come back) */
  /* what each book cites, one key for each entry of its bibliography
   * (lua/lulibre/refs.lua): books that cite the same things are about the
   * same thing */
  "CREATE TABLE IF NOT EXISTS refs("
  " book INTEGER NOT NULL, key TEXT NOT NULL, raw TEXT, PRIMARY KEY(book, key)) WITHOUT ROWID;"
  "CREATE INDEX IF NOT EXISTS refs_key ON refs(key);"
  /* what metadata services answered (lua/lulibre/net/core.lua), so that each work
   * is asked about once; status 404 is "asked, and there is none" */
  "CREATE TABLE IF NOT EXISTS lookups("
  " service TEXT NOT NULL, key TEXT NOT NULL, at INTEGER, status INTEGER, body TEXT,"
  " PRIMARY KEY(service, key)) WITHOUT ROWID;"
  "CREATE TABLE IF NOT EXISTS terms("
  " subject TEXT NOT NULL, term TEXT NOT NULL, score REAL, books INTEGER, state TEXT NOT NULL DEFAULT 'learned',"
  " PRIMARY KEY(subject, term)) WITHOUT ROWID;"
  /* content hashes, filled on demand by lulibre.md5(); a row is good while
   * the file's size and mtime still match */
  "CREATE TABLE IF NOT EXISTS hashes("
  " path TEXT PRIMARY KEY, size INTEGER, mtime INTEGER, md5 TEXT NOT NULL) WITHOUT ROWID;"
  "CREATE INDEX IF NOT EXISTS hashes_md5 ON hashes(md5);"
  /* files waiting in the sync folder, with the metadata they will be added
   * to calibre with. Shown as books with id = -id (db/stage.c). twin: the
   * library book that already holds the same bytes, if any. */
  "CREATE TABLE IF NOT EXISTS staged("
  " id INTEGER PRIMARY KEY, path TEXT UNIQUE NOT NULL, size INTEGER, mtime INTEGER,"
  " title TEXT, authors TEXT, tags TEXT, series TEXT, series_index REAL, publisher TEXT,"
  " pubdate TEXT, idents TEXT, languages TEXT, added INTEGER, twin INTEGER, note TEXT);"
  /* the books as they were the last time changes made outside lulibre were
   * looked for (db/mirror.c keeps it, lua/lulibre/snapshots.lua compares it
   * with the books as they are now and empties it) */
  "CREATE TABLE IF NOT EXISTS mirror_prev("
  " id INTEGER PRIMARY KEY, title TEXT, authors TEXT, tags TEXT, series TEXT, series_index REAL,"
  " publisher TEXT, pubdate TEXT, languages TEXT, idents TEXT, formats TEXT, path TEXT);"

  /* ---- files and what reading them came to (design 37, 38) ---- */
  "CREATE TABLE IF NOT EXISTS files("
  " id INTEGER PRIMARY KEY, book INTEGER, format TEXT NOT NULL, path TEXT NOT NULL,"
  " size INTEGER, mtime INTEGER,"
  " outcome INTEGER NOT NULL DEFAULT 0," /* enum file_outcome (index/outcome.h) */
  " error TEXT, npages INTEGER, req_pages INTEGER, nchars INTEGER, quality REAL, garbled REAL,"
  " ocr_pages INTEGER, ocr_lang TEXT," /* what OCR read, when it did */
  " emb_title TEXT, emb_author TEXT, emb_subject TEXT, emb_keywords TEXT,"
  " emb_creator TEXT, emb_producer TEXT, indexed_at INTEGER,"
  " UNIQUE(book, format));"
  "CREATE INDEX IF NOT EXISTS files_path ON files(path);"
  /* the only stored text: one row per printed line; flags LINE_* (doc/doc.h),
   * LINE_BLOCK on the first line of each paragraph */
  "CREATE TABLE IF NOT EXISTS lines("
  " id INTEGER PRIMARY KEY,"
  " file INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,"
  " page INTEGER NOT NULL, n INTEGER NOT NULL, text TEXT NOT NULL,"
  " size REAL, flags INTEGER, x0 REAL, y0 REAL, x1 REAL, y1 REAL, math TEXT,"
  " UNIQUE(file, page, n));"
  /* a page's text, from its lines: a blank line before each paragraph */
  "CREATE VIEW IF NOT EXISTS pages(file, page, text) AS"
  " SELECT file, page, group_concat(CASE WHEN flags & 32 AND n > 0 THEN char(10) || text ELSE text END,"
  " char(10) ORDER BY n) FROM lines GROUP BY file, page;"
  /* one row per paragraph, built from its lines when they are stored; the
   * rowid is the paragraph's first line's. A match is found again in the
   * paragraph's lines. */
  "CREATE VIRTUAL TABLE IF NOT EXISTS paragraphs_fts USING fts5("
  " text, content='', contentless_delete=1, tokenize='unicode61 remove_diacritics 2');";
