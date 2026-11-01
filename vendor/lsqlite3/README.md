# lsqlite3

lsqlite3.c from lsqlite3 0.9.7, unchanged: the SQLite binding scripts
reach as `require "lsqlite3"`. MIT licence, in the file's header.

- Source: https://lua.sqlite.org/home/zip/lsqlite3_v097.zip?uuid=v0.9.7
  (the `lsqlite3-0.9.7-1` source rock)
- SHA-256 of lsqlite3.c: a3de0d56dcdd7df85e334174cd46e70451f996bc843e735ab1d8a8e8804f9486
- Documentation: https://lua.sqlite.org/home/doc/tip/doc/lsqlite3.wiki

It is built into lulibre, not installed as a rock, so that it uses the
same SQLite as lulibre: lulibre's SQL functions (fold, ihas, ...) are
registered on every connection that SQLite opens in the process
(src/db/dbfuncs.c), and a rock built against another SQLite would not get
them. To update, replace the file and the version and checksum here.
