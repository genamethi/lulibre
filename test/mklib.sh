#!/bin/sh
# Build a two-book calibre library by hand at $1: a metadata.db with the
# tables lulibre reads, one PDF and one text file. No calibre needed.
set -eu
lib=$1
mkdir -p "$lib/Unknown/paper (1)" "$lib/Paul Erdos/Notes (2)"

sqlite3 "$lib/metadata.db" <<'SQL'
CREATE TABLE books(id INTEGER PRIMARY KEY, title TEXT, sort TEXT, timestamp TIMESTAMP,
  pubdate TIMESTAMP, series_index REAL, author_sort TEXT, path TEXT, last_modified TIMESTAMP);
CREATE TABLE authors(id INTEGER PRIMARY KEY, name TEXT, sort TEXT);
CREATE TABLE books_authors_link(id INTEGER PRIMARY KEY, book INTEGER, author INTEGER);
CREATE TABLE tags(id INTEGER PRIMARY KEY, name TEXT);
CREATE TABLE books_tags_link(id INTEGER PRIMARY KEY, book INTEGER, tag INTEGER);
CREATE TABLE series(id INTEGER PRIMARY KEY, name TEXT);
CREATE TABLE books_series_link(id INTEGER PRIMARY KEY, book INTEGER, series INTEGER);
CREATE TABLE publishers(id INTEGER PRIMARY KEY, name TEXT);
CREATE TABLE books_publishers_link(id INTEGER PRIMARY KEY, book INTEGER, publisher INTEGER);
CREATE TABLE languages(id INTEGER PRIMARY KEY, lang_code TEXT);
CREATE TABLE books_languages_link(id INTEGER PRIMARY KEY, book INTEGER, lang_code INTEGER);
CREATE TABLE identifiers(id INTEGER PRIMARY KEY, book INTEGER, type TEXT, val TEXT);
CREATE TABLE comments(id INTEGER PRIMARY KEY, book INTEGER, text TEXT);
CREATE TABLE data(id INTEGER PRIMARY KEY, book INTEGER, format TEXT,
  uncompressed_size INTEGER, name TEXT);

INSERT INTO books VALUES
 (1, 'paper', 'paper', '2024-01-01 00:00:00+00:00', '0101-01-01 00:00:00+00:00', 1.0,
  'Unknown', 'Unknown/paper (1)', '2024-01-01 00:00:00+00:00'),
 (2, 'Notes', 'Notes', '2024-01-02 00:00:00+00:00', '1996-05-01 00:00:00+00:00', 1.0,
  'Erdős, Paul', 'Paul Erdos/Notes (2)', '2024-01-02 00:00:00+00:00');
INSERT INTO authors VALUES (1, 'Unknown', 'Unknown'), (2, 'Paul Erdős', 'Erdős, Paul');
INSERT INTO books_authors_link VALUES (1, 1, 1), (2, 2, 2);
INSERT INTO tags VALUES (1, 'math.number-theory.additive'), (2, 'cs');
INSERT INTO books_tags_link VALUES (1, 2, 1);
INSERT INTO identifiers VALUES (1, 2, 'doi', '10.1000/xyz');
INSERT INTO data VALUES (1, 1, 'PDF', 0, 'paper - Unknown'), (2, 2, 'TXT', 0, 'Notes - Paul Erdos');
SQL

# A minimal PDF; the cross-reference table is left for the reader to rebuild.
cat > "$lib/Unknown/paper (1)/paper - Unknown.pdf" <<'PDF'
%PDF-1.4
1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj
2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj
3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 612 792]/Contents 4 0 R/Resources<</Font<</F1 5 0 R>>>>>>endobj
4 0 obj<</Length 120>>stream
BT /F1 24 Tf 72 700 Td (A Note on Sieve Methods) Tj ET
BT /F1 12 Tf 72 660 Td (arXiv:1012.6008v1 [math.NT]) Tj ET
endstream
endobj
5 0 obj<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>endobj
trailer<</Root 1 0 R/Size 6>>
%%EOF
PDF
printf 'Lecture notes on additive number theory\nSecond line\n' \
  > "$lib/Paul Erdos/Notes (2)/Notes - Paul Erdos.txt"

