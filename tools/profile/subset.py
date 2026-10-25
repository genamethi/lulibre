"""A smaller calibre library made from a larger one, for measuring how a step
grows with the number of books. Every k-th book is kept, so the sample spans
the whole library rather than its oldest part. The books' folders are links
to the real ones, which are only read; metadata.db is a copy with the other
books deleted. calibredb must never run on the result.

    python3 -I tools/profile/subset.py LIBRARY N OUT
"""
import os
import sqlite3
import sys

lib, n, out = os.path.realpath(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
os.makedirs(out)
src = sqlite3.connect(f"file:{lib}/metadata.db?mode=ro", uri=True)
db = sqlite3.connect(os.path.join(out, "metadata.db"))
src.backup(db)
src.close()

ids = [r[0] for r in db.execute("SELECT id FROM books ORDER BY id")]
step = max(1, len(ids) // n)
keep = set(ids[::step][:n])
# calibre's triggers call functions only calibre defines
for (name,) in db.execute("SELECT name FROM sqlite_master WHERE type = 'trigger'").fetchall():
    db.execute(f'DROP TRIGGER "{name}"')
db.execute("CREATE TEMP TABLE keep (id INTEGER PRIMARY KEY)")
db.executemany("INSERT INTO keep VALUES (?)", [(i,) for i in keep])
db.execute("DELETE FROM books WHERE id NOT IN (SELECT id FROM keep)")
for (table,) in db.execute("SELECT name FROM sqlite_master WHERE type = 'table'").fetchall():
    cols = [c[1] for c in db.execute(f'PRAGMA table_info("{table}")')]
    if "book" in cols:
        db.execute(f'DELETE FROM "{table}" WHERE book NOT IN (SELECT id FROM books)')
db.commit()

for (path,) in db.execute("SELECT path FROM books"):
    os.makedirs(os.path.join(out, os.path.dirname(path)), exist_ok=True)
    os.symlink(os.path.join(lib, path), os.path.join(out, path))
db.execute("VACUUM")
db.close()
print(f"{len(keep)} books of {len(ids)} in {out}")
