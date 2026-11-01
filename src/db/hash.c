/* The hashes table: a file's MD5, good while its size and modification
 * time (to the nanosecond) are what they were when it was read. Used by
 * utils.md5 (lua/l_hash.c) and by the sync folder's scan (db/stage.c),
 * each on a connection of its own thread. */
#include <errno.h>
#include <string.h>
#include <sys/stat.h>

#include "core/md5.h"
#include "db/db.h"

long long db_mtime_ns(const struct stat *sb) {
  return (long long)sb->st_mtim.tv_sec * 1000000000LL + sb->st_mtim.tv_nsec;
}

int db_hash_get(sqlite3 *h, const char *path, long long size, long long mtime_ns, char hex[33]) {
  sqlite3_stmt *st;
  int hit = 0;
  if (sqlite3_prepare_v2(h, "SELECT md5 FROM hashes WHERE path = ? AND size = ? AND mtime = ?", -1, &st, NULL) !=
      SQLITE_OK)
    return 0;
  sqlite3_bind_text(st, 1, path, -1, SQLITE_STATIC);
  sqlite3_bind_int64(st, 2, size);
  sqlite3_bind_int64(st, 3, mtime_ns);
  if (sqlite3_step(st) == SQLITE_ROW && sqlite3_column_bytes(st, 0) == 32) {
    memcpy(hex, sqlite3_column_text(st, 0), 33);
    hit = 1;
  }
  sqlite3_finalize(st);
  return hit;
}

void db_hash_put(sqlite3 *h, const char *path, long long size, long long mtime_ns, const char *hex) {
  sqlite3_stmt *st;
  if (sqlite3_prepare_v2(h, "INSERT OR REPLACE INTO hashes(path, size, mtime, md5) VALUES(?, ?, ?, ?)", -1, &st,
                         NULL) != SQLITE_OK)
    return;
  sqlite3_bind_text(st, 1, path, -1, SQLITE_STATIC);
  sqlite3_bind_int64(st, 2, size);
  sqlite3_bind_int64(st, 3, mtime_ns);
  sqlite3_bind_text(st, 4, hex, -1, SQLITE_STATIC);
  sqlite3_step(st);
  sqlite3_finalize(st);
}

int db_hash_file(sqlite3 *h, const char *path, char hex[33]) {
  struct stat sb;
  if (stat(path, &sb)) return errno;
  long long size = (long long)sb.st_size, mt = db_mtime_ns(&sb);
  if (db_hash_get(h, path, size, mt, hex)) return 0;
  if (md5_file(path, hex)) return errno ? errno : EIO;
  db_hash_put(h, path, size, mt, hex);
  return 0;
}
