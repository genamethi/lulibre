/* MD5 of a file, through OpenSSL's libcrypto. Used only to tell whether two
 * files hold the same bytes. */
#include "core/md5.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#include <openssl/evp.h>

int md5_file(const char *path, char hex[33]) {
  int fd = open(path, O_RDONLY | O_CLOEXEC);
  if (fd < 0) return -1;
#ifdef POSIX_FADV_SEQUENTIAL
  posix_fadvise(fd, 0, 0, POSIX_FADV_SEQUENTIAL);
#endif
  enum { CHUNK = 1 << 18 };
  unsigned char *buf = malloc(CHUNK);
  EVP_MD_CTX *ctx = EVP_MD_CTX_new();
  int rc = -1, e = ENOMEM;
  if (!buf || !ctx || !EVP_DigestInit_ex(ctx, EVP_md5(), NULL)) goto out;
  ssize_t n;
  while ((n = read(fd, buf, CHUNK)) != 0) {
    if (n < 0) {
      if (errno == EINTR) continue;
      e = errno;
      goto out;
    }
    EVP_DigestUpdate(ctx, buf, (size_t)n);
  }
  unsigned char out[EVP_MAX_MD_SIZE];
  unsigned len = 0;
  if (!EVP_DigestFinal_ex(ctx, out, &len) || len != 16) {
    e = EIO;
    goto out;
  }
  for (int i = 0; i < 16; i++) snprintf(hex + 2 * i, 3, "%02x", out[i]);
  rc = 0;
out:
  EVP_MD_CTX_free(ctx);
  free(buf);
  close(fd);
  if (rc) errno = e;
  return rc;
}
