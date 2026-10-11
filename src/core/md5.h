#ifndef LULIBRE_MD5_H
#define LULIBRE_MD5_H

#include <stddef.h>
#include <stdint.h>

struct md5 {
  uint32_t a, b, c, d;
  uint64_t len;
  unsigned char buf[64];
};

void md5_init(struct md5 *m);
void md5_update(struct md5 *m, const void *data, size_t n);
void md5_final(struct md5 *m, unsigned char out[16]);

/* MD5 of a file's contents as 32 hex digits. Returns 0, or -1 with errno
 * set when the file cannot be read. */
int md5_file(const char *path, char hex[33]);

#endif
